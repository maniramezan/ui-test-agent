import ExtensionKit
import Foundation
import Testing

@testable import AuthBridge

/// Answers requests from a script keyed by "METHOD path" and records what was sent.
actor StubTransport: HTTPTransport {
    struct Sent: Equatable {
        let method: String
        let path: String
        let body: JSONValue?
    }

    private var replies: [String: [(Int, String)]]
    private(set) var sent: [Sent] = []

    init(_ replies: [String: [(Int, String)]]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = try #require(request.url)
        let key = "\(method) \(url.path(percentEncoded: false))"
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        sent.append(Sent(method: method, path: url.path(percentEncoded: false), body: body))
        var queue = replies[key] ?? []
        guard !queue.isEmpty else {
            throw URLError(.cannotConnectToHost)
        }
        let (status, text) = queue.count > 1 ? queue.removeFirst() : queue[0]
        replies[key] = queue
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(text.utf8), response)
    }
}

@Suite("AuthHandler")
struct AuthHandlerTests {
    static let project = "demo-example"
    static let lookup = "POST /identitytoolkit.googleapis.com/v1/projects/demo-example/accounts:lookup"
    static let update = "POST /identitytoolkit.googleapis.com/v1/projects/demo-example/accounts:update"
    static let delete = "POST /identitytoolkit.googleapis.com/v1/projects/demo-example/accounts:delete"
    static let batchCreate = "POST /identitytoolkit.googleapis.com/v1/projects/demo-example/accounts:batchCreate"

    static let user =
        #"{"users":[{"localId":"u-1","email":"user@example.com","emailVerified":true,"passwordHash":"fakeHash:salt=s1:password=secret123","salt":"s1","createdAt":"1700000000000","validSince":"1700000000","providerUserInfo":[{"providerId":"password","email":"user@example.com"}]}]}"#
    static let disabledUser =
        #"{"users":[{"localId":"u-1","email":"user@example.com","disabled":true}]}"#
    static let none = #"{"kind":"identitytoolkit#GetAccountInfoResponse"}"#
    static let ok = #"{"kind":"ok"}"#

    static let state = AuthState(configPath: "/unused", host: "127.0.0.1:9099", projectId: project)

