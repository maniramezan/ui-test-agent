import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import ExampleBackend

/// A clock the test moves by hand, to expire tokens without waiting.
final class TestClock: Sendable {
    private let seconds = Mutex<TimeInterval>(1_800_000_000)

    var now: Date {
        Date(timeIntervalSince1970: seconds.withLock { $0 })
    }

    func advance(by interval: TimeInterval) {
        seconds.withLock { $0 += interval }
    }
}

/// What a signed-in client holds: the bearer token and the session cookie pair.
struct SignedIn {
    var token: String
    var cookie: String

    var headers: HTTPFields {
        [.authorization: "Bearer \(token)", .cookie: cookie]
    }
}

struct Reply {
    var status: HTTPResponse.Status
    var headers: HTTPFields
    var json: [String: Any]

    var error: String? {
        json["error"] as? String
    }

    var items: [[String: Any]] {
        json["items"] as? [[String: Any]] ?? []
    }
}

extension TestClientProtocol {
    func call(
        _ method: HTTPRequest.Method, _ uri: String, headers: HTTPFields = [:], json: String? = nil
    ) async throws -> Reply {
        var headers = headers
        if json != nil {
            headers[.contentType] = "application/json"
        }
        let response = try await execute(
            uri: uri, method: method, headers: headers, body: json.map { ByteBuffer(string: $0) })
        let object = try? JSONSerialization.jsonObject(with: Data(buffer: response.body))
        return Reply(
            status: response.status, headers: response.headers, json: object as? [String: Any] ?? [:])
    }

    func signIn(email: String = "user@example.com", headers: HTTPFields = [:]) async throws -> SignedIn {
        let reply = try await call(
            .post, "/v1/session", headers: headers,
            json: #"{"email":"\#(email)","password":"example-password"}"#)
        #expect(reply.status == .ok)
        let token = try #require(reply.json["token"] as? String)
        let setCookie = try #require(reply.headers[.setCookie])
        let pair = try #require(setCookie.split(separator: ";").first.map(String.init))
        return SignedIn(token: token, cookie: pair)
    }
}

@Suite struct BackendTests {
    let clock = TestClock()

    func withBackend(
        tokenLifetime: TimeInterval = 3600,
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let clock = clock
        let router = try Backend.router(
            store: Store(), tokenLifetime: tokenLifetime, now: { clock.now })
        try await Application(router: router).test(.router) { client in
            try await body(client)
        }
    }

