import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

/// What the auth extension keeps between calls in one amoo run.
public struct AuthState: Codable, Sendable, Equatable {
    public var configPath: String
    /// `firebase-emulator`: the emulator's `host:port` and project.
    public var host: String?
    public var projectId: String?
    /// `firebase-emulator`: each account a step changed, by email, as the run first found it.
    public var originals: [String: AccountSnapshot]?
    /// `test-routes`: the backend and the run's session on it.
    public var backend: BackendState?

    public init(
        configPath: String,
        host: String? = nil,
        projectId: String? = nil,
        originals: [String: AccountSnapshot]? = nil,
        backend: BackendState? = nil
    ) {
        self.configPath = configPath
        self.host = host
        self.projectId = projectId
        self.originals = originals
        self.backend = backend
    }
}

public typealias AuthRequest = FlowRequest<AuthState>
public typealias AuthReply = FlowReply<AuthState>

/// Answers amoo's flow-extension verbs for `auth.*` steps: account fixtures on an identity-provider
/// emulator or through the backend's own test routes, put back at flow end so runs stay independent.
public struct AuthHandler: Sendable {
    public static let configVariable = "auth_config"
    public static let moqConfigVariable = "moq_config"
    public static let configEnvironmentVariable = "AMOO_EXT_AUTH_CONFIG"

    /// The steps this build implements, each taking `{email}`.
    public static let steps = ["disable_user", "enable_user", "delete_user", "revoke_tokens"]

    private static let logger = Logger.forType(subsystem: "UITestAgent", AuthHandler.self)

