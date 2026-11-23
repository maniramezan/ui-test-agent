import Foundation
import OSLog
import SwiftCommons

/// Sends one HTTP request. Swapped for a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.malformedResponse(url: request.url?.absoluteString ?? "")
        }
        return (data, http)
    }
}

/// Admin credentials resolved from the environment. The value never leaves this type except in
/// the request header.
public struct ResolvedAdminAuth: Sendable {
    fileprivate enum Credential: Sendable {
        case none
        case header(name: String, value: String)
    }

    fileprivate let credential: Credential

    public static let none = ResolvedAdminAuth(credential: .none)

    public init(_ auth: AdminAuth, environment: [String: String]) throws {
        switch auth {
        case .none:
            credential = .none
        case .bearer(let tokenEnv):
            guard let token = environment[tokenEnv], !token.isEmpty else {
                throw BridgeError.missingAdminCredential(environmentVariable: tokenEnv)
            }
            credential = .header(name: "Authorization", value: "Bearer \(token)")
        case .apiKey(let header, let valueEnv):
            guard let value = environment[valueEnv], !value.isEmpty else {
                throw BridgeError.missingAdminCredential(environmentVariable: valueEnv)
            }
            credential = .header(name: header, value: value)
        }
    }

    private init(credential: Credential) {
        self.credential = credential
    }

    fileprivate func apply(to request: inout URLRequest) {
        if case .header(let name, let value) = credential {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}

/// An endpoint as moqserver keys it: `"GET /v1/words/{id}"`, plus a GraphQL operation if any.
public struct EndpointRef: Sendable, Equatable {
    public var method: String
    public var path: String
    public var operation: String?

    public init(_ key: String, operation: String? = nil) throws {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
            throw BridgeError.invalidArgument(
                name: "endpoint", reason: "expected \"METHOD /path\", got \"\(key)\"")
        }
        method = parts[0].uppercased()
        path = parts[1]
        self.operation = operation
    }

    public var key: String {
        "\(method) \(path)"
    }
}

/// One row of `GET /_admin/requests`, limited to the fields the bridge reads. The full shape is
/// in moqserver's RUNTIME_WORKFLOWS.md, "Asserting what the app sent".
public struct RequestRecord: Decodable, Sendable, Equatable {
    public struct Rejection: Decodable, Sendable, Equatable {
        public var kind: String
        public var code: String
        public var message: String
    }

    public var method: String
    public var path: String
    public var endpoint: String?
    public var status: Int?
    public var timestamp: Double?
    public var rejection: Rejection?
}

/// A server-side query verdict: `ok`, the server's message, and the whole response body
/// (`matched`, `nearMisses`, `unattributed`, …) for the step's report.
public struct QueryVerdict: Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public var body: JSONValue
}

/// The moqserver admin routes the bridge needs, as documented in moqserver's ADMIN_API.md.
public struct AdminClient: Sendable {
    private static let logger = Logger.forType(subsystem: "UITestAgent", AdminClient.self)

    public let baseURL: URL
    private let auth: ResolvedAdminAuth
    private let transport: any HTTPTransport

    public init(baseURL: URL, auth: ResolvedAdminAuth, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.auth = auth
        self.transport = transport
    }

    /// True when `path` answers 2xx. Connection failures and other statuses mean not ready yet;
    /// a 401 throws, since waiting won't fix wrong credentials.
    public func isReady(path: String) async throws -> Bool {
        let url = baseURL.appending(path: path)
        do {
            let (_, response) = try await send("GET", url: url)
            if response.statusCode == 401 {
                throw BridgeError.adminUnauthorized(url: url.absoluteString)
            }
            return (200..<300).contains(response.statusCode)
        } catch let error as BridgeError {
            throw error
        } catch {
            Self.logger.debugPublic("Readiness probe failed at \(url.absoluteString); retrying")
            return false
        }
    }

    public func createSession() async throws -> String {
        let url = baseURL.appending(path: "_admin/sessions")
        Self.logger.infoPublic("Creating moqserver session at \(url.absoluteString)")
        let (data, response) = try await send("POST", url: url)
        try Self.check(response, data: data, method: "POST", url: url)
        struct Created: Decodable {
            let id: String
        }
        guard let created = try? JSONDecoder().decode(Created.self, from: data), !created.id.isEmpty
        else {
            throw BridgeError.malformedResponse(url: url.absoluteString)
        }
        Self.logger.infoPublic("Created moqserver session \(created.id)")
        return created.id
    }

