import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

public typealias AuthEmitRequest = EmitRequest

/// Answers amoo's `emit` verb for the `test-routes` provider: the code a generated test needs to
/// run in a backend session of its own and to call the backend's test routes for `auth.*` steps.
///
/// It writes Swift for XCUITest and Kotlin for Espresso and Compose. The `firebase-emulator`
/// provider answers `ok: false`.
public struct AuthEmitter: Sendable {
    public static let supportedFrameworks: Set<String> = ["xcuitest", "espresso", "compose"]

    /// The development machine's loopback as an Android emulator reaches it.
    static let emulatorHostLoopback = "10.0.2.2"

    private static let logger = Logger.forType(subsystem: "UITestAgent", AuthEmitter.self)

    private let environment: [String: String]
    private let currentDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) {
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    public func handle(_ request: EmitRequest) -> EmitReply {
        let context = "verb=emit framework=\(request.framework) phase=\(request.phase)"
        Self.logger.infoPublic("Handling \(context)")
        guard request.protocol == 1 else {
            return .unsupported("amoo sent protocol \(request.protocol); this extension speaks 1")
        }
        guard Self.supportedFrameworks.contains(request.framework) else {
            return .unsupported("amoo-ext-auth does not generate \(request.framework) code")
        }
        let kotlin = request.isKotlin
        do {
            let config = try config(vars: request.vars ?? [:])
            guard config.provider == .testRoutes else {
                return .unsupported(
                    "amoo-ext-auth generates test code for the test-routes provider only, not \(config.provider.rawValue)"
                )
            }
            let reply: EmitReply
            switch request.phase {
            case "setup":
                reply = kotlin ? kotlinSetup(config) : setup(config)
            case "teardown":
                reply = kotlin ? kotlinTeardown(config) : teardown(config)
            case "step":
                guard let step = request.step else {
                    throw ArgumentError(name: "step", reason: "missing from the request")
                }
                reply = try self.step(step, config: config, kotlin: kotlin)
            default:
                reply = .unsupported("Unknown emit phase \(request.phase)")
            }
            Self.logger.infoPublic("Handled \(context) ok=\(reply.ok ?? true)")
            return reply
        } catch {
            Self.logger.error("Emit failed", error: error, context: context)
            return .unsupported(error.localizedDescription)
        }
    }

    /// The per-app config, found as `flow_start` finds it: the flow variables, then the environment.
    private func config(vars: [String: String]) throws -> AuthConfig {
        guard
            let rawPath = vars[AuthHandler.configVariable] ?? vars[AuthHandler.moqConfigVariable]
                ?? environment[AuthHandler.configEnvironmentVariable],
            !rawPath.isEmpty
        else {
            throw ArgumentError(
                name: AuthHandler.configVariable,
                reason:
                    "set the flow variable, or \(AuthHandler.configEnvironmentVariable) when generating, so the test can reach the backend's test routes"
            )
        }
        let url =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : currentDirectory.appending(path: rawPath).standardizedFileURL
        return try AuthConfig.load(from: url)
    }

    /// One fresh session id per test, and the launch keys that make the app join it.
    private func setup(_ config: AuthConfig) -> EmitReply {
        var values = ["baseURL": Self.escaped(config.baseURL ?? "")]
        if config.sessionHeader != nil {
            values["sessionId"] = "\\(authSession)"
        }
        let lines = (config.launchEnvironment ?? [:]).sorted(by: { $0.key < $1.key }).map { key, template in
            let value = AuthConfig.render(Self.escaped(template), open: "{{", close: "}}", values: values)
            return "app.launchEnvironment[\(Self.literal(key))] = \"\(value)\""
        }
        return EmitReply(members: members(config), lines: lines)
    }

    private func teardown(_ config: AuthConfig) -> EmitReply {
        guard config.sessionHeader != nil, let release = config.routes?[AuthConfig.releaseRoute] else {
            return EmitReply()
        }
        return EmitReply(lines: ["_ = try? authCall(\(Self.literal(release.method)), \(Self.path(of: release, email: nil)))"])
    }

    private func step(_ step: EmitRequest.Step, config: AuthConfig, kotlin: Bool) throws -> EmitReply {
        var arguments = StepArguments(step.arguments ?? [:])
        let email = try arguments.string("email")
        try arguments.finish()
        guard AuthHandler.steps.contains(step.tool) else {
            throw ArgumentError(name: "tool", reason: "auth.\(step.tool) is not a step of this build")
        }
        guard let route = config.routes?[step.tool] else {
            throw AuthError.noRoute(step: step.tool)
        }
        if kotlin {
            return EmitReply(lines: [
                "authExpect(\(Self.kotlinLiteral(route.method)), \(Self.kotlinPath(of: route, email: email)))"
            ])
        }
        return EmitReply(
            lines: ["try authExpect(\(Self.literal(route.method)), \(Self.path(of: route, email: email)))"],
            requires: ["throws"])
    }

    // MARK: Kotlin

    /// The backend as a test on an Android emulator reaches it: the config's loopback host
    /// becomes the emulator's alias for the development machine.
    static func emulatorBaseURL(_ baseURL: String) -> String {
        var base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        for host in AuthConfig.loopbackHosts.sorted() {
            base = base.replacingOccurrences(of: "://\(host)", with: "://\(emulatorHostLoopback)")
            base = base.replacingOccurrences(of: "://[\(host)]", with: "://\(emulatorHostLoopback)")
        }
        return base
    }

    /// One fresh session id per test, and the launch keys that make the app join it. amoo's
    /// generated test builds the launch intent itself, so the keys are added by a lifecycle
    /// callback just before the activity's `onCreate` reads them.
    private func kotlinSetup(_ config: AuthConfig) -> EmitReply {
        var values = ["baseURL": Self.kotlinEscaped(Self.emulatorBaseURL(config.baseURL ?? ""))]
        if config.sessionHeader != nil {
            values["sessionId"] = "$authSession"
        }
        let extras = (config.launchEnvironment ?? [:]).sorted(by: { $0.key < $1.key }).map { key, template in
            let value = AuthConfig.render(Self.kotlinEscaped(template), open: "{{", close: "}}", values: values)
            return "authLaunchExtras[\(Self.kotlinLiteral(key))] = \"\(value)\""
        }
        var imports = ["java.net.HttpURLConnection", "java.net.URL"]
        var lines: [String] = []
        if !extras.isEmpty {
            imports += [
                "androidx.test.runner.lifecycle.ActivityLifecycleCallback",
                "androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry",
                "androidx.test.runner.lifecycle.Stage",
            ]
            lines = extras + ["ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(authLaunchCallback)"]
        }
        if config.sessionHeader != nil {
            imports.append("java.util.UUID")
        }
        return EmitReply(imports: imports, members: kotlinMembers(config, launchKeys: !extras.isEmpty), lines: lines)
    }

    private func kotlinTeardown(_ config: AuthConfig) -> EmitReply {
        var lines: [String] = []
        if !(config.launchEnvironment ?? [:]).isEmpty {
            lines.append("ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(authLaunchCallback)")
        }
        if config.sessionHeader != nil, let release = config.routes?[AuthConfig.releaseRoute] {
            lines.append(
                "runCatching { authCall(\(Self.kotlinLiteral(release.method)), \(Self.kotlinPath(of: release, email: nil))) }")
        }
        return EmitReply(lines: lines)
    }

    /// `route`'s path as a Kotlin string literal, with `{session}` read from the test's member.
    static func kotlinPath(of route: AuthConfig.Route, email: String?) -> String {
        let marker = "auth-session-placeholder"
        let path = TestRoutesClient.path(of: route, email: email, session: marker)
        return kotlinLiteral(path).replacingOccurrences(of: marker, with: "$authSession")
    }

    private func kotlinMembers(_ config: AuthConfig, launchKeys: Bool) -> [String] {
        let base = Self.kotlinEscaped(Self.emulatorBaseURL(config.baseURL ?? ""))
        var members: [String] = []
        var header = ""
        if let sessionHeader = config.sessionHeader {
            members.append(
                """
                /** This test's own data set on the backend, so tests running at the same time don't see each other's changes. */
                private val authSession = UUID.randomUUID().toString()
                """)
            header = "\n    connection.setRequestProperty(\(Self.kotlinLiteral(sessionHeader)), authSession)"
        }
        if launchKeys {
            members.append(
                """
                /** Launch keys of this test's backend session, added to the activity's intent just before it is created. */
                private val authLaunchExtras = mutableMapOf<String, String>()
                """)
            members.append(
                """
                private val authLaunchCallback = ActivityLifecycleCallback { activity, stage ->
                    if (stage == Stage.PRE_ON_CREATE) {
                        authLaunchExtras.forEach { (key, value) -> activity.intent.putExtra(key, value) }
                    }
                }
                """)
        }
        members.append(
            """
            /** Calls one of the backend's test routes and returns the status. */
            private fun authCall(method: String, path: String): Int {
                val connection = URL("\(base)" + path).openConnection() as HttpURLConnection
                connection.requestMethod = method
                connection.connectTimeout = 10_000
                connection.readTimeout = 10_000\(header)
                return try {
                    connection.responseCode
                } finally {
                    connection.disconnect()
                }
            }
            """)
        members.append(
            """
            /** Calls one of the backend's test routes and fails the test unless it answers 2xx. */
            private fun authExpect(method: String, path: String) {
                val status = authCall(method, path)
                check(status in 200..299) { "$method $path answered $status" }
            }
            """)
        return members
    }

    // MARK: Swift

    /// `route`'s path as a Swift string literal, with `{session}` read from the test's member.
    static func path(of route: AuthConfig.Route, email: String?) -> String {
        let marker = "auth-session-placeholder"
        let path = TestRoutesClient.path(of: route, email: email, session: marker)
        return literal(path).replacingOccurrences(of: marker, with: "\\(authSession)")
    }

    /// The test's session id and the two helpers that call the backend.
    private func members(_ config: AuthConfig) -> [String] {
        let baseURL = config.baseURL ?? ""
        let base = Self.escaped(baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL)
        var members: [String] = []
        var header = ""
        if let sessionHeader = config.sessionHeader {
            members.append(
                """
                /// This test's own data set on the backend, so tests running at the same time
                /// don't see each other's changes.
                private let authSession = UUID().uuidString.lowercased()
                """)
            header = "\n    request.setValue(authSession, forHTTPHeaderField: \(Self.literal(sessionHeader)))"
        }
        members.append(
            """
            /// Calls one of the backend's test routes and returns the status, 0 when it did not answer.
            private func authCall(_ method: String, _ path: String) throws -> Int {
                var request = URLRequest(url: try XCTUnwrap(URL(string: "\(base)" + path)))
                request.httpMethod = method
                request.timeoutInterval = 10\(header)
                let done = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var status = 0
                URLSession.shared.dataTask(with: request) { _, response, _ in
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    done.signal()
                }.resume()
                done.wait()
                return status
            }
            """)
        members.append(
            """
            /// Calls one of the backend's test routes and fails the test unless it answers 2xx.
            private func authExpect(
                _ method: String, _ path: String, file: StaticString = #filePath, line: UInt = #line
            ) throws {
                let status = try authCall(method, path)
                XCTAssertTrue(
                    (200..<300).contains(status), "\\(method) \\(path) answered \\(status)", file: file, line: line)
            }
            """)
        return members
    }

    /// `text` as a Swift string literal.
    static func literal(_ text: String) -> String {
        "\"\(escaped(text))\""
    }

    /// `text` as a Kotlin string literal.
    static func kotlinLiteral(_ text: String) -> String {
        "\"\(kotlinEscaped(text))\""
    }

    /// `text` made safe inside a Kotlin string literal; a `$` in it stays literal text.
    static func kotlinEscaped(_ text: String) -> String {
        escaped(text).replacingOccurrences(of: "$", with: "\\$")
    }

    /// `text` made safe inside a Swift string literal; an interpolation in it stays literal text.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
