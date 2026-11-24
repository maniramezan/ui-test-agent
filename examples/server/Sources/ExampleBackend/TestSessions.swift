import Foundation
import HTTPTypes
import OSLog
import OpenAPIRuntime
import SwiftCommons

/// The backend's data sets: the shared one, and a separate seeded one for each test session.
///
/// A request that carries `X-Test-Session: <id>` reads and writes only that session's data, which
/// is created from the seed the first time the id is seen. Tests that each pick their own id can
/// therefore run at the same time against one server without seeing each other's changes.
public actor TestSessions {
    public static let headerName = "X-Test-Session"

    private static let logger = Logger.forType(subsystem: "ExampleServer", TestSessions.self)

    /// The data of every request without the header.
    let shared: Store
    private var stores: [String: Store] = [:]

    public init(shared: Store = Store()) {
        self.shared = shared
    }

    /// The test session id a request's headers carry, if any.
    static func id(in fields: HTTPFields) -> String? {
        guard let name = HTTPField.Name(headerName) else {
            return nil
        }
        return fields[name]
    }

    /// 1 to 64 letters, digits, `-` or `_`.
    static func isValid(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
    }

    /// The data set of `session`, created on first use; the shared one when there is no session.
    func store(for session: String?) -> Store {
        guard let session else {
            return shared
        }
        if let store = stores[session] {
            return store
        }
        let store = Store()
        stores[session] = store
        Self.logger.infoPublic("Created a data set for a test session; \(stores.count) in use")
        return store
    }

    /// Drops a session's data set. False when the id was never used.
    func release(_ session: String) -> Bool {
        let existed = stores.removeValue(forKey: session) != nil
        Self.logger.infoPublic("Released a test session's data set existed=\(existed); \(stores.count) in use")
        return existed
    }
}

/// The data set of the request being handled, set by `TestSessionMiddleware`.
enum DataSet {
    @TaskLocal static var current: Store?
}

/// Picks the request's data set from its `X-Test-Session` header before anything else runs.
struct TestSessionMiddleware: ServerMiddleware {
    private static let logger = Logger.forType(subsystem: "ExampleServer", TestSessionMiddleware.self)

    let sessions: TestSessions

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
            HTTPResponse, HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let session = TestSessions.id(in: request.headerFields)
        if let session, !TestSessions.isValid(session) {
            Self.logger.infoPublic("Refused \(operationID): invalid test session id")
            return ErrorReply.response(
                status: .badRequest, code: "invalid_test_session",
                message: "\(TestSessions.headerName) must be 1 to 64 letters, digits, - or _")
        }
        let store = await sessions.store(for: session)
        return try await DataSet.$current.withValue(store) {
            try await next(request, body, metadata)
        }
    }
}
