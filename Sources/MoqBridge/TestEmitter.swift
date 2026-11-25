import Foundation
import OSLog
import SwiftCommons

/// Answers amoo's `emit` verb: the `MoqClient` code a generated test needs for the session a flow
/// run gets from `flow_start`, and for each `moq.*` step. Arguments are read by the same strict
/// readers the steps use, and every request check becomes the `MoqClient` call of the same name,
/// so a flow step and its generated line ask the server the same question.
///
/// It writes Swift for XCUITest and Kotlin for Espresso and Compose.
public struct TestEmitter: Sendable {
    public static let supportedFrameworks: Set<String> = ["xcuitest", "espresso", "compose"]

    private static let logger = Logger.forType(subsystem: "UITestAgent", TestEmitter.self)

    private let environment: [String: String]
    private let currentDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
    ) {
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    public func handle(_ request: EmitRequest) throws -> EmitReply {
        guard request.protocol == ExtensionReply.protocolVersion else {
            throw BridgeError.unsupportedProtocol(request.protocol)
        }
        let context = "verb=emit framework=\(request.framework) phase=\(request.phase)"
        Self.logger.infoPublic("Handling \(context)")
        guard Self.supportedFrameworks.contains(request.framework) else {
            return .unsupported("amoo-ext-moq does not generate \(request.framework) code")
        }
        let kotlin = request.isKotlin
        do {
            let reply: EmitReply
            switch request.phase {
            case "setup":
                reply = try kotlin ? kotlinSetup(vars: request.vars ?? [:]) : swiftSetup(vars: request.vars ?? [:])
            case "teardown":
                reply =
                    kotlin
                    ? EmitReply(lines: [
                        "ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(moqLaunchCallback)",
                        "moqSession?.closeSession()",
                    ])
                    : EmitReply(lines: ["try moqSession?.closeSession()"], requires: ["throws"])
            case "step":
                guard let step = request.step else {
                    throw BridgeError.invalidArgument(name: "step", reason: "missing from the request")
                }
                let arguments = StepArguments(step.arguments ?? [:])
                reply =
                    kotlin
                    ? try Self.kotlinStep(tool: step.tool, arguments: arguments)
                    : EmitReply(lines: try Self.lines(tool: step.tool, arguments: arguments), requires: ["throws"])
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

    // MARK: Config

    /// The per-app config, found as `flow_start` finds it: the flow variable, then the environment.
    private func config(vars: [String: String]) throws -> AppConfig {
        guard
            let rawPath = vars[ExtensionHandler.configVariable]
                ?? environment[ExtensionHandler.configEnvironmentVariable],
            !rawPath.isEmpty
        else {
            throw BridgeError.invalidArgument(
                name: ExtensionHandler.configVariable,
                reason:
                    "set the flow variable, or \(ExtensionHandler.configEnvironmentVariable) when generating, so the test can give the app its launch keys"
            )
        }
        let configURL =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : currentDirectory.appending(path: rawPath).standardizedFileURL
        return try AppConfig.load(from: configURL)
    }

    // MARK: Swift setup

    /// Opens one session per test and hands the app the config's launch keys, as `flow_start`
    /// does for a flow run.
    private func swiftSetup(vars: [String: String]) throws -> EmitReply {
        let config = try config(vars: vars)
        let platform = try config.platformConfig(for: .ios)

        let auth: String
        switch config.server.adminAuth {
        case .none:
            auth = ""
        case .bearer(let tokenEnv):
            auth = ", auth: .bearer(ProcessInfo.processInfo.environment[\(Self.literal(tokenEnv))] ?? \"\")"
        case .apiKey(let header, let valueEnv):
            auth =
                ", auth: .apiKey(header: \(Self.literal(header)), value: ProcessInfo.processInfo.environment[\(Self.literal(valueEnv))] ?? \"\")"
        }
        var lines = [
            "let moqPort = ProcessInfo.processInfo.environment[\(Self.literal(ExtensionHandler.portEnvironmentVariable))] ?? \"\(config.server.port)\"",
            "let moqAdminURL = try XCTUnwrap(URL(string: \"http://\(Self.escaped(config.server.adminHost)):\\(moqPort)\"))",
            "let moqClient = try MoqClient(baseURL: moqAdminURL\(auth)).createSession()",
            "moqSession = moqClient",
            "let moqSessionID = try XCTUnwrap(moqClient.sessionID)",
            "let moqBaseURL = \"http://\(Self.escaped(platform.appHost)):\\(moqPort)\"",
        ]
        for (key, template) in platform.launchEnvironment.sorted(by: { $0.key < $1.key }) {
            let value = try LaunchTemplate.render(
                Self.escaped(template),
                values: [
                    LaunchTemplate.baseURL: "\\(moqBaseURL)",
                    LaunchTemplate.sessionId: "\\(moqSessionID)",
                ])
            lines.append("app.launchEnvironment[\(Self.literal(key))] = \"\(value)\"")
        }
        return EmitReply(
            imports: ["MoqTestSupport"], members: Self.members, lines: lines, requires: ["throws"])
    }

    static let members = [
        "private var moqSession: MoqClient?",
        """
        /// The moqserver session setUp opened for this test.
        private func moq() throws -> MoqClient {
            try XCTUnwrap(moqSession, "No moqserver session: setUp did not finish")
        }
        """,
    ]

    // MARK: Kotlin setup

    /// Opens one session per test and hands the app the config's launch keys as intent extras.
    ///
    /// amoo's generated test builds the launch intent itself, from the flow's literal environment,
    /// so the per-test values are added by a lifecycle callback just before the activity's
    /// `onCreate` reads them. Instrumented tests run in the app's process, which is what lets the
    /// callback reach the activity. The test reaches the admin API on the host the app uses.
    private func kotlinSetup(vars: [String: String]) throws -> EmitReply {
        let config = try config(vars: vars)
        let platform = try config.platformConfig(for: .android)
        let host = Self.kotlinEscaped(platform.appHost)

        let auth: String
        switch config.server.adminAuth {
        case .none:
            auth = ""
        case .bearer(let tokenEnv):
            auth =
                ", auth = MoqClient.Auth.Bearer(InstrumentationRegistry.getArguments().getString(\(Self.kotlinLiteral(tokenEnv))) ?: \"\")"
        case .apiKey(let header, let valueEnv):
            auth =
                ", auth = MoqClient.Auth.ApiKey(\(Self.kotlinLiteral(header)), InstrumentationRegistry.getArguments().getString(\(Self.kotlinLiteral(valueEnv))) ?: \"\")"
        }
        let portArgument = Self.kotlinLiteral(ExtensionHandler.portEnvironmentVariable)
        var lines = [
            "val moqPort = InstrumentationRegistry.getArguments().getString(\(portArgument)) ?: \"\(config.server.port)\"",
            "val moqBaseUrl = \"http://\(host):$moqPort\"",
            "val moqClient = MoqClient(moqBaseUrl\(auth)).createSession()",
            "moqSession = moqClient",
            "val moqSessionId = checkNotNull(moqClient.sessionId) { \"moqserver returned no session id\" }",
        ]
        for (key, template) in platform.launchEnvironment.sorted(by: { $0.key < $1.key }) {
            let value = try LaunchTemplate.render(
                Self.kotlinEscaped(template),
                values: [
                    LaunchTemplate.baseURL: "$moqBaseUrl",
                    LaunchTemplate.sessionId: "$moqSessionId",
                ])
            lines.append("moqLaunchExtras[\(Self.kotlinLiteral(key))] = \"\(value)\"")
        }
        lines.append("ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(moqLaunchCallback)")
        return EmitReply(imports: Self.kotlinImports, members: Self.kotlinMembers, lines: lines)
    }

    static let kotlinImports = [
        "androidx.test.platform.app.InstrumentationRegistry",
        "androidx.test.runner.lifecycle.ActivityLifecycleCallback",
        "androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry",
        "androidx.test.runner.lifecycle.Stage",
        "com.moqserver.testsupport.MoqClient",
    ]

    static let kotlinMembers = [
        "private var moqSession: MoqClient? = null",
        """
        /** Launch keys of this test's moqserver session, added to the activity's intent just before it is created. */
        private val moqLaunchExtras = mutableMapOf<String, String>()
        """,
        """
        private val moqLaunchCallback = ActivityLifecycleCallback { activity, stage ->
            if (stage == Stage.PRE_ON_CREATE) {
                moqLaunchExtras.forEach { (key, value) -> activity.intent.putExtra(key, value) }
            }
        }
        """,
        """
        /** The moqserver session the setup opened for this test. */
        private fun moq(): MoqClient = checkNotNull(moqSession) { "No moqserver session: setup did not finish" }
        """,
    ]

    // MARK: Swift steps

    static func lines(tool: String, arguments: StepArguments) throws -> [String] {
        var arguments = arguments
        switch tool {
        case "activate_scenario":
            let name = try arguments.string("name")
            try arguments.finish()
            return ["try moq().activateScenario(\(literal(name)))"]

        case "select_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            let variant = try arguments.string("variant")
            let times = try arguments.optionalInt("times", minimum: 1)
            try arguments.finish()
            var call = "try moq().selectVariant(\(literal(variant)), \(route(endpoint))"
            if let times {
                call += ", times: \(times)"
            }
            return [call + ")"]

        case "reset_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            try arguments.finish()
            return ["try moq().resetVariant(\(route(endpoint)))"]

        case "mark":
            let name = try arguments.string("name")
            try arguments.finish()
            return ["let \(markVariable(name)) = try moq().mark()"]

        case "assert_request":
            let endpoint = try arguments.string("endpoint")
            let times = try arguments.optionalInt("times", minimum: 0)
            let headers = try StepRunner.headerPredicates(arguments.array("headers")).map {
                try expectation($0, kotlin: false, of: "headers")
            }
            let parameters = try StepRunner.queryPredicates(arguments.array("query")).map {
                try expectation($0, kotlin: false, of: "query")
            }
            let claims = try arguments.stringMap("claims")
            let since = try since(&arguments)
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0)
            try arguments.finish()
            var parts = ["endpoint: \(literal(endpoint))"]
            if let times {
                parts.append("times: \(times)")
            }
            if !headers.isEmpty {
                parts.append("headers: [\(headers.joined(separator: ", "))]")
            }
            if !parameters.isEmpty {
                parts.append("query: [\(parameters.joined(separator: ", "))]")
            }
            if !claims.isEmpty {
                parts.append("claims: \(dictionary(claims))")
            }
            if let since {
                parts.append("since: \(since)")
            }
            if let timeout, timeout > 0 {
                parts.append("timeout: \(seconds(timeout))")
            }
            return ["_ = try moq().assertRequest(\(parts.joined(separator: ", ")))"]

        case "assert_no_rejected_requests":
            let since = try since(&arguments)
            try arguments.finish()
            return ["try moq().assertNoRejectedRequests(\(since.map { "since: \($0)" } ?? ""))"]

        case "assert_all_requests_carry_session":
            let claims = try arguments.stringMap("claims")
            let includeUnattributed = try arguments.optionalBool("include_unattributed") ?? false
            let since = try since(&arguments)
            try arguments.finish()
            var parts: [String] = []
            if !claims.isEmpty {
                parts.append("claims: \(dictionary(claims))")
            }
            if includeUnattributed {
                parts.append("includeUnattributed: true")
            }
            if let since {
                parts.append("since: \(since)")
            }
            return ["_ = try moq().assertAllRequestsCarrySession(\(parts.joined(separator: ", ")))"]

        case "assert_session_reached":
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0) ?? 0
            try arguments.finish()
            // With no endpoint and no count, the client's check passes once any request has
            // reached the session.
            return ["_ = try moq().assertRequest(\(timeout > 0 ? "timeout: \(seconds(timeout))" : ""))"]

        case "assert_no_unmatched_requests":
            try arguments.finish()
            return ["try moq().assertNoUnmatchedRequests()"]

        default:
            throw BridgeError.invalidArgument(name: "tool", reason: "moq.\(tool) is not a step of this build")
        }
    }

    // MARK: Kotlin steps

    static let headerExpectationImport = "com.moqserver.testsupport.MoqHeaderExpectation"
    static let queryExpectationImport = "com.moqserver.testsupport.MoqQueryExpectation"

    /// The Kotlin client's call for one step, with the imports its expectations need.
    static func kotlinStep(tool: String, arguments: StepArguments) throws -> EmitReply {
        var arguments = arguments
        switch tool {
        case "activate_scenario":
            let name = try arguments.string("name")
            try arguments.finish()
            return EmitReply(lines: ["moq().activateScenario(\(kotlinLiteral(name)))"])

        case "select_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            let variant = try arguments.string("variant")
            let times = try arguments.optionalInt("times", minimum: 1)
            try arguments.finish()
            var call = "moq().selectVariant(\(kotlinLiteral(variant)), \(kotlinRoute(endpoint))"
            if let times {
                call += ", times = \(times)"
            }
            return EmitReply(lines: [call + ")"])

        case "reset_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            try arguments.finish()
            return EmitReply(lines: ["moq().resetVariant(\(kotlinRoute(endpoint)))"])

        case "mark":
            let name = try arguments.string("name")
            try arguments.finish()
            return EmitReply(lines: ["val \(markVariable(name)) = moq().mark()"])

        case "assert_request":
            let endpoint = try arguments.string("endpoint")
            let times = try arguments.optionalInt("times", minimum: 0)
            let headers = try StepRunner.headerPredicates(arguments.array("headers")).map {
                try expectation($0, kotlin: true, of: "headers")
            }
            let parameters = try StepRunner.queryPredicates(arguments.array("query")).map {
                try expectation($0, kotlin: true, of: "query")
            }
            let claims = try arguments.stringMap("claims")
            let since = try kotlinSince(&arguments)
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0)
            try arguments.finish()
            var parts = [kotlinLiteral(endpoint)]
            var imports: [String] = []
            if let times {
                parts.append("times = \(times)")
            }
            if !headers.isEmpty {
                parts.append("headers = listOf(\(headers.joined(separator: ", ")))")
                imports.append(headerExpectationImport)
            }
            if !claims.isEmpty {
                parts.append("claims = \(kotlinMap(claims))")
            }
            if let since {
                parts.append("since = \(since)")
            }
            if let timeout, timeout > 0 {
                parts.append("timeoutMillis = \(timeout)")
            }
            if !parameters.isEmpty {
                parts.append("query = listOf(\(parameters.joined(separator: ", ")))")
                imports.append(queryExpectationImport)
            }
            return EmitReply(
                imports: imports.isEmpty ? nil : imports,
                lines: ["moq().assertRequest(\(parts.joined(separator: ", ")))"])

        case "assert_no_rejected_requests":
            let since = try kotlinSince(&arguments)
            try arguments.finish()
            return EmitReply(lines: ["moq().assertNoRejectedRequests(\(since.map { "since = \($0)" } ?? ""))"])

        case "assert_all_requests_carry_session":
            let claims = try arguments.stringMap("claims")
            let includeUnattributed = try arguments.optionalBool("include_unattributed") ?? false
            let since = try kotlinSince(&arguments)
            try arguments.finish()
            var parts: [String] = []
            if !claims.isEmpty {
                parts.append("claims = \(kotlinMap(claims))")
            }
            if includeUnattributed {
                parts.append("includeUnattributed = true")
            }
            if let since {
                parts.append("since = \(since)")
            }
            return EmitReply(lines: ["moq().assertAllRequestsCarrySession(\(parts.joined(separator: ", ")))"])

        case "assert_session_reached":
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0) ?? 0
            try arguments.finish()
            return EmitReply(lines: ["moq().assertRequest(\(timeout > 0 ? "timeoutMillis = \(timeout)" : ""))"])

        case "assert_no_unmatched_requests":
            try arguments.finish()
            return EmitReply(lines: ["moq().assertNoUnmatchedRequests()"])

        default:
            throw BridgeError.invalidArgument(name: "tool", reason: "moq.\(tool) is not a step of this build")
        }
    }

    /// `since` for Kotlin, where a `Double` parameter refuses an integer literal.
    private static func kotlinSince(_ arguments: inout StepArguments) throws -> String? {
        guard let since = try since(&arguments) else {
            return nil
        }
        return Double(since) != nil && !since.contains(".") ? since + ".0" : since
    }

    // MARK: Shared pieces

    /// `since` as code: a number as written, or the local a `moq.mark` of that name declared.
    private static func since(_ arguments: inout StepArguments) throws -> String? {
        switch arguments.value("since") {
        case nil, .null:
            return nil
        case .number(let value):
            return String(value)
        case .string(let text):
            if Double(text) != nil {
                return text
            }
            return markVariable(text)
        default:
            throw BridgeError.invalidArgument(name: "since", reason: "must be a mark name or a number")
        }
    }

    /// One wire predicate (`{name, present | scheme | fingerprintOf | equals}`) as the client's
    /// expectation: `MoqHeaderExpectation` for `headers`, `MoqQueryExpectation` for `query`.
    private static func expectation(_ predicate: JSONValue, kotlin: Bool, of argument: String) throws -> String {
        guard case .object(let fields) = predicate, case .string(let name) = fields["name"] else {
            throw BridgeError.invalidArgument(name: argument, reason: "needs a non-empty name")
        }
        let type = argument == "query" ? "MoqQueryExpectation" : "MoqHeaderExpectation"
        func make(_ swiftCase: String, _ kotlinCase: String, _ value: String?, label: String = "") -> String {
            if kotlin {
                let arguments = ([name] + (value.map { [$0] } ?? [])).map(kotlinLiteral)
                return "\(type).\(kotlinCase)(\(arguments.joined(separator: ", ")))"
            }
            return ".\(swiftCase)(\(literal(name))\(value.map { ", \(label)\(literal($0))" } ?? ""))"
        }
        if case .bool(let present) = fields["present"] {
            return present ? make("present", "Present", nil) : make("absent", "Absent", nil)
        }
        if case .string(let scheme) = fields["scheme"] {
            return make("scheme", "Scheme", scheme)
        }
        if case .string(let credential) = fields["fingerprintOf"] {
            return make("fingerprint", "Fingerprint", credential, label: "of: ")
        }
        if case .string(let value) = fields["equals"] {
            return make("equals", "Equals", value)
        }
        throw BridgeError.invalidArgument(name: argument, reason: "has a predicate this build can't write")
    }

    private static func route(_ endpoint: EndpointRef) -> String {
        var route = "for: \(literal(endpoint.method)), path: \(literal(endpoint.path))"
        if let operation = endpoint.operation {
            route += ", operation: \(literal(operation))"
        }
        return route
    }

    private static func kotlinRoute(_ endpoint: EndpointRef) -> String {
        var route = "\(kotlinLiteral(endpoint.method)), \(kotlinLiteral(endpoint.path))"
        if let operation = endpoint.operation {
            route += ", operation = \(kotlinLiteral(operation))"
        }
        return route
    }

    /// The local that holds a mark: `before-delete` → `moqMarkBeforeDelete`.
    static func markVariable(_ name: String) -> String {
        let words = name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return "moqMark" + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static func seconds(_ milliseconds: Int) -> String {
        let value = Double(milliseconds) / 1000
        return value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func dictionary(_ values: [String: String]) -> String {
        "[" + values.sorted(by: { $0.key < $1.key }).map { "\(literal($0.key)): \(literal($0.value))" }
            .joined(separator: ", ") + "]"
    }

    private static func kotlinMap(_ values: [String: String]) -> String {
        let pairs = values.sorted(by: { $0.key < $1.key }).map { "\(kotlinLiteral($0.key)) to \(kotlinLiteral($0.value))" }
        return "mapOf(\(pairs.joined(separator: ", ")))"
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

    /// `text` as a Kotlin string literal.
    static func kotlinLiteral(_ text: String) -> String {
        "\"\(kotlinEscaped(text))\""
    }

    /// `text` made safe inside a Kotlin string literal; a `$` in it stays literal text.
    static func kotlinEscaped(_ text: String) -> String {
        escaped(text).replacingOccurrences(of: "$", with: "\\$")
    }
}
