import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

public typealias AuthEmitRequest = EmitRequest

/// Answers amoo's `emit` verb for the `test-routes` provider: the code a generated test needs to
/// run in a backend session of its own and to call the backend's test routes for `auth.*` steps.
///
/// XCUITest only. The `firebase-emulator` provider, Espresso and Compose answer `ok: false`.
public struct AuthEmitter: Sendable {
    public static let supportedFrameworks: Set<String> = ["xcuitest"]

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
            return .unsupported(
                "amoo-ext-auth does not generate \(request.framework) code yet; it writes XCUITest only")
        }
        do {
            let config = try config()
            guard config.provider == .testRoutes else {
                return .unsupported(
                    "amoo-ext-auth generates test code for the test-routes provider only, not \(config.provider.rawValue)"
                )
            }
            let reply: EmitReply
            switch request.phase {
            case "setup":
                reply = setup(config)
            case "teardown":
                reply = teardown(config)
            case "step":
                guard let step = request.step else {
                    throw ArgumentError(name: "step", reason: "missing from the request")
                }
                reply = try self.step(step, config: config)
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

    /// amoo sends no flow variables with `emit`, so the config is found through the environment.
    private func config() throws -> AuthConfig {
        guard let rawPath = environment[AuthHandler.configEnvironmentVariable], !rawPath.isEmpty else {
            throw ArgumentError(
                name: AuthHandler.configEnvironmentVariable,
                reason: "set it to the per-app config when generating, so the test can reach the backend's test routes")
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

    private func step(_ step: EmitRequest.Step, config: AuthConfig) throws -> EmitReply {
        var arguments = StepArguments(step.arguments ?? [:])
        let email = try arguments.string("email")
        try arguments.finish()
        guard AuthHandler.steps.contains(step.tool) else {
            throw ArgumentError(name: "tool", reason: "auth.\(step.tool) is not a step of this build")
        }
        guard let route = config.routes?[step.tool] else {
            throw AuthError.noRoute(step: step.tool)
        }
        return EmitReply(
            lines: ["try authExpect(\(Self.literal(route.method)), \(Self.path(of: route, email: email)))"],
            requires: ["throws"])
    }

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

    /// `text` made safe inside a Swift string literal; an interpolation in it stays literal text.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
