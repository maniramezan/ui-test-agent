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

    public static func router(
        store: Store,
        tokenLifetime: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Router<BasicRequestContext> {
        let router = Router()
        let signer = TokenSigner(lifetime: tokenLifetime)
        let handler = Handler(store: store, signer: signer, now: now)
        try handler.registerHandlers(
            on: router,
            middlewares: [
                RequestErrorMiddleware(),
                AuthMiddleware(store: store, signer: signer, now: now),
            ]
        )
        router.post("/_test/reset") { _, _ -> HTTPResponse.Status in
            await store.reset()
            logger.infoPublic("Restored seed data")
            return .noContent
        }
        router.put("/_test/accounts/{email}/disabled") { _, context -> HTTPResponse.Status in
            try await setDisabled(true, store: store, context: context)
        }
        router.delete("/_test/accounts/{email}/disabled") { _, context -> HTTPResponse.Status in
            try await setDisabled(false, store: store, context: context)
        }
        return router
    }

    private static func setDisabled(
        _ disabled: Bool, store: Store, context: BasicRequestContext
    ) async throws -> HTTPResponse.Status {
        let email = try context.parameters.require("email")
        guard await store.setDisabled(disabled, email: email) else {
            return .notFound
        }
        logger.infoPublic("Account disabled=\(disabled)")
        return .noContent
    }
}
