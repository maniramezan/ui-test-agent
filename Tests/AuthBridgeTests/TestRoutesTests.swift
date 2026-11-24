import ExtensionKit
import Foundation
import Testing

@testable import AuthBridge

@Suite("AuthHandler with the test-routes provider")
struct TestRoutesTests {
    static let disable = "PUT /_test/accounts/user@example.com/disabled"
    static let enable = "DELETE /_test/accounts/user@example.com/disabled"
    static let release = "DELETE /_test/sessions/run-session"

    static let section = """
        "auth": {
          "provider": "test-routes",
          "baseURL": "http://127.0.0.1:8081",
          "sessionHeader": "X-Test-Session",
          "launchEnvironment": { "APP_TEST_SESSION": "{{sessionId}}", "APP_BASE_URL": "{{baseURL}}" },
          "routes": {
            "release": { "method": "DELETE", "path": "/_test/sessions/{session}" },
            "disable_user": { "method": "PUT", "path": "/_test/accounts/{email}/disabled" },
            "enable_user": { "method": "DELETE", "path": "/_test/accounts/{email}/disabled" }
          }
        }
        """

    static let routes: [String: AuthConfig.Route] = [
        "release": .init(method: "DELETE", path: "/_test/sessions/{session}"),
        "disable_user": .init(method: "PUT", path: "/_test/accounts/{email}/disabled"),
        "enable_user": .init(method: "DELETE", path: "/_test/accounts/{email}/disabled"),
    ]

    static let inSession = AuthState(
        configPath: "/unused",
        backend: BackendState(
            baseURL: "http://127.0.0.1:8081", sessionHeader: "X-Test-Session", session: "run-session",
            routes: routes))

    static let shared = AuthState(
        configPath: "/unused", backend: BackendState(baseURL: "http://127.0.0.1:8081", routes: routes))

    private func handler(_ transport: StubTransport) -> AuthHandler {
        AuthHandler(environment: [:], transport: transport, makeSessionID: { "run-session" })
    }

    private func request(_ json: String) throws -> AuthRequest {
        try JSONDecoder().decode(AuthRequest.self, from: Data(json.utf8))
    }