    @Test func signInReturnsATokenAndSetsTheSessionCookie() async throws {
        try await withBackend { client in
            let reply = try await client.call(
                .post, "/v1/session",
                json: #"{"email":"user@example.com","password":"example-password"}"#)
            #expect(reply.status == .ok)
            #expect((reply.json["user"] as? [String: Any])?["id"] as? String == "user-1")
            let cookie = try #require(reply.headers[.setCookie])
            #expect(cookie.hasPrefix("example_session="))
            #expect(cookie.contains("HttpOnly"))
        }
    }

    @Test func signInRefusesWrongAndDisabledAccountsAndEmptyFields() async throws {
        try await withBackend { client in
            let wrong = try await client.call(
                .post, "/v1/session", json: #"{"email":"user@example.com","password":"nope"}"#)
            #expect(wrong.status == .unauthorized)
            #expect(wrong.error == "invalid_credentials")

            let disabled = try await client.call(
                .post, "/v1/session",
                json: #"{"email":"disabled@example.com","password":"example-password"}"#)
            #expect(disabled.status == .forbidden)
            #expect(disabled.error == "account_disabled")

            let empty = try await client.call(.post, "/v1/session", json: #"{"email":" ","password":""}"#)
            #expect(empty.status == .unprocessableContent)
            #expect((empty.json["fields"] as? [String: String])?.keys.sorted() == ["email", "password"])
        }
    }

    @Test func protectedCallsNeedBothTheCookieAndTheToken() async throws {
        try await withBackend { client in
            let session = try await client.signIn()

            let noCookie = try await client.call(
                .get, "/v1/me", headers: [.authorization: "Bearer \(session.token)"])
            #expect(noCookie.status == .unauthorized)
            #expect(noCookie.error == "missing_session_cookie")

            let noToken = try await client.call(.get, "/v1/me", headers: [.cookie: session.cookie])
            #expect(noToken.status == .unauthorized)
            #expect(noToken.error == "missing_token")

            let forged = try await client.call(
                .get, "/v1/me",
                headers: [.authorization: "Bearer \(session.token)x", .cookie: session.cookie])
            #expect(forged.error == "invalid_token")

            let other = try await client.signIn(email: "second@example.com")
            let mixed = try await client.call(
                .get, "/v1/me",
                headers: [.authorization: "Bearer \(other.token)", .cookie: session.cookie])
            #expect(mixed.error == "session_mismatch")

            let both = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(both.status == .ok)
            #expect(both.json["email"] as? String == "user@example.com")
        }
    }

    @Test func listingNeedsEveryQueryParameterAndPages() async throws {
        try await withBackend { client in
            let session = try await client.signIn()

            let missing = try await client.call(.get, "/v1/tasks?status=all&page=1", headers: session.headers)
            #expect(missing.status == .badRequest)

            let unknown = try await client.call(
                .get, "/v1/tasks?status=later&page=1&limit=20", headers: session.headers)
            #expect(unknown.status == .badRequest)

            let outOfRange = try await client.call(
                .get, "/v1/tasks?status=all&page=0&limit=20", headers: session.headers)
            #expect(outOfRange.status == .badRequest)
            #expect(outOfRange.error == "invalid_query")

            let first = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=20", headers: session.headers)
            #expect(first.status == .ok)
            #expect(first.items.count == 20)
            #expect(first.items.first?["id"] as? String == "task-025")
            #expect(first.json["total"] as? Int == 25)
            #expect(first.json["has_more"] as? Bool == true)

            let second = try await client.call(
                .get, "/v1/tasks?status=all&page=2&limit=20", headers: session.headers)
            #expect(second.items.count == 5)
            #expect(second.json["has_more"] as? Bool == false)

            let done = try await client.call(
                .get, "/v1/tasks?status=done&page=1&limit=100", headers: session.headers)
            #expect(done.items.count == 8)
            #expect(done.items.allSatisfy { $0["done"] as? Bool == true })
        }
    }

    @Test func tasksCanBeCreatedChangedAndDeleted() async throws {
        try await withBackend { client in
            let session = try await client.signIn()

            let blank = try await client.call(
                .post, "/v1/tasks", headers: session.headers, json: #"{"title":"  "}"#)
            #expect(blank.status == .unprocessableContent)
            #expect((blank.json["fields"] as? [String: String])?["title"] == "Enter a title")

            let created = try await client.call(
                .post, "/v1/tasks", headers: session.headers,
                json: #"{"title":"Buy milk","notes":"Two litres"}"#)
            #expect(created.status == .created)
            let id = try #require(created.json["id"] as? String)

            let changed = try await client.call(
                .patch, "/v1/tasks/\(id)", headers: session.headers, json: #"{"done":true}"#)
            #expect(changed.json["done"] as? Bool == true)
            #expect(changed.json["title"] as? String == "Buy milk")

            let deleted = try await client.call(.delete, "/v1/tasks/\(id)", headers: session.headers)
            #expect(deleted.status == .noContent)

            let gone = try await client.call(.get, "/v1/tasks/\(id)", headers: session.headers)
            #expect(gone.status == .notFound)
            #expect(gone.error == "task_not_found")

            let all = try await client.call(.delete, "/v1/tasks", headers: session.headers)
            #expect(all.json["deleted"] as? Int == Store.seededTaskCount)

            let empty = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=20", headers: session.headers)
            #expect(empty.items.isEmpty)
            #expect(empty.json["total"] as? Int == 0)
        }
    }

    @Test func anExpiredTokenIsRefusedUntilRefreshed() async throws {
        let clock = clock
        try await withBackend(tokenLifetime: 60) { client in
            let session = try await client.signIn()
            clock.advance(by: 61)

            let expired = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(expired.status == .unauthorized)
            #expect(expired.error == "invalid_token")

            let refreshed = try await client.call(
                .post, "/v1/session/refresh", headers: [.cookie: session.cookie])
            #expect(refreshed.status == .ok)
            let token = try #require(refreshed.json["token"] as? String)

            let again = try await client.call(
                .get, "/v1/me", headers: [.authorization: "Bearer \(token)", .cookie: session.cookie])
            #expect(again.status == .ok)
        }
    }

    @Test func aDisabledAccountGetsA401ThenA403OnRefresh() async throws {
        try await withBackend { client in
            let session = try await client.signIn()
            let disable = try await client.call(.put, "/_test/accounts/user@example.com/disabled")
            #expect(disable.status == .noContent)

            let refused = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(refused.status == .unauthorized)

            let refresh = try await client.call(
                .post, "/v1/session/refresh", headers: [.cookie: session.cookie])
            #expect(refresh.status == .forbidden)
            #expect(refresh.error == "account_disabled")

            let enable = try await client.call(.delete, "/_test/accounts/user@example.com/disabled")
            #expect(enable.status == .noContent)
            let allowed = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(allowed.status == .ok)
        }
    }

    @Test func signingOutEndsTheSession() async throws {
        try await withBackend { client in
            let session = try await client.signIn()
            let out = try await client.call(.delete, "/v1/session", headers: session.headers)
            #expect(out.status == .noContent)
            let after = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(after.status == .unauthorized)
            #expect(after.error == "unknown_session")
        }
    }

    @Test func resetRestoresTheSeedAndEndsSessions() async throws {
        try await withBackend { client in
            let session = try await client.signIn()
            _ = try await client.call(.delete, "/v1/tasks", headers: session.headers)
            let reset = try await client.call(.post, "/_test/reset")
            #expect(reset.status == .noContent)

            let stale = try await client.call(.get, "/v1/me", headers: session.headers)
            #expect(stale.status == .unauthorized)

            let fresh = try await client.signIn()
            let list = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=100", headers: fresh.headers)
            #expect(list.items.count == Store.seededTaskCount)
        }
    }

    @Test func aTestSessionHasItsOwnDataUntilItIsReleased() async throws {
        try await withBackend { client in
            let header = try #require(HTTPField.Name(TestSessions.headerName))
            let one: HTTPFields = [header: "session-one"]
            let two: HTTPFields = [header: "session-two"]

            let inOne = try await client.signIn(headers: one)
            let cleared = try await client.call(.delete, "/v1/tasks", headers: inOne.headers + one)
            #expect(cleared.status == .ok)
            let disable = try await client.call(
                .put, "/_test/accounts/second@example.com/disabled", headers: one)
            #expect(disable.status == .noContent)

            // The other session and the shared data still hold the seed.
            let inTwo = try await client.signIn(headers: two)
            let listTwo = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=100", headers: inTwo.headers + two)
            #expect(listTwo.items.count == Store.seededTaskCount)
            let second = try await client.call(
                .post, "/v1/session", headers: two,
                json: #"{"email":"second@example.com","password":"example-password"}"#)
            #expect(second.status == .ok)
            let shared = try await client.signIn()
            let listShared = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=100", headers: shared.headers)
            #expect(listShared.items.count == Store.seededTaskCount)

            // A sign-in belongs to the data set it was made in.
            let crossed = try await client.call(.get, "/v1/me", headers: inOne.headers + two)
            #expect(crossed.status == .unauthorized)
            #expect(crossed.error == "unknown_session")

            let released = try await client.call(.delete, "/_test/sessions/session-one")
            #expect(released.status == .noContent)
            let again = try await client.call(.delete, "/_test/sessions/session-one")
            #expect(again.status == .notFound)
            let reseeded = try await client.signIn(headers: one)
            let listOne = try await client.call(
                .get, "/v1/tasks?status=all&page=1&limit=100", headers: reseeded.headers + one)
            #expect(listOne.items.count == Store.seededTaskCount)
        }
    }

    @Test func anUnusableTestSessionIdIsRefused() async throws {
        try await withBackend { client in
            let header = try #require(HTTPField.Name(TestSessions.headerName))
            let reply = try await client.call(
                .post, "/v1/session", headers: [header: "not a valid id"],
                json: #"{"email":"user@example.com","password":"example-password"}"#)
            #expect(reply.status == .badRequest)
            #expect(reply.error == "invalid_test_session")
            let reset = try await client.call(.post, "/_test/reset", headers: [header: "not a valid id"])
            #expect(reset.status == .badRequest)
        }
    }
}
