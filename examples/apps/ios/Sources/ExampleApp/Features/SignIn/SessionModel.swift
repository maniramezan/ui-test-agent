import Foundation
import OSLog
import Observation
import SwiftCommons

/// Who is signed in, and why the sign-in screen is showing when nobody is.
@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn(User)
    }

    private static let logger = Logger.forType(subsystem: "ExampleApp", SessionModel.self)

    private(set) var phase = Phase.signedOut
    private(set) var message: String?
    private(set) var fieldErrors: [String: String] = [:]

    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func signIn(email: String, password: String) async {
        phase = .signingIn
        message = nil
        fieldErrors = [:]
        Self.logger.infoPublic("Signing in")
        do {
            let user = try await client.signIn(email: email, password: password)
            Self.logger.infoPublic("Signed in user=\(user.id)")
            phase = .signedIn(user)
        } catch let error as APIError {
            Self.logger.error("Sign-in failed", error: error, context: "feature=signIn action=signIn")
            if case .rejected(_, _, _, let fields) = error {
                fieldErrors = fields
            }
            message = error.message
            phase = .signedOut
        } catch {
            Self.logger.error("Sign-in failed", error: error, context: "feature=signIn action=signIn")
            message = APIError.malformed.message
            phase = .signedOut
        }
    }

    func signOut() async {
        Self.logger.infoPublic("Signing out")
        await client.signOut()
        Self.logger.infoPublic("Signed out")
        message = nil
        phase = .signedOut
    }

    /// Called when a signed-in call found the session over.
    func sessionEnded(_ error: APIError) {
        Self.logger.infoPublic("Session ended: \(error == .accountDisabled ? "account disabled" : "signed out")")
        message = error.message
        phase = .signedOut
    }
}