    /// Releases a session. Idempotent: an already-gone session (404) counts as released.
    public func releaseSession(_ id: String) async throws {
        let url = baseURL.appending(path: "_admin/sessions").appending(path: id)
        Self.logger.infoPublic("Releasing moqserver session \(id)")
        let (data, response) = try await send("DELETE", url: url)
        if response.statusCode == 404 {
            Self.logger.infoPublic("Session \(id) was already gone")
            return
        }
        try Self.check(response, data: data, method: "DELETE", url: url)
        Self.logger.infoPublic("Released moqserver session \(id)")
    }

    public func activateScenario(_ name: String, session: String) async throws {
        let url = baseURL.appending(path: "_admin/scenario")
        try await call("PUT", url: url, session: session, json: ["name": name])
    }

    /// Overrides the endpoint's variant in this session; with `times`, only for that many
    /// requests that reach variant selection, after which normal selection resumes.
    public func selectVariant(
        _ variant: String, for endpoint: EndpointRef, times: Int? = nil, session: String
    ) async throws {
        struct Selection: Encodable {
            let variant: String
            let times: Int?
        }
        let url = endpointURL(endpoint, subresource: "variant")
        try await call("PUT", url: url, session: session, json: Selection(variant: variant, times: times))
    }

    /// The server's current time, Unix seconds, for a later query's `since`.
    public func mark(session: String) async throws -> Double {
        let url = baseURL.appending(path: "_admin/requests/mark")
        let data = try await call("POST", url: url, session: session)
        guard let marked = try? JSONDecoder().decode([String: Double].self, from: data),
            let timestamp = marked["timestamp"]
        else {
            throw BridgeError.malformedResponse(url: url.absoluteString)
        }
        return timestamp
    }

    /// Evaluates a request query on the server (`POST /_admin/requests/query`) and returns its
    /// verdict as sent.
    public func query(_ query: JSONValue, session: String) async throws -> QueryVerdict {
        let url = baseURL.appending(path: "_admin/requests/query")
        let data = try await call("POST", url: url, session: session, json: query)
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = body,
            case .bool(let ok) = fields["ok"]
        else {
            throw BridgeError.malformedResponse(url: url.absoluteString)
        }
        var message: String?
        if case .string(let text) = fields["message"] {
            message = text
        }
        return QueryVerdict(ok: ok, message: message, body: body)
    }

    public func resetVariant(for endpoint: EndpointRef, session: String) async throws {
        try await call("DELETE", url: endpointURL(endpoint, subresource: "variant"), session: session)
    }

    /// This session's request history, oldest first.
    public func requests(session: String) async throws -> [RequestRecord] {
        let url = baseURL.appending(path: "_admin/requests")
        let data = try await call("GET", url: url, session: session)
        guard let records = try? JSONDecoder().decode([RequestRecord].self, from: data) else {
            throw BridgeError.malformedResponse(url: url.absoluteString)
        }
        return records.reversed()
    }

    private func endpointURL(_ endpoint: EndpointRef, subresource: String) -> URL {
        let trimmed = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appending(path: "_admin/endpoints")
            .appending(path: endpoint.method)
            .appending(path: trimmed)
            .appending(path: subresource)
        guard let operation = endpoint.operation else {
            return url
        }
        return url.appending(queryItems: [URLQueryItem(name: "operation", value: operation)])
    }

    @discardableResult
    private func call(_ method: String, url: URL, session: String, json: (any Encodable)? = nil)
        async throws -> Data
    {
        Self.logger.debugPublic("\(method) \(url.absoluteString) session=\(session)")
        let body = try json.map { try JSONEncoder().encode($0) }
        let (data, response) = try await send(method, url: url, session: session, body: body)
        try Self.check(response, data: data, method: method, url: url)
        Self.logger.debugPublic("\(method) \(url.absoluteString) answered \(response.statusCode)")
        return data
    }

    private func send(_ method: String, url: URL, session: String? = nil, body: Data? = nil)
        async throws -> (Data, HTTPURLResponse)
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let session {
            request.setValue(session, forHTTPHeaderField: "X-Mock-Session")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        auth.apply(to: &request)
        return try await transport.send(request)
    }

    private static func check(_ response: HTTPURLResponse, data: Data, method: String, url: URL)
        throws
    {
        if response.statusCode == 401 {
            throw BridgeError.adminUnauthorized(url: url.absoluteString)
        }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable {
                let reason: String?
                let error: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw BridgeError.unexpectedStatus(
                method: method,
                url: url.absoluteString,
                status: response.statusCode,
                reason: failure?.reason ?? failure?.error
            )
        }
    }
}
