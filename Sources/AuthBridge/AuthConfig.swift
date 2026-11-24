import ExtensionKit
import Foundation

/// The `auth` section of the per-app config: where the flow's account steps act.
public struct AuthConfig: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable {
        /// The Firebase Auth emulator's admin routes.
        case firebaseEmulator = "firebase-emulator"
        /// Test-support routes of the app's own backend.
        case testRoutes = "test-routes"
    }

    /// One backend route. `path` may hold `{email}` and `{session}`.
    public struct Route: Codable, Sendable, Equatable {
        public var method: String
        public var path: String

        public init(method: String, path: String) {
            self.method = method
            self.path = path
        }
    }

    public var provider: Provider
    /// `firebase-emulator`: `host:port` of the emulator as this Mac reaches it. Falls back to
    /// `FIREBASE_AUTH_EMULATOR_HOST`.
    public var host: String?
    /// `firebase-emulator`: the emulator project.
    public var projectId: String?
    /// `test-routes`: the backend as this Mac reaches it. Loopback only.
    public var baseURL: String?
    /// `test-routes`: the header that names a run's own data set on the backend. With it, each
    /// run gets a fresh id, sent on every route call and given to the app through
    /// `launchEnvironment`.
    public var sessionHeader: String?
    /// `test-routes`: launch keys for the app; values may use `{{sessionId}}` and `{{baseURL}}`.
    public var launchEnvironment: [String: String]?
    /// `test-routes`: a route per step name (`disable_user`, …), plus `release`, called at flow
    /// end to drop the run's data set.
    public var routes: [String: Route]?

    public static let hostEnvironmentVariable = "FIREBASE_AUTH_EMULATOR_HOST"
    public static let releaseRoute = "release"
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public init(
        provider: Provider,
        host: String? = nil,
        projectId: String? = nil,
        baseURL: String? = nil,
        sessionHeader: String? = nil,
        launchEnvironment: [String: String]? = nil,
        routes: [String: Route]? = nil
    ) {
        self.provider = provider
        self.host = host
        self.projectId = projectId
        self.baseURL = baseURL
        self.sessionHeader = sessionHeader
        self.launchEnvironment = launchEnvironment
        self.routes = routes
    }

    private struct File: Decodable {
        let auth: AuthConfig?
    }

    /// Reads and checks the `auth` section of the per-app config file at `url`.
    public static func load(from url: URL) throws -> AuthConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AuthError.configUnreadable(path: url.path, reason: error.localizedDescription)
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw AuthError.configInvalid(path: url.path, problem: String(describing: error))
        }
        guard let auth = file.auth else {
            throw AuthError.configInvalid(path: url.path, problem: "no auth section")
        }
        if let problem = auth.problem {
            throw AuthError.configInvalid(path: url.path, problem: problem)
        }
        return auth
    }

    /// What is wrong with this section, or nil.
    var problem: String? {
        switch provider {
        case .firebaseEmulator:
            return (projectId ?? "").isEmpty ? "auth.projectId is empty" : nil
        case .testRoutes:
            return testRoutesProblem
        }
    }

    private var testRoutesProblem: String? {
        guard let baseURL, let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host(),
            ["http", "https"].contains(scheme)
        else {
            return "auth.baseURL must be an http(s) URL"
        }
        guard Self.loopbackHosts.contains(host.lowercased()) else {
            return "auth.baseURL is \(host); test routes are only called on this Mac (127.0.0.1 or localhost)"
        }
        let routes = routes ?? [:]
        guard !routes.isEmpty else {
            return "auth.routes is empty"
        }
        let known = Set(AuthHandler.steps).union([Self.releaseRoute])
        for (name, route) in routes.sorted(by: { $0.key < $1.key }) {
            guard known.contains(name) else {
                return "auth.routes.\(name) is not a step; use \(known.sorted().joined(separator: ", "))"
            }
            guard Self.methods.contains(route.method) else {
                return "auth.routes.\(name).method must be one of \(Self.methods.sorted().joined(separator: ", "))"
            }
            guard route.path.hasPrefix("/") else {
                return "auth.routes.\(name).path must start with /"
            }
            let allowed: Set<String> = name == Self.releaseRoute ? ["session"] : ["email", "session"]
            for placeholder in Self.placeholders(in: route.path, open: "{", close: "}") where !allowed.contains(placeholder) {
                return "auth.routes.\(name).path uses unknown placeholder {\(placeholder)}"
            }
        }
        let usesSession = (launchEnvironment ?? [:]).values.contains {
            Self.placeholders(in: $0, open: "{{", close: "}}").contains("sessionId")
        }
        for (key, value) in (launchEnvironment ?? [:]).sorted(by: { $0.key < $1.key }) {
            for placeholder in Self.placeholders(in: value, open: "{{", close: "}}")
            where !["sessionId", "baseURL"].contains(placeholder) {
                return "auth.launchEnvironment.\(key) uses unknown placeholder {{\(placeholder)}}"
            }
        }
        if let sessionHeader {
            guard !sessionHeader.isEmpty else {
                return "auth.sessionHeader is empty"
            }
            guard usesSession else {
                return "auth.launchEnvironment has no {{sessionId}}, so the app would never join the run's session"
            }
        } else {
            if usesSession {
                return "auth.launchEnvironment uses {{sessionId}} but auth.sessionHeader is not set"
            }
            if routes[Self.releaseRoute] != nil {
                return "auth.routes.release needs auth.sessionHeader"
            }
        }
        return nil
    }

    /// The names between `open` and `close` markers in `text`, in order.
    static func placeholders(in text: String, open: String, close: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
            names.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return names
    }

    /// `text` with each `open name close` replaced by its value; an unknown name is left as is.
    static func render(_ text: String, open: String, close: String, values: [String: String]) -> String {
        var result = text
        for (name, value) in values {
            result = result.replacingOccurrences(of: open + name + close, with: value)
        }
        return result
    }

    /// The emulator's `host:port`. A Google host is refused: these steps only ever act on an
    /// emulator.
    public func resolvedHost(environment: [String: String]) throws -> String {
        guard let host = host ?? environment[Self.hostEnvironmentVariable], !host.isEmpty else {
            throw AuthError.hostNotGiven
        }
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        guard !name.hasSuffix("googleapis.com"), !name.hasSuffix("google.com") else {
            throw AuthError.notAnEmulator(host: host)
        }
        return host
    }
}