    private let environment: [String: String]
    private let transport: any HTTPTransport
    private let currentDirectory: URL
    private let now: @Sendable () -> Date
    private let makeSessionID: @Sendable () -> String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(),
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.environment = environment
        self.transport = transport
        self.currentDirectory = currentDirectory
        self.now = now
        self.makeSessionID = makeSessionID
    }

    public func handle(_ request: AuthRequest) async throws -> AuthReply {
        guard request.protocol == AuthReply.protocolVersion else {
            throw ArgumentError(name: "protocol", reason: "amoo sent \(request.protocol); this extension speaks 1")
        }
        let context = "verb=\(request.verb) run=\(request.run?.id ?? "-")"
        Self.logger.infoPublic("Handling \(context)")
        do {
            let reply: AuthReply
            switch request.verb {
            case "describe":
                reply = AuthReply(steps: Self.steps)
            case "flow_start":
                reply = try await flowStart(request)
            case "step":
                reply = try await step(request)
            case "flow_end":
                reply = await flowEnd(request)
            default:
                reply = AuthReply(ok: false, message: "Unknown verb \(request.verb)", state: request.state)
            }
            Self.logger.infoPublic("Handled \(context) ok=\(reply.ok ?? true)")
            return reply
        } catch {
            Self.logger.error("Extension call failed", error: error, context: context)
            return AuthReply(ok: false, message: error.localizedDescription, state: request.state)
        }
    }

    private func flowStart(_ request: AuthRequest) async throws -> AuthReply {
        let vars = request.vars ?? [:]
        guard
            let rawPath = vars[Self.configVariable] ?? vars[Self.moqConfigVariable]
                ?? environment[Self.configEnvironmentVariable],
            !rawPath.isEmpty
        else {
            throw AuthError.configNotGiven
        }
        let configURL =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : currentDirectory.appending(path: rawPath).standardizedFileURL
        let config = try AuthConfig.load(from: configURL)
        switch config.provider {
        case .firebaseEmulator:
            let host = try config.resolvedHost(environment: environment)
            let projectId = config.projectId ?? ""
            try await client(host: host, projectId: projectId).checkReachable()
            return AuthReply(
                ok: true,
                message: "Auth emulator at \(host), project \(projectId)",
                state: AuthState(configPath: configURL.path, host: host, projectId: projectId)
            )
        case .testRoutes:
            return try await backendFlowStart(config, configPath: configURL.path)
        }
    }

    /// `test-routes`: checks the backend answers and, when the config names a session header,
    /// gives the run its own session and the app the launch keys to join it.
    private func backendFlowStart(_ config: AuthConfig, configPath: String) async throws -> AuthReply {
        let baseURL = config.baseURL ?? ""
        let session = config.sessionHeader == nil ? nil : makeSessionID()
        let backend = BackendState(
            baseURL: baseURL, sessionHeader: config.sessionHeader, session: session, routes: config.routes ?? [:])
        try await TestRoutesClient(state: backend, transport: transport).checkReachable()
        var values = ["baseURL": baseURL]
        values["sessionId"] = session
        let launchEnvironment = (config.launchEnvironment ?? [:]).mapValues {
            AuthConfig.render($0, open: "{{", close: "}}", values: values)
        }
        return AuthReply(
            ok: true,
            message: session == nil
                ? "Backend test routes at \(baseURL), shared data"
                : "Backend test routes at \(baseURL), in a session of this run's own",
            state: AuthState(configPath: configPath, backend: backend),
            launchEnvironment: launchEnvironment.isEmpty ? nil : launchEnvironment
        )
    }

    private func step(_ request: AuthRequest) async throws -> AuthReply {
        guard var state = request.state else {
            throw AuthError.noRunState
        }
        guard let step = request.step else {
            throw ArgumentError(name: "step", reason: "missing from the request")
        }
        var arguments = StepArguments(step.arguments ?? [:])
        let email = try arguments.string("email")
        try arguments.finish()
        guard Self.steps.contains(step.tool) else {
            throw ArgumentError(name: "tool", reason: "auth.\(step.tool) is not a step of this build")
        }
        if let backend = state.backend {
            return try await backendStep(step.tool, email: email, backend: backend, state: state)
        }
        guard let host = state.host, let projectId = state.projectId else {
            throw AuthError.noRunState
        }
        let client = client(host: host, projectId: projectId)
        guard let account = try await client.lookup(email: email) else {
            throw AuthError.noAccount(email: email)
        }
        var originals = state.originals ?? [:]
        if originals[email] == nil {
            originals[email] = account
        }
        state.originals = originals

        let message: String
        var result: [String: JSONValue] = ["email": .string(email), "local_id": .string(account.localId)]
        switch step.tool {
        case "disable_user":
            try await client.update(localId: account.localId, ["disableUser": .bool(true)])
            message = "Disabled \(email)"
            result["disabled"] = .bool(true)
        case "enable_user":
            try await client.update(localId: account.localId, ["disableUser": .bool(false)])
            message = "Enabled \(email)"
            result["disabled"] = .bool(false)
        case "delete_user":
            try await client.delete(localId: account.localId)
            message = "Deleted \(email); flow_end recreates it"
            result["deleted"] = .bool(true)
        case "revoke_tokens":
            let seconds = Int(now().timeIntervalSince1970)
            try await client.update(localId: account.localId, ["validSince": .string(String(seconds))])
            message =
                "Revoked tokens of \(email) issued before \(seconds). The emulator rejects older ID tokens but still refreshes old refresh tokens"
            result["valid_since"] = .number(Double(seconds))
        default:
            throw ArgumentError(name: "tool", reason: "auth.\(step.tool) is not a step of this build")
        }
        return AuthReply(ok: true, message: message, result: .object(result), state: state)
    }

    /// `test-routes`: calls the step's route. Inside a session nothing needs undoing; outside one,
    /// the first change to each account is kept for flow_end.
    private func backendStep(
        _ tool: String, email: String, backend: BackendState, state: AuthState
    ) async throws -> AuthReply {
        var backend = backend
        let status = try await TestRoutesClient(state: backend, transport: transport).call(tool, email: email)
        guard (200..<300).contains(status) else {
            throw AuthError.backendRefused(step: tool, status: status)
        }
        if backend.session == nil {
            var changed = backend.changed ?? [:]
            if changed[email] == nil {
                changed[email] = tool
            }
            backend.changed = changed
        }
        var state = state
        state.backend = backend
        return AuthReply(
            ok: true,
            message: "\(tool) done for \(email)",
            result: .object(["email": .string(email), "status": .number(Double(status))]),
            state: state)
    }

    /// The step that undoes `tool`, when there is one.
    static func opposite(of tool: String) -> String? {
        switch tool {
        case "disable_user": "enable_user"
        case "enable_user": "disable_user"
        default: nil
        }
    }

    /// `test-routes`: drops the run's session, or, without one, undoes the first change to each
    /// account by calling the opposite route.
    private func backendFlowEnd(_ backend: BackendState, state: AuthState) async -> AuthReply {
        let client = TestRoutesClient(state: backend, transport: transport)
        if backend.session != nil {
            guard backend.routes[AuthConfig.releaseRoute] != nil else {
                return AuthReply(
                    ok: true, message: "No release route: the run's session stays on the backend until it restarts",
                    state: state)
            }
            do {
                let status = try await client.call(AuthConfig.releaseRoute)
                // 404: nothing reached the backend in this session, so there was nothing to drop.
                guard (200..<300).contains(status) || status == 404 else {
                    return AuthReply(
                        ok: false, message: "The release route answered \(status); the session stays", state: state)
                }
                Self.logger.infoPublic("Released the backend session status=\(status)")
                return AuthReply(ok: true, message: "Released the run's backend session", state: state)
            } catch {
                Self.logger.error("Could not release the backend session", error: error, context: "verb=flow_end")
                return AuthReply(ok: false, message: error.localizedDescription, state: state)
            }
        }
        guard let changed = backend.changed, !changed.isEmpty else {
            return AuthReply(ok: true, message: "No accounts to restore")
        }
        var failures: [String] = []
        for (email, tool) in changed.sorted(by: { $0.key < $1.key }) {
            guard let undo = Self.opposite(of: tool) else {
                failures.append("\(email): \(tool) can't be undone")
                continue
            }
            do {
                let status = try await client.call(undo, email: email)
                guard (200..<300).contains(status) else {
                    throw AuthError.backendRefused(step: undo, status: status)
                }
                Self.logger.infoPublic("Restored an account with \(undo)")
            } catch {
                Self.logger.error("Could not restore account", error: error, context: "undo=\(undo)")
                failures.append("\(email): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            return AuthReply(
                ok: false, message: "Could not restore " + failures.joined(separator: "; "), state: state)
        }
        return AuthReply(ok: true, message: "Restored \(changed.count) account(s)", state: state)
    }

    /// Puts every changed account back: re-enables or re-disables it as it was, or recreates it
    /// when a step deleted it. A token revocation can't be undone and is left as is.
    private func flowEnd(_ request: AuthRequest) async -> AuthReply {
        if let state = request.state, let backend = state.backend {
            return await backendFlowEnd(backend, state: state)
        }
        guard let state = request.state, let originals = state.originals, !originals.isEmpty,
            let host = state.host, let projectId = state.projectId
        else {
            return AuthReply(ok: true, message: "No accounts to restore")
        }
        let client = client(host: host, projectId: projectId)
        var failures: [String] = []
        for (email, original) in originals.sorted(by: { $0.key < $1.key }) {
            do {
                if let current = try await client.lookup(email: email) {
                    if current.disabled != original.disabled {
                        try await client.update(localId: current.localId, ["disableUser": .bool(original.disabled)])
                    }
                } else {
                    try await client.recreate(original)
                }
                Self.logger.infoPublic("Restored account \(original.localId)")
            } catch {
                Self.logger.error("Could not restore account", error: error, context: "localId=\(original.localId)")
                failures.append("\(email): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            return AuthReply(
                ok: false, message: "Could not restore " + failures.joined(separator: "; "), state: state)
        }
        return AuthReply(ok: true, message: "Restored \(originals.count) account(s)", state: state)
    }

    private func client(host: String, projectId: String) -> EmulatorClient {
        EmulatorClient(host: host, projectId: projectId, transport: transport)
    }
}
