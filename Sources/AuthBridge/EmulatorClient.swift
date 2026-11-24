import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

/// What flow_end needs to put an account back the way the run found it.
public struct AccountSnapshot: Codable, Sendable, Equatable {
    /// The fields `accounts:batchCreate` takes back as they came from `accounts:lookup`.
    static let restorableFields = [
        "localId", "email", "emailVerified", "displayName", "photoUrl", "phoneNumber",
        "customAttributes", "disabled", "createdAt", "lastLoginAt", "providerUserInfo",
    ]

    public var localId: String
    public var disabled: Bool
    /// The restorable fields, unchanged.
    public var record: [String: JSONValue]
    /// The emulator stores a password as `fakeHash:salt=…:password=<plain>`; nil for an account
    /// without one.
    public var password: String?

    init(lookup user: [String: JSONValue]) throws {
        guard case .string(let localId) = user["localId"] else {
            throw AuthError.malformedResponse(action: "accounts:lookup")
        }
        self.localId = localId
        if case .bool(let disabled) = user["disabled"] {
            self.disabled = disabled
        } else {
            self.disabled = false
        }
        record = user.filter { Self.restorableFields.contains($0.key) }
        if case .string(let hash) = user["passwordHash"], let range = hash.range(of: ":password=") {
            password = String(hash[range.upperBound...])
        }
    }
}

/// The Firebase Auth emulator's admin REST routes, authorized with the emulator's `owner` token.
/// They exist on the emulator only; production rejects that token.
struct EmulatorClient {
    private static let logger = Logger.forType(subsystem: "UITestAgent", EmulatorClient.self)

    let host: String
    let projectId: String
    let transport: any HTTPTransport

    private var root: URL {
        get throws {
            guard let url = URL(string: "http://\(host)/") else {
                throw AuthError.notAnEmulator(host: host)
            }
            return url
        }
    }

    private func accounts(_ action: String) throws -> URL {
        try root.appending(path: "identitytoolkit.googleapis.com/v1/projects")
            .appending(path: projectId)
            .appending(path: "accounts:\(action)")
    }

    func checkReachable() async throws {
        let url = try root
        do {
            let (_, response) = try await transport.send(URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else {
                throw AuthError.emulatorNotReachable(url: url.absoluteString, projectId: projectId)
            }
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.emulatorNotReachable(url: url.absoluteString, projectId: projectId)
        }
    }

    /// The account with this email, or nil when there is none.
    func lookup(email: String) async throws -> AccountSnapshot? {
        let body = try await post("lookup", ["email": .array([.string(email)])])
        guard case .array(let users) = body["users"], case .object(let user) = users.first else {
            return nil
        }
        return try AccountSnapshot(lookup: user)
    }

    func update(localId: String, _ fields: [String: JSONValue]) async throws {
        try await post("update", fields.merging(["localId": .string(localId)]) { _, new in new })
    }

    func delete(localId: String) async throws {
        try await post("delete", ["localId": .string(localId)])
    }

    /// Recreates a deleted account with its original id and fields, then its password.
    func recreate(_ snapshot: AccountSnapshot) async throws {
        let body = try await post("batchCreate", ["users": .array([.object(snapshot.record)])])
        if case .array(let errors) = body["error"], !errors.isEmpty {
            throw AuthError.emulatorRefused(
                action: "accounts:batchCreate", status: 200, reason: "\(errors.count) account(s) not created")
        }
        if let password = snapshot.password {
            try await update(localId: snapshot.localId, ["password": .string(password)])
        }
    }

    @discardableResult
    private func post(_ action: String, _ fields: [String: JSONValue]) async throws -> [String: JSONValue] {
        let url = try accounts(action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        Self.logger.debugPublic("POST accounts:\(action) project=\(projectId)")
        let (data, response) = try await transport.send(request)
        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            var reason: String?
            if case .object(let object) = body, case .object(let error) = object["error"],
                case .string(let message) = error["message"]
            {
                reason = message
            }
            throw AuthError.emulatorRefused(
                action: "accounts:\(action)", status: response.statusCode, reason: reason)
        }
        guard case .object(let object) = body else {
            throw AuthError.malformedResponse(action: "accounts:\(action)")
        }
        Self.logger.debugPublic("accounts:\(action) answered \(response.statusCode)")
        return object
    }
}
