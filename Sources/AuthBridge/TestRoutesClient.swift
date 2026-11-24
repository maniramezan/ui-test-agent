import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

/// What the `test-routes` provider keeps for one run.
public struct BackendState: Codable, Sendable, Equatable {
    public var baseURL: String
    public var sessionHeader: String?
    /// The run's own data set on the backend; nil when the config names no session header.
    public var session: String?
    public var routes: [String: AuthConfig.Route]
    /// Without a session: the first step applied to each account, by email, for flow_end to undo.
    public var changed: [String: String]?

    public init(
        baseURL: String,
        sessionHeader: String? = nil,
        session: String? = nil,
        routes: [String: AuthConfig.Route],
        changed: [String: String]? = nil
    ) {
        self.baseURL = baseURL
        self.sessionHeader = sessionHeader
        self.session = session
        self.routes = routes
        self.changed = changed
    }
}

/// Calls the test-support routes an app's backend offers, inside the run's session when it has one.
struct TestRoutesClient {
    private static let logger = Logger.forType(subsystem: "UITestAgent", TestRoutesClient.self)

    let state: BackendState
    let transport: any HTTPTransport

    /// A path segment may hold anything but `/`.
    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// `route`'s path with `{email}` and `{session}` filled in, percent-encoded.
    static func path(of route: AuthConfig.Route, email: String?, session: String?) -> String {
        var values: [String: String] = [:]
        for (name, value) in [("email", email), ("session", session)] {
            if let value {
                values[name] = value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
            }
        }
        return AuthConfig.render(route.path, open: "{", close: "}", values: values)
    }

    private func request(method: String, path: String) throws -> URLRequest {
        let base = state.baseURL.hasSuffix("/") ? String(state.baseURL.dropLast()) : state.baseURL
        guard let url = URL(string: base + path) else {
            throw AuthError.backendNotReachable(url: base + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let header = state.sessionHeader, let session = state.session {
            request.setValue(session, forHTTPHeaderField: header)
        }
        return request
    }

    /// Any HTTP answer counts: the backend is up.
    func checkReachable() async throws {
        do {
            _ = try await transport.send(try request(method: "GET", path: "/"))
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.backendNotReachable(url: state.baseURL)
        }
    }

    /// Calls the route configured as `name` and returns its status.
    func call(_ name: String, email: String? = nil) async throws -> Int {
        guard let route = state.routes[name] else {
            throw AuthError.noRoute(step: name)
        }
        let path = Self.path(of: route, email: email, session: state.session)
        Self.logger.debugPublic("Calling test route \(name) method=\(route.method)")
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(try request(method: route.method, path: path))
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.backendNotReachable(url: state.baseURL)
        }
        Self.logger.debugPublic("Test route \(name) answered \(response.statusCode)")
        return response.statusCode
    }
}
