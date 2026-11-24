import APITraceDebug
import Foundation
import OSLog
import SwiftCommons

/// Talks to the API in `examples/openapi.yaml`. It keeps the bearer token in memory and the
/// session cookie in an in-memory store, so every launch starts signed out. A 401 on a signed-in
/// call is answered by one token refresh and one retry. Calls that fail together share one
/// refresh, and once the session is over every call fails with the reason it ended.
actor APIClient {
    private static let logger = Logger.forType(subsystem: "ExampleApp", APIClient.self)
    static let pageSize = 20

    private let settings: LaunchSettings
    private let session: URLSession
    private var token: String?
    /// The refresh in flight, shared by every call that got a 401 meanwhile.
    private var refresh: Task<Void, any Error>?
    /// Why the session ended, until the next sign-in.
    private var ended: APIError?

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(settings: LaunchSettings) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = !settings.faults.contains(.omitCookie)
        if settings.recordsTraffic {
            // Capture replaces this session's loader with one that has no cookie store, so the
            // session cookie is neither kept nor sent while recording (ios-network-recorder
            // 1.5.0). Capture is therefore on only for a run that asked for a HAR file.
            APITraceDebugBootstrap.enableCapture(in: configuration)
        }
        session = URLSession(configuration: configuration)
    }

    // MARK: Session

    func signIn(email: String, password: String) async throws -> User {
        let payload: SessionPayload = try await call(
            "POST", "/v1/session", body: ["email": email, "password": password], authorized: false)
        token = payload.token
        ended = nil
        return payload.user
    }

    func signOut() async {
        do {
            try await callWithoutReply("DELETE", "/v1/session")
        } catch {
            Self.logger.error("Sign-out call failed", error: error, context: "action=signOut")
        }
        forgetSession(because: .signedOut)
    }

    // MARK: Tasks

    func tasks(status: StatusFilter, page: Int, refreshing: Bool) async throws -> TaskPage {
        let sent = settings.faults.contains(.ignoreFilter) ? StatusFilter.all : status
        return try await call(
            "GET", "/v1/tasks",
            query: [
                URLQueryItem(name: "status", value: sent.rawValue),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ],
            dropAuthorization: refreshing && settings.faults.contains(.dropAuthorizationOnRefresh)
        )
    }

    func task(id: String) async throws -> TaskItem {
        try await call("GET", "/v1/tasks/\(id)")
    }

    func createTask(title: String, notes: String?) async throws -> TaskItem {
        var body = ["title": title]
        body["notes"] = notes
        return try await call("POST", "/v1/tasks", body: body)
    }

    func setDone(_ done: Bool, id: String) async throws -> TaskItem {
        try await call("PATCH", "/v1/tasks/\(id)", body: ["done": done])
    }

    func deleteTask(id: String) async throws {
        try await callWithoutReply("DELETE", "/v1/tasks/\(id)")
    }

    func deleteAllTasks() async throws -> Int {
        let count: DeletedCount = try await call("DELETE", "/v1/tasks")
        return count.deleted
    }

    // MARK: Transport

    private func call<Reply: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        authorized: Bool = true,
        dropAuthorization: Bool = false
    ) async throws -> Reply {
        let data = try await send(
            method, path, query: query, body: body, authorized: authorized,
            dropAuthorization: dropAuthorization)
        do {
            return try Self.decoder.decode(Reply.self, from: data)
        } catch {
            Self.logger.error("Unreadable reply", error: error, context: "request=\(method) \(path)")
            throw APIError.malformed
        }
    }

    private func callWithoutReply(_ method: String, _ path: String) async throws {
        _ = try await send(method, path, query: [], body: nil, authorized: true, dropAuthorization: false)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: (any Encodable & Sendable)?,
        authorized: Bool,
        dropAuthorization: Bool
    ) async throws -> Data {
        if authorized, let ended {
            throw ended
        }
        let first = try await perform(
            method, path, query: query, body: body, authorized: authorized && !dropAuthorization)
        guard first.status == 401, authorized else {
            return try Self.checked(first, signedIn: authorized)
        }
        Self.logger.infoPublic("401 on \(method) \(path); refreshing the token")
        try await refreshToken()
        let second = try await perform(method, path, query: query, body: body, authorized: true)
        if second.status == 401 {
            forgetSession(because: .signedOut)
            throw APIError.signedOut
        }
        return try Self.checked(second, signedIn: true)
    }

    /// Refreshes the token once for every call waiting on it. A second refresh after the first
    /// one ended the session would go out without its cookie and report the wrong reason.
    private func refreshToken() async throws {
        if let ended {
            throw ended
        }
        if let refresh {
            return try await refresh.value
        }
        let task = Task { try await requestNewToken() }
        refresh = task
        defer { refresh = nil }
        try await task.value
    }

    private func requestNewToken() async throws {
        let reply = try await perform(
            "POST", "/v1/session/refresh", query: [], body: nil, authorized: false)
        switch reply.status {
        case 200..<300:
            guard let payload = try? Self.decoder.decode(SessionPayload.self, from: reply.data) else {
                throw APIError.malformed
            }
            token = payload.token
            Self.logger.infoPublic("Token refreshed")
        case 403:
            Self.logger.infoPublic("Refresh refused: account disabled")
            forgetSession(because: .accountDisabled)
            throw APIError.accountDisabled
        case 401:
            Self.logger.infoPublic("Refresh refused: session ended")
            forgetSession(because: .signedOut)
            throw APIError.signedOut
        default:
            throw APIError.server(status: reply.status)
        }
    }

    private func forgetSession(because reason: APIError) {
        if ended == nil {
            ended = reason
        }
        token = nil
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: (any Encodable & Sendable)?,
        authorized: Bool
    ) async throws -> (status: Int, data: Data) {
        var url = settings.baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let mockSession = settings.mockSession {
            request.setValue(mockSession, forHTTPHeaderField: LaunchSettings.mockSessionHeader)
        }
        if let testSession = settings.testSession {
            request.setValue(testSession, forHTTPHeaderField: LaunchSettings.testSessionHeader)
        }
        if authorized, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        Self.logger.debugPublic("\(method) \(path)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.malformed
            }
            Self.logger.debugPublic("\(method) \(path) answered \(http.statusCode)")
            return (http.statusCode, data)
        } catch let error as APIError {
            throw error
        } catch {
            Self.logger.error("Request failed", error: error, context: "request=\(method) \(path)")
            throw APIError.unreachable
        }
    }

    private static func checked(_ reply: (status: Int, data: Data), signedIn: Bool) throws -> Data {
        switch reply.status {
        case 200..<300:
            return reply.data
        case 500...:
            throw APIError.server(status: reply.status)
        default:
            guard let body = try? decoder.decode(ErrorBody.self, from: reply.data) else {
                throw APIError.server(status: reply.status)
            }
            if reply.status == 403, body.error == "account_disabled" {
                throw APIError.accountDisabled
            }
            throw APIError.rejected(
                status: reply.status, code: body.error, message: body.message, fields: body.fields ?? [:])
        }
    }
}
