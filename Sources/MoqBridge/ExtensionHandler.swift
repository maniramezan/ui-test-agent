import Foundation
import OSLog
import SwiftCommons

/// Answers amoo's flow-extension verbs: opens a moqserver session at flow start, runs `moq.*`
/// steps inside it, and releases it at flow end.
public struct ExtensionHandler: Sendable {
    public static let configVariable = "moq_config"
    public static let portVariable = "moq_port"
    public static let sessionVariable = "moq_session"
    public static let configEnvironmentVariable = "AMOO_EXT_MOQ_CONFIG"
    public static let portEnvironmentVariable = "MOQ_PORT"

    /// The steps this build implements. A flow using any other `moq.*` step fails before it runs.
    public static let steps = [
        "activate_scenario",
        "select_variant",
        "reset_variant",
        "assert_no_unmatched_requests",
        "assert_no_rejected_requests",
    ]

    private static let logger = Logger.forType(subsystem: "UITestAgent", ExtensionHandler.self)

    private let environment: [String: String]
    private let transport: any HTTPTransport
    private let currentDirectory: URL
    private let pollInterval: Duration

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(),
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.environment = environment
        self.transport = transport
        self.currentDirectory = currentDirectory
        self.pollInterval = pollInterval
    }

    /// Turns one request into one reply. Problems a flow author can fix become `ok: false` with
    /// a message; only an unreadable request or a protocol mismatch throws.
    public func handle(_ request: ExtensionRequest) async throws -> ExtensionReply {
        guard request.protocol == ExtensionReply.protocolVersion else {
            throw BridgeError.unsupportedProtocol(request.protocol)
        }
        let context = "verb=\(request.verb) run=\(request.run?.id ?? "-")"
        Self.logger.infoPublic("Handling \(context)")
        switch request.verb {
        case "describe":
            return ExtensionReply(steps: Self.steps)
        case "flow_start":
            return await failing(context, state: request.state) {
                try await flowStart(request)
            }
        case "step":
            return await failing(context, state: request.state) {
                try await step(request)
            }
        case "flow_end":
            return await failing(context, state: request.state) {
                try await flowEnd(request)
            }
        default:
            return ExtensionReply(ok: false, message: "Unknown verb \(request.verb)", state: request.state)
        }
    }

    private func failing(
        _ context: String,
        state: BridgeState?,
        _ body: () async throws -> ExtensionReply
    ) async -> ExtensionReply {
        do {
            let reply = try await body()
            Self.logger.infoPublic("Handled \(context) ok=\(reply.ok ?? true)")
            return reply
        } catch {
            Self.logger.error("Extension call failed", error: error, context: context)
            return ExtensionReply(ok: false, message: error.localizedDescription, state: state)
        }
    }

    private func flowStart(_ request: ExtensionRequest) async throws -> ExtensionReply {
        let vars = request.vars ?? [:]
        guard
            let rawPath = vars[Self.configVariable] ?? environment[Self.configEnvironmentVariable],
            !rawPath.isEmpty
        else {
            throw BridgeError.configNotGiven
        }
        let configURL =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : currentDirectory.appending(path: rawPath).standardizedFileURL
        let config = try AppConfig.load(from: configURL)
        let port = try port(vars: vars) ?? config.server.port
        guard let platform = request.run?.platform.flatMap({ Platform(rawValue: $0.lowercased()) })
        else {
            throw BridgeError.unknownPlatform(request.run?.platform)
        }
        let started = try await lifecycle(config, port: port).start(platform: platform)
        let state = BridgeState(
            configPath: configURL.path,
            port: port,
            platform: platform,
            sessionId: started.sessionId
        )
        return ExtensionReply(
            ok: true,
            message: "moqserver session \(started.sessionId) on port \(port)",
            state: state,
            launchEnvironment: started.launchEnvironment,
            vars: [Self.sessionVariable: started.sessionId]
        )
    }

    private func flowEnd(_ request: ExtensionRequest) async throws -> ExtensionReply {
        guard let state = request.state else {
            return ExtensionReply(ok: true, message: "No session to release")
        }
        let config = try AppConfig.load(from: URL(filePath: state.configPath))
        try await lifecycle(config, port: state.port).end(sessionId: state.sessionId)
        return ExtensionReply(
            ok: true, message: "Released moqserver session \(state.sessionId)", state: state)
    }

    private func step(_ request: ExtensionRequest) async throws -> ExtensionReply {
        guard let state = request.state else {
            throw BridgeError.noSession
        }
        guard let step = request.step else {
            throw BridgeError.invalidArgument(name: "step", reason: "missing from the request")
        }
        let config = try AppConfig.load(from: URL(filePath: state.configPath))
        let client = AdminClient(
            baseURL: lifecycle(config, port: state.port).adminBaseURL,
            auth: try ResolvedAdminAuth(config.server.adminAuth, environment: environment),
            transport: transport
        )
        var reply = try await StepRunner(client: client, session: state.sessionId)
            .run(tool: step.tool, arguments: StepArguments(step.arguments ?? [:]))
        reply.state = state
        return reply
    }

    private func port(vars: [String: String]) throws -> Int? {
        guard let raw = vars[Self.portVariable] ?? environment[Self.portEnvironmentVariable],
            !raw.isEmpty
        else {
            return nil
        }
        guard let port = Int(raw), (1...65535).contains(port) else {
            throw BridgeError.invalidArgument(name: Self.portVariable, reason: "'\(raw)' is not a port")
        }
        return port
    }

    private func lifecycle(_ config: AppConfig, port: Int) -> SessionLifecycle {
        SessionLifecycle(
            config: config,
            portOverride: port,
            environment: environment,
            transport: transport,
            pollInterval: pollInterval
        )
    }
}