    private func encoded(_ state: AuthState) throws -> String {
        String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    private func step(_ tool: String, email: String = "user@example.com", state: AuthState) throws -> AuthRequest {
        try request(
            #"{"protocol":1,"verb":"step","state":\#(try encoded(state)),"step":{"tool":"\#(tool)","arguments":{"email":"\#(email)"}}}"#
        )
    }

    private func flowEnd(_ state: AuthState) throws -> AuthRequest {
        try request(#"{"protocol":1,"verb":"flow_end","state":\#(try encoded(state)),"passed":true}"#)
    }

    private func config(_ section: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "auth-\(UUID().uuidString).json")
        try Data("{\(section)}".utf8).write(to: url)
        return url
    }

    @Test("flow_start gives the run a session and the app the launch keys to join it")
    func flowStart() async throws {
        let url = try config(Self.section)
        let transport = StubTransport(["GET /": [(404, "")]])
        let reply = try await handler(transport).handle(
            request(#"{"protocol":1,"verb":"flow_start","vars":{"auth_config":"\#(url.path)"}}"#))
        #expect(reply.ok == true)
        #expect(
            reply.launchEnvironment == [
                "APP_TEST_SESSION": "run-session", "APP_BASE_URL": "http://127.0.0.1:8081",
            ])
        #expect(reply.state?.backend?.session == "run-session")
        #expect(reply.state?.backend?.routes == Self.routes)
        #expect(await transport.sentHeaders.first?["X-Test-Session"] == "run-session")
    }

    @Test("flow_start fails when the backend doesn't answer")
    func flowStartBackendDown() async throws {
        let url = try config(Self.section)
        let reply = try await handler(StubTransport([:])).handle(
            request(#"{"protocol":1,"verb":"flow_start","vars":{"auth_config":"\#(url.path)"}}"#))
        #expect(reply.ok == false)
        #expect(reply.message?.contains("did not answer http://127.0.0.1:8081") == true)
    }

    @Test(
        "A config that could reach beyond this Mac, or can't work, is refused",
        arguments: [
            (#""baseURL": "https://api.example.test""#, "only called on this Mac"),
            (#""routes": {}"#, "auth.routes is empty"),
            (#""routes": {"reset_everything": {"method": "POST", "path": "/x"}}"#, "is not a step"),
            (#""routes": {"disable_user": {"method": "TRACE", "path": "/x"}}"#, "method must be one of"),
            (#""routes": {"disable_user": {"method": "PUT", "path": "/x/{id}"}}"#, "unknown placeholder {id}"),
            (#""launchEnvironment": {"APP_TEST_SESSION": "fixed"}"#, "has no {{sessionId}}"),
            (#""launchEnvironment": {"APP_TEST_SESSION": "{{sessionId}}{{port}}"}"#, "unknown placeholder {{port}}"),
        ])
    func invalidConfig(override: String, problem: String) async throws {
        let key = String(override.dropFirst().prefix { $0 != "\"" })
        var fields = [
            "provider": #""provider": "test-routes""#,
            "baseURL": #""baseURL": "http://127.0.0.1:8081""#,
            "sessionHeader": #""sessionHeader": "X-Test-Session""#,
            "launchEnvironment": #""launchEnvironment": {"APP_TEST_SESSION": "{{sessionId}}"}"#,
            "routes": #""routes": {"disable_user": {"method": "PUT", "path": "/a/{email}"}}"#,
        ]
        fields[key] = override
        let url = try config(#""auth": {\#(fields.values.sorted().joined(separator: ","))}"#)
        let reply = try await handler(StubTransport(["GET /": [(200, "")]])).handle(
            request(#"{"protocol":1,"verb":"flow_start","vars":{"auth_config":"\#(url.path)"}}"#))
        #expect(reply.ok == false)
        #expect(reply.message?.contains(problem) == true, "\(reply.message ?? "")")
    }

    @Test("A session needs its header: {{sessionId}} or a release route without one is refused")
    func sessionNeedsHeader() throws {
        let launch = AuthConfig(
            provider: .testRoutes, baseURL: "http://localhost:8081",
            launchEnvironment: ["APP_TEST_SESSION": "{{sessionId}}"],
            routes: ["disable_user": .init(method: "PUT", path: "/a/{email}")])
        #expect(launch.problem?.contains("auth.sessionHeader is not set") == true)
        let release = AuthConfig(
            provider: .testRoutes, baseURL: "http://localhost:8081",
            routes: ["release": .init(method: "DELETE", path: "/s/{session}")])
        #expect(release.problem?.contains("needs auth.sessionHeader") == true)
    }

    @Test("A step calls its route inside the run's session and keeps nothing to undo")
    func stepInSession() async throws {
        let transport = StubTransport([Self.disable: [(204, "")]])
        let reply = try await handler(transport).handle(step("disable_user", state: Self.inSession))
        #expect(reply.ok == true)
        #expect(reply.state == Self.inSession)
        #expect(await transport.sent.map(\.path) == ["/_test/accounts/user@example.com/disabled"])
        #expect(await transport.sentHeaders.first?["X-Test-Session"] == "run-session")
    }

    @Test("An email is percent-encoded into one path segment")
    func emailEncoding() {
        let route = AuthConfig.Route(method: "PUT", path: "/_test/accounts/{email}/disabled")
        #expect(
            TestRoutesClient.path(of: route, email: "a/b c@example.com", session: nil)
                == "/_test/accounts/a%2Fb%20c@example.com/disabled")
    }

    @Test("A step with no route, a refused call or an unknown step fails by name")
    func stepFailures() async throws {
        let transport = StubTransport([Self.disable: [(404, "")]])
        let noRoute = try await handler(transport).handle(step("delete_user", state: Self.inSession))
        #expect(noRoute.ok == false)
        #expect(noRoute.message?.contains("no delete_user route") == true)
        let refused = try await handler(transport).handle(step("disable_user", state: Self.inSession))
        #expect(refused.ok == false)
        #expect(refused.message?.contains("answered 404") == true)
        let unknown = try await handler(transport).handle(step("release", state: Self.inSession))
        #expect(unknown.ok == false)
        #expect(unknown.message?.contains("auth.release is not a step") == true)
    }

    @Test("flow_end releases the run's session; a session nothing reached counts as released")
    func flowEndReleases() async throws {
        let transport = StubTransport([Self.release: [(204, ""), (404, ""), (500, "")]])
        let first = try await handler(transport).handle(flowEnd(Self.inSession))
        #expect(first.ok == true)
        let unused = try await handler(transport).handle(flowEnd(Self.inSession))
        #expect(unused.ok == true)
        let failed = try await handler(transport).handle(flowEnd(Self.inSession))
        #expect(failed.ok == false)
        #expect(failed.message?.contains("answered 500") == true)
    }

    @Test("Without a session, flow_end undoes the first change to each account")
    func sharedDataIsRestored() async throws {
        let transport = StubTransport([Self.disable: [(204, "")], Self.enable: [(204, "")]])
        let disabled = try await handler(transport).handle(step("disable_user", state: Self.shared))
        let afterFirst = try #require(disabled.state)
        #expect(afterFirst.backend?.changed == ["user@example.com": "disable_user"])
        #expect(await transport.sentHeaders.first?["X-Test-Session"] == nil)
        let enabled = try await handler(transport).handle(step("enable_user", state: afterFirst))
        let afterSecond = try #require(enabled.state)
        #expect(afterSecond.backend?.changed == ["user@example.com": "disable_user"])

        let end = try await handler(transport).handle(flowEnd(afterSecond))
        #expect(end.ok == true)
        #expect(end.message == "Restored 1 account(s)")
        #expect(await transport.sent.last == .init(method: "DELETE", path: "/_test/accounts/user@example.com/disabled", body: nil))
    }
}

@Suite("AuthEmitter")
struct AuthEmitterTests {
    private func emitter(_ section: String = TestRoutesTests.section) throws -> AuthEmitter {
        let url = FileManager.default.temporaryDirectory.appending(path: "auth-\(UUID().uuidString).json")
        try Data("{\(section)}".utf8).write(to: url)
        return AuthEmitter(environment: [AuthHandler.configEnvironmentVariable: url.path])
    }

    @Test("Setup gives the test a session id, the helpers that call the backend, and the launch keys")
    func setup() throws {
        let reply = try emitter().handle(EmitRequest(framework: "xcuitest", phase: "setup"))
        #expect(reply.ok != false)
        #expect(
            reply.lines == [
                #"app.launchEnvironment["APP_BASE_URL"] = "http://127.0.0.1:8081""#,
                #"app.launchEnvironment["APP_TEST_SESSION"] = "\(authSession)""#,
            ])
        let members = try #require(reply.members)
        #expect(members.count == 3)
        #expect(members[0].contains("private let authSession = UUID().uuidString.lowercased()"))
        #expect(members[1].contains(#"URL(string: "http://127.0.0.1:8081" + path)"#))
        #expect(members[1].contains(#"request.setValue(authSession, forHTTPHeaderField: "X-Test-Session")"#))
        #expect(members[2].contains("private func authExpect("))
        #expect(reply.requires == nil)
    }

    @Test("Teardown releases the session without failing the test, and a step calls its route")
    func teardownAndStep() throws {
        let emitter = try emitter()
        let teardown = emitter.handle(EmitRequest(framework: "xcuitest", phase: "teardown"))
        #expect(teardown.lines == [#"_ = try? authCall("DELETE", "/_test/sessions/\(authSession)")"#])
        let step = emitter.handle(
            EmitRequest(
                framework: "xcuitest", phase: "step",
                step: .init(tool: "disable_user", arguments: ["email": .string("user@example.com")])))
        #expect(step.lines == [#"try authExpect("PUT", "/_test/accounts/user@example.com/disabled")"#])
        #expect(step.requires == ["throws"])
    }

    @Test("A step without a route, another framework, the emulator provider and a missing config answer ok: false")
    func unsupported() throws {
        let emitter = try emitter()
        let noRoute = emitter.handle(
            EmitRequest(
                framework: "xcuitest", phase: "step",
                step: .init(tool: "revoke_tokens", arguments: ["email": .string("user@example.com")])))
        #expect(noRoute.ok == false)
        #expect(noRoute.message?.contains("no revoke_tokens route") == true)
        let espresso = emitter.handle(EmitRequest(framework: "espresso", phase: "setup"))
        #expect(espresso.ok == false)
        let firebase = try self.emitter(#""auth": {"provider": "firebase-emulator", "projectId": "demo-example"}"#)
            .handle(EmitRequest(framework: "xcuitest", phase: "setup"))
        #expect(firebase.ok == false)
        #expect(firebase.message?.contains("test-routes provider only") == true)
        let noConfig = AuthEmitter(environment: [:]).handle(EmitRequest(framework: "xcuitest", phase: "setup"))
        #expect(noConfig.ok == false)
        #expect(noConfig.message?.contains(AuthHandler.configEnvironmentVariable) == true)
    }
}
