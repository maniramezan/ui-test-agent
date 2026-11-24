import ExtensionKit
import Foundation

/// The `auth` section of the per-app config: which identity-provider emulator the flow's account
/// steps act on.
public struct AuthConfig: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable {
        case firebaseEmulator = "firebase-emulator"
    }

    public var provider: Provider
    /// `host:port` of the emulator as this Mac reaches it. Falls back to
    /// `FIREBASE_AUTH_EMULATOR_HOST`.
    public var host: String?
    public var projectId: String

    public static let hostEnvironmentVariable = "FIREBASE_AUTH_EMULATOR_HOST"

    public init(provider: Provider, host: String?, projectId: String) {
        self.provider = provider
        self.host = host
        self.projectId = projectId
    }

    private struct File: Decodable {
        let auth: AuthConfig?
    }

    /// Reads the `auth` section of the per-app config file at `url`.
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
        guard !auth.projectId.isEmpty else {
            throw AuthError.configInvalid(path: url.path, problem: "auth.projectId is empty")
        }
        return auth
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
