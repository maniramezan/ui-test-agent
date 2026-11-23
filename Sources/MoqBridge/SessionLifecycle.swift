import Foundation
import OSLog
import SwiftCommons

/// What a started session hands to amoo: the id to release later and the launch keys to merge
/// into every app launch.
public struct StartedSession: Codable, Sendable, Equatable {
    public var sessionId: String
    public var platform: Platform
    public var adminBaseURL: String
    public var requireSession: Bool
    public var launchEnvironment: [String: String]
}

/// Attaches to a running moqserver, opens an isolated session and renders the app's launch keys;
/// releases the session at the end.
public struct SessionLifecycle: Sendable {
    private static let logger = Logger.forType(subsystem: "UITestAgent", SessionLifecycle.self)

    private let config: AppConfig
    private let port: Int
    private let environment: [String: String]
    private let transport: any HTTPTransport
    private let pollInterval: Duration

    public init(
        config: AppConfig,
        portOverride: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(),
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.config = config
        self.port = portOverride ?? config.server.port
        self.environment = environment
        self.transport = transport
        self.pollInterval = pollInterval
    }

    public var adminBaseURL: URL {
        Self.url(host: config.server.adminHost, port: port)
    }

    public func start(platform: Platform) async throws -> StartedSession {
        let platformConfig = try config.platformConfig(for: platform)
        let client = try adminClient()
        let context = "app=\(config.app) platform=\(platform.rawValue) port=\(port)"
        do {
            Self.logger.infoPublic("Waiting for moqserver: \(context)")
            try await waitUntilReady(client)
            let sessionId = try await client.createSession()
            let launchEnvironment = try LaunchTemplate.render(
                platformConfig.launchEnvironment,
                values: [
                    LaunchTemplate.baseURL: Self.url(host: platformConfig.appHost, port: port)
                        .absoluteString,
                    LaunchTemplate.sessionId: sessionId,
                ]
            )
            Self.logger.infoPublic("Session \(sessionId) ready: \(context)")
            return StartedSession(
                sessionId: sessionId,
                platform: platform,
                adminBaseURL: adminBaseURL.absoluteString,
                requireSession: platformConfig.requireSession,
                launchEnvironment: launchEnvironment
            )
        } catch {
            Self.logger.error("Session start failed", error: error, context: context)
            throw error
        }
    }

    public func end(sessionId: String) async throws {
        let context = "app=\(config.app) session=\(sessionId) port=\(port)"
        do {
            try await adminClient().releaseSession(sessionId)
        } catch {
            Self.logger.error("Session release failed", error: error, context: context)
            throw error
        }
    }

    private func adminClient() throws -> AdminClient {
        AdminClient(
            baseURL: adminBaseURL,
            auth: try ResolvedAdminAuth(config.server.adminAuth, environment: environment),
            transport: transport
        )
    }

    private func waitUntilReady(_ client: AdminClient) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(config.server.readinessTimeoutSeconds * 1000))
        while true {
            if try await client.isReady(path: config.server.readinessPath) {
                return
            }
            guard clock.now < deadline else {
                throw BridgeError.serverNotReady(
                    url: client.baseURL.appending(path: config.server.readinessPath).absoluteString,
                    seconds: config.server.readinessTimeoutSeconds
                )
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func url(host: String, port: Int) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        guard let url = components.url else {
            preconditionFailure("http://\(host):\(port) is not a URL")
        }
        return url
    }
}
