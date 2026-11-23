import Foundation

/// The app platforms a per-app config can describe.
public enum Platform: String, Codable, CaseIterable, Sendable {
    case ios
    case android
}

/// How the bridge authenticates to moqserver's admin API.
///
/// Credentials are named by environment variable, never stored in the config file.
public enum AdminAuth: Codable, Sendable, Equatable {
    case none
    case bearer(tokenEnv: String)
    case apiKey(header: String, valueEnv: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case tokenEnv
        case header
        case valueEnv
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "none":
            self = .none
        case "bearer":
            self = .bearer(tokenEnv: try container.decode(String.self, forKey: .tokenEnv))
        case "apiKey":
            self = .apiKey(
                header: try container.decode(String.self, forKey: .header),
                valueEnv: try container.decode(String.self, forKey: .valueEnv)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown adminAuth kind '\(kind)'; expected none, bearer or apiKey"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .bearer(let tokenEnv):
            try container.encode("bearer", forKey: .kind)
            try container.encode(tokenEnv, forKey: .tokenEnv)
        case .apiKey(let header, let valueEnv):
            try container.encode("apiKey", forKey: .kind)
            try container.encode(header, forKey: .header)
            try container.encode(valueEnv, forKey: .valueEnv)
        }
    }
}

/// One app's mock setup: where moqserver listens, how to reach its admin API, and which launch
/// keys hand the base URL and session to the app on each platform.
public struct AppConfig: Codable, Sendable, Equatable {
    public struct Server: Codable, Sendable, Equatable {
        public var port: Int
        public var adminHost: String
        public var readinessPath: String
        public var readinessTimeoutSeconds: Double
        public var adminAuth: AdminAuth
    }

    public struct PlatformConfig: Codable, Sendable, Equatable {
        /// The host the app uses to reach moqserver (`10.0.2.2` from an Android emulator).
        public var appHost: String
        /// Whether this platform's runs serve with `--require-session`. Later session checks
        /// need it: without it, session-less calls land in global history.
        public var requireSession: Bool
        /// Launch keys and values. Values may use `{{baseURL}}` and `{{sessionId}}`.
        public var launchEnvironment: [String: String]
    }

    public var app: String
    public var server: Server
    public var platforms: [String: PlatformConfig]

    public static func load(from url: URL) throws -> AppConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BridgeError.configUnreadable(path: url.path, reason: error.localizedDescription)
        }
        let config: AppConfig
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw BridgeError.configInvalid(path: url.path, problems: [String(describing: error)])
        }
        let problems = config.problems()
        guard problems.isEmpty else {
            throw BridgeError.configInvalid(path: url.path, problems: problems)
        }
        return config
    }

    /// Everything wrong with the config, empty when it is usable.
    public func problems() -> [String] {
        var problems: [String] = []
        if app.isEmpty {
            problems.append("app is empty")
        }
        if !(1...65535).contains(server.port) {
            problems.append("server.port \(server.port) is outside 1-65535")
        }
        if !server.readinessPath.hasPrefix("/") {
            problems.append("server.readinessPath must start with /")
        }
        if server.readinessTimeoutSeconds <= 0 {
            problems.append("server.readinessTimeoutSeconds must be positive")
        }
        if platforms.isEmpty {
            problems.append("platforms is empty")
        }
        for (key, platform) in platforms.sorted(by: { $0.key < $1.key }) {
            guard Platform(rawValue: key) != nil else {
                problems.append("platforms.\(key) is not one of \(Platform.allCases.map(\.rawValue))")
                continue
            }
            var usesSession = false
            for (name, value) in platform.launchEnvironment.sorted(by: { $0.key < $1.key }) {
                let used = LaunchTemplate.placeholders(in: value)
                usesSession = usesSession || used.contains(LaunchTemplate.sessionId)
                for unknown in used where !LaunchTemplate.known.contains(unknown) {
                    problems.append(
                        "platforms.\(key).launchEnvironment.\(name) uses unknown placeholder {{\(unknown)}}"
                    )
                }
            }
            if !usesSession {
                problems.append(
                    "platforms.\(key).launchEnvironment has no {{\(LaunchTemplate.sessionId)}}, so the app would never join its session"
                )
            }
        }
        return problems
    }

    public func platformConfig(for platform: Platform) throws -> PlatformConfig {
        guard let config = platforms[platform.rawValue] else {
            throw BridgeError.platformNotConfigured(platform: platform.rawValue, app: app)
        }
        return config
    }
}
