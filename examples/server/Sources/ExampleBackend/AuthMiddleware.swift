import Foundation
import HTTPTypes
import OSLog
import OpenAPIRuntime
import SwiftCommons

/// Who is calling, set by `AuthMiddleware` for the handler of the same request.
struct Caller: Sendable, Equatable {
    var account: String
    var session: String

    @TaskLocal static var current: Caller?
}

/// Enforces the spec's security rules: every call but sign-in needs the session cookie, and
/// every call but sign-in and refresh also needs a valid bearer token of that same session.
struct AuthMiddleware: ServerMiddleware {
    static let cookieName = "example_session"

    private static let logger = Logger.forType(subsystem: "ExampleServer", AuthMiddleware.self)

    /// The data used outside any test session.
    let shared: Store
    let signer: TokenSigner
    let now: @Sendable () -> Date

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
            HTTPResponse, HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if operationID == "createSession" {
            var (response, responseBody) = try await next(request, body, metadata)
            // The generated code percent-encodes header values as OpenAPI's `simple` style asks,
            // which turns a cookie's `=` and `;` into escapes no client can read.
            if let cookie = response.headerFields[.setCookie]?.removingPercentEncoding {
                response.headerFields[.setCookie] = cookie
            }
            return (response, responseBody)
        }
        guard let session = Self.cookie(Self.cookieName, in: request.headerFields[.cookie]) else {
            return Self.refuse(operationID, code: "missing_session_cookie", "The session cookie is required")
        }
        let account: Account
        do {
            account = try await (DataSet.current ?? shared).account(forSession: session)
        } catch {
            return Self.refuse(operationID, code: "unknown_session", "The session has ended")
        }
        if operationID != "refreshSession" {
            guard let token = Self.bearerToken(request.headerFields[.authorization]) else {
                return Self.refuse(operationID, code: "missing_token", "A bearer token is required")
            }
            guard let claims = signer.claims(of: token, now: now()) else {
                return Self.refuse(operationID, code: "invalid_token", "The token is invalid or expired")
            }
            guard claims.sid == session, claims.sub == account.id else {
                return Self.refuse(operationID, code: "session_mismatch", "The token is for another session")
            }
            guard !account.disabled else {
                return Self.refuse(operationID, code: "invalid_token", "The token is invalid or expired")
            }
        }
        return try await Caller.$current.withValue(Caller(account: account.id, session: session)) {
            try await next(request, body, metadata)
        }
    }

    static func cookie(_ name: String, in header: String?) -> String? {
        guard let header else {
            return nil
        }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == name, !parts[1].isEmpty {
                return parts[1]
            }
        }
        return nil
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header else {
            return nil
        }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else {
            return nil
        }
        return parts[1]
    }

    private static func refuse(
        _ operationID: String, code: String, _ message: String
    ) -> (HTTPResponse, HTTPBody?) {
        logger.infoPublic("Refused \(operationID): \(code)")
        return ErrorReply.response(status: .unauthorized, code: code, message: message)
    }
}

/// An error body written outside the generated handlers, in the spec's `ErrorBody` shape.
enum ErrorReply {
    static func response(
        status: HTTPResponse.Status, code: String, message: String
    ) -> (HTTPResponse, HTTPBody?) {
        let body = (try? JSONEncoder().encode(["error": code, "message": message])) ?? Data()
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json; charset=utf-8"
        return (response, HTTPBody(body))
    }
}

/// Answers a request the generated code could not read (a missing or mistyped query parameter,
/// an unreadable body) with a 400 in the spec's `ErrorBody` shape instead of a bare 500.
struct RequestErrorMiddleware: ServerMiddleware {
    private static let logger = Logger.forType(subsystem: "ExampleServer", RequestErrorMiddleware.self)

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
            HTTPResponse, HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        do {
            return try await next(request, body, metadata)
        } catch let error as any HTTPResponseConvertible where error.httpStatus == .badRequest {
            Self.logger.infoPublic("Refused \(operationID): unreadable request")
            return ErrorReply.response(
                status: .badRequest, code: "invalid_request",
                message: "A required parameter is missing or has the wrong type")
        }
    }
}
