import Foundation
import Hummingbird
import OSLog
import OpenAPIHummingbird
import OpenAPIRuntime
import SwiftCommons

/// Builds the backend's routes: the operations of `openapi.yaml`, plus test-support routes under
/// `/_test` that are deliberately outside the spec, so they never become part of a mock bundle.
public enum Backend {
    private static let logger = Logger.forType(subsystem: "ExampleServer", Backend.self)

    /// - Parameter store: the data of requests outside any test session.
    public static func router(
        store: Store,
        tokenLifetime: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Router<BasicRequestContext> {
        let router = Router()
        let signer = TokenSigner(lifetime: tokenLifetime)
        let sessions = TestSessions(shared: store)
        let handler = Handler(shared: store, signer: signer, now: now)
        try handler.registerHandlers(
            on: router,
            middlewares: [
                TestSessionMiddleware(sessions: sessions),
                RequestErrorMiddleware(),
                AuthMiddleware(shared: store, signer: signer, now: now),
            ]
        )
        router.post("/_test/reset") { request, _ -> HTTPResponse.Status in
            guard let store = await dataSet(of: request, in: sessions) else {
                return .badRequest
            }
            await store.reset()
            logger.infoPublic("Restored seed data")
            return .noContent
        }
        router.put("/_test/accounts/{email}/disabled") { request, context -> HTTPResponse.Status in
            try await setDisabled(true, request: request, sessions: sessions, context: context)
        }
        router.delete("/_test/accounts/{email}/disabled") { request, context -> HTTPResponse.Status in
            try await setDisabled(false, request: request, sessions: sessions, context: context)
        }
        router.delete("/_test/sessions/{id}") { _, context -> HTTPResponse.Status in
            let id = try context.parameters.require("id")
            return await sessions.release(id) ? .noContent : .notFound
        }
        return router
    }

    /// The data set a test route acts on: its `X-Test-Session`'s, or the shared one. Nil for an
    /// id the header can't hold.
    private static func dataSet(of request: Request, in sessions: TestSessions) async -> Store? {
        let session = TestSessions.id(in: request.headers)
        if let session, !TestSessions.isValid(session) {
            return nil
        }
        return await sessions.store(for: session)
    }

    private static func setDisabled(
        _ disabled: Bool, request: Request, sessions: TestSessions, context: BasicRequestContext
    ) async throws -> HTTPResponse.Status {
        let email = try context.parameters.require("email")
        guard let store = await dataSet(of: request, in: sessions) else {
            return .badRequest
        }
        guard await store.setDisabled(disabled, email: email) else {
            return .notFound
        }
        logger.infoPublic("Account disabled=\(disabled)")
        return .noContent
    }
}
