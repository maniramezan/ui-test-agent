import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

/// What the auth extension keeps between calls in one amoo run.
public struct AuthState: Codable, Sendable, Equatable {
    public var configPath: String
    public var host: String
    public var projectId: String
    /// Each account a step changed, by email, as the run first found it.
    public var originals: [String: AccountSnapshot]?

    public init(
        configPath: String, host: String, projectId: String, originals: [String: AccountSnapshot]? = nil
    ) {
        self.configPath = configPath
        self.host = host
        self.projectId = projectId
        self.originals = originals
    }
}

public typealias AuthRequest = FlowRequest<AuthState>
public typealias AuthReply = FlowReply<AuthState>

/// Answers amoo's flow-extension verbs for `auth.*` steps: account fixtures on an identity-provider
/// emulator, put back at flow end so runs stay independent.
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

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(),
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.transport = transport
        self.currentDirectory = currentDirectory
        self.now = now
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
        let host = try config.resolvedHost(environment: environment)
        try await client(host: host, projectId: config.projectId).checkReachable()
        return AuthReply(
            ok: true,
            message: "Auth emulator at \(host), project \(config.projectId)",
            state: AuthState(configPath: configURL.path, host: host, projectId: config.projectId)
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
        let client = client(host: state.host, projectId: state.projectId)
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

    /// Puts every changed account back: re-enables or re-disables it as it was, or recreates it
    /// when a step deleted it. A token revocation can't be undone and is left as is.
    private func flowEnd(_ request: AuthRequest) async -> AuthReply {
        guard let state = request.state, let originals = state.originals, !originals.isEmpty else {
            return AuthReply(ok: true, message: "No accounts to restore")
        }
        let client = client(host: state.host, projectId: state.projectId)
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