    private func handler(_ transport: StubTransport, environment: [String: String] = [:]) -> AuthHandler {
        AuthHandler(environment: environment, transport: transport, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func encoded(_ state: AuthState?) throws -> String {
        guard let state else { return "null" }
        return String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    private func request(_ json: String) throws -> AuthRequest {
        try JSONDecoder().decode(AuthRequest.self, from: Data(json.utf8))
    }

    private func stepRequest(_ tool: String, arguments: String = #"{"email":"user@example.com"}"#, state: AuthState? = AuthHandlerTests.state)
        throws -> AuthRequest
    {
        try request(
            #"{"protocol":1,"verb":"step","run":{"id":"r1","platform":"ios"},"state":\#(try encoded(state)),"step":{"tool":"\#(tool)","arguments":\#(arguments)}}"#
        )
    }

    private func flowEnd(state: AuthState) throws -> AuthRequest {
        try request(#"{"protocol":1,"verb":"flow_end","state":\#(try encoded(state)),"passed":true}"#)
    }

    private func config(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "auth-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test("describe lists the implemented steps")
    func describe() async throws {
        let reply = try await handler(StubTransport([:])).handle(request(#"{"protocol":1,"verb":"describe"}"#))
        #expect(reply.steps == ["disable_user", "enable_user", "delete_user", "revoke_tokens"])
    }

    @Test("flow_start reads the auth section through moq_config and checks the emulator answers")
    func flowStart() async throws {
        let url = try config(#"{"app":"sample","auth":{"provider":"firebase-emulator","host":"127.0.0.1:9099","projectId":"demo-example"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = StubTransport(["GET /": [(200, "{}")]])
        let reply = try await handler(transport).handle(
            request(#"{"protocol":1,"verb":"flow_start","run":{"id":"r1"},"state":null,"vars":{"moq_config":"\#(url.path)"}}"#))
        #expect(reply.ok == true)
        #expect(reply.state == AuthState(configPath: url.path, host: "127.0.0.1:9099", projectId: "demo-example"))
    }

    @Test("The emulator host falls back to FIREBASE_AUTH_EMULATOR_HOST, and a Google host is refused")
    func hostResolution() throws {
        let config = AuthConfig(provider: .firebaseEmulator, host: nil, projectId: "demo-example")
        #expect(try config.resolvedHost(environment: ["FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9199"]) == "127.0.0.1:9199")
        #expect(throws: AuthError.hostNotGiven) { try config.resolvedHost(environment: [:]) }
        let google = AuthConfig(provider: .firebaseEmulator, host: "identitytoolkit.googleapis.com", projectId: "p")
        #expect(throws: AuthError.notAnEmulator(host: "identitytoolkit.googleapis.com")) {
            try google.resolvedHost(environment: [:])
        }
    }

    @Test("flow_start with no emulator running says how to start it and how to install the Firebase CLI")
    func flowStartEmulatorDown() async throws {
        let url = try config(#"{"app":"sample","auth":{"provider":"firebase-emulator","host":"127.0.0.1:9099","projectId":"demo-example"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = try await handler(StubTransport([:])).handle(
            request(#"{"protocol":1,"verb":"flow_start","state":null,"vars":{"auth_config":"\#(url.path)"}}"#))
        #expect(reply.ok == false)
        let message = try #require(reply.message)
        #expect(message.contains("firebase emulators:start --only auth --project demo-example"))
        #expect(message.contains("brew install firebase-cli"))
        #expect(message.contains("npm install -g firebase-tools"))
    }

    @Test("flow_start without an auth section fails with the reason")
    func flowStartNoSection() async throws {
        let url = try config(#"{"app":"sample"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = try await handler(StubTransport([:])).handle(
            request(#"{"protocol":1,"verb":"flow_start","state":null,"vars":{"auth_config":"\#(url.path)"}}"#))
        #expect(reply.ok == false)
        #expect(reply.message == AuthError.configInvalid(path: url.path, problem: "no auth section").errorDescription)
    }

    @Test("disable_user disables the account and keeps the original for flow_end")
    func disableUser() async throws {
        let transport = StubTransport([Self.lookup: [(200, Self.user)], Self.update: [(200, Self.ok)]])
        let reply = try await handler(transport).handle(stepRequest("disable_user"))
        #expect(reply.ok == true)
        let sent = await transport.sent
        #expect(sent.map(\.path).last == "/identitytoolkit.googleapis.com/v1/projects/demo-example/accounts:update")
        #expect(sent.last?.body == .object(["localId": .string("u-1"), "disableUser": .bool(true)]))
        let original = try #require(reply.state?.originals?["user@example.com"])
        #expect(original.disabled == false)
        #expect(original.password == "secret123")
        #expect(original.record["validSince"] == nil)
        #expect(original.record["emailVerified"] == .bool(true))
    }

    @Test("A second step on the same account keeps the first original")
    func originalKeptOnce() async throws {
        let transport = StubTransport([Self.lookup: [(200, Self.disabledUser)], Self.update: [(200, Self.ok)]])
        var state = Self.state
        state.originals = ["user@example.com": try AccountSnapshot(lookup: ["localId": .string("u-1"), "disabled": .bool(false)])]
        let reply = try await handler(transport).handle(stepRequest("enable_user", state: state))
        #expect(reply.state?.originals?["user@example.com"]?.disabled == false)
    }

    @Test("revoke_tokens sets validSince to now, and delete_user deletes by id")
    func revokeAndDelete() async throws {
        let revoke = StubTransport([Self.lookup: [(200, Self.user)], Self.update: [(200, Self.ok)]])
        let revoked = try await handler(revoke).handle(stepRequest("revoke_tokens"))
        #expect(revoked.ok == true)
        #expect(await revoke.sent.last?.body == .object(["localId": .string("u-1"), "validSince": .string("1800000000")]))

        let delete = StubTransport([Self.lookup: [(200, Self.user)], Self.delete: [(200, Self.ok)]])
        let deleted = try await handler(delete).handle(stepRequest("delete_user"))
        #expect(deleted.ok == true)
        #expect(await delete.sent.last?.body == .object(["localId": .string("u-1")]))
    }

    @Test("A step fails on an unknown email or an unknown argument")
    func stepFailures() async throws {
        let missing = try await handler(StubTransport([Self.lookup: [(200, Self.none)]])).handle(stepRequest("disable_user"))
        #expect(missing.message == AuthError.noAccount(email: "user@example.com").errorDescription)
        let extra = try await handler(StubTransport([:])).handle(
            stepRequest("disable_user", arguments: #"{"email":"user@example.com","uid":"u-1"}"#))
        #expect(extra.message == ArgumentError(name: "uid", reason: "not an argument of this step").errorDescription)
    }

    @Test("A step before flow_start fails")
    func stepWithoutState() async throws {
        let reply = try await handler(StubTransport([:])).handle(stepRequest("disable_user", state: nil))
        #expect(reply.message == AuthError.noRunState.errorDescription)
    }

    @Test("flow_end re-enables a disabled account and recreates a deleted one with its password")
    func flowEndRestores() async throws {
        let transport = StubTransport([
            Self.lookup: [(200, Self.disabledUser), (200, Self.none)],
            Self.update: [(200, Self.ok)],
            Self.batchCreate: [(200, #"{"error":[]}"#)],
        ])
        var state = Self.state
        let deleted = try AccountSnapshot(lookup: [
            "localId": .string("u-2"), "email": .string("two@example.com"),
            "passwordHash": .string("fakeHash:salt=s:password=pw2"), "validSince": .string("1"),
        ])
        state.originals = [
            "a@example.com": try AccountSnapshot(lookup: ["localId": .string("u-1"), "disabled": .bool(false)]),
            "two@example.com": deleted,
        ]
        let reply = try await handler(transport).handle(flowEnd(state: state))
        #expect(reply.ok == true)
        let bodies = await transport.sent.map(\.body)
        #expect(bodies.contains(.object(["localId": .string("u-1"), "disableUser": .bool(false)])))
        #expect(
            bodies.contains(
                .object(["users": .array([.object(["localId": .string("u-2"), "email": .string("two@example.com")])])])))
        #expect(bodies.last == .object(["localId": .string("u-2"), "password": .string("pw2")]))
    }

    @Test("flow_end reports an account it couldn't restore and still tries the others")
    func flowEndPartialFailure() async throws {
        let transport = StubTransport([
            Self.lookup: [(200, Self.none), (200, Self.disabledUser)],
            Self.batchCreate: [(400, #"{"error":{"message":"DUPLICATE_LOCAL_ID"}}"#)],
            Self.update: [(200, Self.ok)],
        ])
        var state = Self.state
        state.originals = [
            "a@example.com": try AccountSnapshot(lookup: ["localId": .string("u-1")]),
            "b@example.com": try AccountSnapshot(lookup: ["localId": .string("u-2"), "disabled": .bool(false)]),
        ]
        let reply = try await handler(transport).handle(flowEnd(state: state))
        #expect(reply.ok == false)
        #expect(reply.message?.contains("a@example.com") == true)
        #expect(reply.message?.contains("DUPLICATE_LOCAL_ID") == true)
        #expect(await transport.sent.last?.body == .object(["localId": .string("u-1"), "disableUser": .bool(false)]))
    }
}
