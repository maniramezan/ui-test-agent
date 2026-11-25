import Foundation
import OSLog
import SwiftCommons

/// Answers amoo's `emit` verb: the `MoqClient` code a generated test needs for the session a flow
/// run gets from `flow_start`, and for each `moq.*` step. Arguments are read by the same strict
/// readers the steps use, and every request check becomes the `MoqClient` call of the same name,
/// so a flow step and its generated line ask the server the same question.
///
/// XCUITest only for now; Espresso and Compose answer `ok: false`.
public struct TestEmitter: Sendable {
    public static let supportedFrameworks: Set<String> = ["xcuitest"]

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
            return .unsupported(
                "amoo-ext-moq does not generate \(request.framework) code yet; it writes XCUITest only")
        }
        do {
            let reply: EmitReply
            switch request.phase {
            case "setup":
                reply = try setup()
            case "teardown":
                reply = EmitReply(lines: ["try moqSession?.closeSession()"], requires: ["throws"])
            case "step":
                guard let step = request.step else {
                    throw BridgeError.invalidArgument(name: "step", reason: "missing from the request")
                }
                reply = EmitReply(
                    lines: try Self.lines(tool: step.tool, arguments: StepArguments(step.arguments ?? [:])),
                    requires: ["throws"])
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

    // MARK: Setup

    /// Opens one session per test and hands the app the config's launch keys, as `flow_start`
    /// does for a flow run. amoo sends no flow variables with `emit`, so the per-app config is
    /// found through the environment only.
    private func setup() throws -> EmitReply {
        guard let rawPath = environment[ExtensionHandler.configEnvironmentVariable], !rawPath.isEmpty else {
            throw BridgeError.invalidArgument(
                name: ExtensionHandler.configEnvironmentVariable,
                reason:
                    "set it to the per-app config when generating, so the test can give the app its launch keys")
        }
        let configURL =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : currentDirectory.appending(path: rawPath).standardizedFileURL
        let config = try AppConfig.load(from: configURL)
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

    // MARK: Steps

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
            let headers = try StepRunner.headerPredicates(arguments.array("headers")).map(headerExpectation)
            let parameters = try StepRunner.queryPredicates(arguments.array("query")).map(queryExpectation)
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

    /// `since` as Swift: a number as written, or the local a `moq.mark` of that name declared.
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

    /// One wire predicate (`{name, present | scheme | fingerprintOf | equals}`) as its
    /// `MoqHeaderExpectation` case.
    private static func headerExpectation(_ predicate: JSONValue) throws -> String {
        guard case .object(let fields) = predicate, case .string(let name) = fields["name"] else {
            throw BridgeError.invalidArgument(name: "headers", reason: "needs a non-empty name")
        }
        if case .bool(let present) = fields["present"] {
            return present ? ".present(\(literal(name)))" : ".absent(\(literal(name)))"
        }
        if case .string(let scheme) = fields["scheme"] {
            return ".scheme(\(literal(name)), \(literal(scheme)))"
        }
        if case .string(let credential) = fields["fingerprintOf"] {
            return ".fingerprint(\(literal(name)), of: \(literal(credential)))"
        }
        if case .string(let value) = fields["equals"] {
            return ".equals(\(literal(name)), \(literal(value)))"
        }
        throw BridgeError.invalidArgument(
            name: "headers", reason: "needs exactly one of present, scheme, fingerprint_of, equals")
    }

    /// One wire predicate (`{name, present | equals | fingerprintOf}`) as its
    /// `MoqQueryExpectation` case.
    private static func queryExpectation(_ predicate: JSONValue) throws -> String {
        guard case .object(let fields) = predicate, case .string(let name) = fields["name"] else {
            throw BridgeError.invalidArgument(name: "query", reason: "needs a non-empty name")
        }
        if case .bool(let present) = fields["present"] {
            return present ? ".present(\(literal(name)))" : ".absent(\(literal(name)))"
        }
        if case .string(let value) = fields["equals"] {
            return ".equals(\(literal(name)), \(literal(value)))"
        }
        if case .string(let credential) = fields["fingerprintOf"] {
            return ".fingerprint(\(literal(name)), of: \(literal(credential)))"
        }
        throw BridgeError.invalidArgument(
            name: "query", reason: "needs exactly one of present, equals, fingerprint_of")
    }

    private static func route(_ endpoint: EndpointRef) -> String {
        var route = "for: \(literal(endpoint.method)), path: \(literal(endpoint.path))"
        if let operation = endpoint.operation {
            route += ", operation: \(literal(operation))"
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
