import CryptoKit
import Foundation

/// The claims of a bearer token: who it is for, which session it belongs to, and when it ends.
struct TokenClaims: Codable, Sendable, Equatable {
    var sub: String
    var email: String
    var sid: String
    var iat: Int
    var exp: Int
}

/// Signs and checks HS256 JWTs. The key is a fixed development key: the backend exists to be
/// tested against, and a decodable token lets a mock server read its claims.
struct TokenSigner: Sendable {
    private let key: SymmetricKey
    let lifetime: TimeInterval

    init(secret: String = "example-development-key", lifetime: TimeInterval) {
        key = SymmetricKey(data: Data(secret.utf8))
        self.lifetime = lifetime
    }

    func token(account: Account, session: String, now: Date) throws -> String {
        let issued = Int(now.timeIntervalSince1970)
        let claims = TokenClaims(
            sub: account.id, email: account.email, sid: session, iat: issued,
            exp: issued + Int(lifetime))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = Self.base64URL(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = Self.base64URL(try encoder.encode(claims))
        let signature = Self.base64URL(Data(mac("\(header).\(payload)")))
        return "\(header).\(payload).\(signature)"
    }

    /// The token's claims when its signature is right and it has not expired, otherwise nil.
    func claims(of token: String, now: Date) -> TokenClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
            let signature = Self.data(base64URL: parts[2]),
            HMAC<SHA256>.isValidAuthenticationCode(
                signature, authenticating: Data("\(parts[0]).\(parts[1])".utf8), using: key),
            let payload = Self.data(base64URL: parts[1]),
            let claims = try? JSONDecoder().decode(TokenClaims.self, from: payload),
            Double(claims.exp) > now.timeIntervalSince1970
        else {
            return nil
        }
        return claims
    }

    private func mac(_ text: String) -> HMAC<SHA256>.MAC {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}
