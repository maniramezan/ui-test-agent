import Foundation
import Testing

@testable import MoqBridge

@Suite("TestEmitter")
struct TestEmitterTests {
    private func configFile(adminAuth: String = #"{"kind":"none"}"#) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moq-\(UUID().uuidString).json")
        let json = """
            {"app":"sample","server":{"port":8080,"adminHost":"127.0.0.1","readinessPath":"/_admin/endpoints",
            "readinessTimeoutSeconds":30,"adminAuth":\(adminAuth)},
            "platforms":{"ios":{"appHost":"127.0.0.1","requireSession":true,"launchEnvironment":
            {"APP_MOCK_BASE_URL":"{{baseURL}}/api","APP_MOCK_SESSION":"{{sessionId}}","APP_FIXED":"say \\"hi\\""}},
            "android":{"appHost":"10.0.2.2","requireSession":true,"launchEnvironment":
            {"APP_MOCK_BASE_URL":"{{baseURL}}/api","APP_MOCK_SESSION":"{{sessionId}}"}}}}
            """
        try Data(json.utf8).write(to: url)
        return url
    }

    private func step(_ tool: String, _ arguments: String = "{}") throws -> EmitReply {
        let arguments = try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.utf8))
        return try TestEmitter(environment: [:]).handle(
            EmitRequest(framework: "xcuitest", phase: "step", step: .init(tool: tool, arguments: arguments)))
    }

    @Test("setup opens a session and sets the config's launch keys on the app")
    func setup() throws {
        let url = try configFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = try TestEmitter(environment: ["AMOO_EXT_MOQ_CONFIG": url.path]).handle(
            EmitRequest(framework: "xcuitest", platform: "ios", phase: "setup"))
        #expect(reply.ok == nil)
        #expect(reply.imports == ["MoqTestSupport"])
        #expect(reply.requires == ["throws"])
        #expect(reply.members == TestEmitter.members)
        #expect(
            reply.lines == [
                #"let moqPort = ProcessInfo.processInfo.environment["MOQ_PORT"] ?? "8080""#,
                #"let moqAdminURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(moqPort)"))"#,
                "let moqClient = try MoqClient(baseURL: moqAdminURL).createSession()",
                "moqSession = moqClient",
                "let moqSessionID = try XCTUnwrap(moqClient.sessionID)",
                #"let moqBaseURL = "http://127.0.0.1:\(moqPort)""#,
                #"app.launchEnvironment["APP_FIXED"] = "say \"hi\"""#,
                #"app.launchEnvironment["APP_MOCK_BASE_URL"] = "\(moqBaseURL)/api""#,
                #"app.launchEnvironment["APP_MOCK_SESSION"] = "\(moqSessionID)""#,
            ])
    }

    @Test("setup reads the admin credential from the environment variable the config names")
    func setupWithAuth() throws {
        let url = try configFile(adminAuth: #"{"kind":"bearer","tokenEnv":"MOQ_ADMIN_TOKEN"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = try TestEmitter(environment: ["AMOO_EXT_MOQ_CONFIG": url.path]).handle(
            EmitRequest(framework: "xcuitest", phase: "setup"))
        #expect(
            reply.lines?.contains(
                #"let moqClient = try MoqClient(baseURL: moqAdminURL, auth: .bearer(ProcessInfo.processInfo.environment["MOQ_ADMIN_TOKEN"] ?? "")).createSession()"#
            ) == true)
    }

    @Test("setup without a config fails with what to set")
    func setupWithoutConfig() throws {
        let reply = try TestEmitter(environment: [:]).handle(EmitRequest(framework: "xcuitest", phase: "setup"))
        #expect(reply.ok == false)
        #expect(reply.message?.contains("AMOO_EXT_MOQ_CONFIG") == true)
    }

    @Test("teardown releases the session")
    func teardown() throws {
        let reply = try TestEmitter(environment: [:]).handle(EmitRequest(framework: "xcuitest", phase: "teardown"))
        #expect(reply.lines == ["try moqSession?.closeSession()"])
        #expect(reply.requires == ["throws"])
    }

    @Test("Each step becomes the MoqClient call of the same name")
    func steps() throws {
        #expect(try step("activate_scenario", #"{"name":"checkout-down"}"#).lines == [
            #"try moq().activateScenario("checkout-down")"#
        ])
        #expect(try step("select_variant", #"{"endpoint":"get /v1/tasks","variant":"server-error","times":"1"}"#).lines == [
            #"try moq().selectVariant("server-error", for: "GET", path: "/v1/tasks", times: 1)"#
        ])
        #expect(try step("select_variant", #"{"endpoint":"POST /graphql","variant":"error","operation":"GetUser"}"#).lines == [
            #"try moq().selectVariant("error", for: "POST", path: "/graphql", operation: "GetUser")"#
        ])
        #expect(try step("reset_variant", #"{"endpoint":"GET /v1/tasks"}"#).lines == [
            #"try moq().resetVariant(for: "GET", path: "/v1/tasks")"#
        ])
        #expect(try step("mark", #"{"name":"before-delete"}"#).lines == ["let moqMarkBeforeDelete = try moq().mark()"])
        #expect(try step("assert_no_rejected_requests").lines == ["try moq().assertNoRejectedRequests()"])
        #expect(try step("assert_no_rejected_requests", #"{"since":"before-delete"}"#).lines == [
            "try moq().assertNoRejectedRequests(since: moqMarkBeforeDelete)"
        ])
        #expect(try step("assert_no_unmatched_requests").lines == ["try moq().assertNoUnmatchedRequests()"])
        #expect(try step("assert_all_requests_carry_session").lines == ["_ = try moq().assertAllRequestsCarrySession()"])
        #expect(
            try step("assert_all_requests_carry_session", #"{"claims":{"sub":"user-1"},"include_unattributed":true,"since":1700000000}"#)
                .lines == [
                    #"_ = try moq().assertAllRequestsCarrySession(claims: ["sub": "user-1"], includeUnattributed: true, since: 1700000000.0)"#
                ])
        #expect(try step("assert_session_reached", #"{"timeout_ms":5000}"#).lines == ["_ = try moq().assertRequest(timeout: 5)"])
        #expect(try step("assert_session_reached").lines == ["_ = try moq().assertRequest()"])
        #expect(
            try step(
                "assert_request",
                #"{"endpoint":"GET /v1/tasks","times":1,"query":[{"name":"status","equals":"done"},{"name":"page","present":true},{"name":"cursor","present":false},{"name":"api_key","fingerprint_of":"k-1"}],"claims":{"sub":"user-1"}}"#
            ).lines == [
                #"_ = try moq().assertRequest(endpoint: "GET /v1/tasks", times: 1, query: [.equals("status", "done"), .present("page"), .absent("cursor"), .fingerprint("api_key", of: "k-1")], claims: ["sub": "user-1"])"#
            ])
    }

    @Test("assert_request carries every predicate, one MoqHeaderExpectation per header item")
    func assertRequest() throws {
        let reply = try step(
            "assert_request",
            #"""
            {"endpoint":"GET /v1/tasks","times":1,"claims":{"sub":"user-1"},"since":"before-delete","timeout_ms":1500,
             "headers":[{"name":"Authorization","scheme":"Bearer"},{"name":"Cookie","present":true},
                        {"name":"X-Debug","present":false},{"name":"Authorization","fingerprint_of":"abc"},
                        {"name":"Accept","equals":"application/json"}]}
            """#)
        #expect(
            reply.lines == [
                #"_ = try moq().assertRequest(endpoint: "GET /v1/tasks", times: 1, headers: [.scheme("Authorization", "Bearer"), .present("Cookie"), .absent("X-Debug"), .fingerprint("Authorization", of: "abc"), .equals("Accept", "application/json")], claims: ["sub": "user-1"], since: moqMarkBeforeDelete, timeout: 1.5)"#
            ])
        #expect(reply.requires == ["throws"])
        #expect(try step("assert_request", #"{"endpoint":"DELETE /v1/tasks/{id}","times":0}"#).lines == [
            #"_ = try moq().assertRequest(endpoint: "DELETE /v1/tasks/{id}", times: 0)"#
        ])
    }

    @Test("A bad argument, an unknown step or another framework is refused with the reason")
    func refusals() throws {
        let typo = try step("mark", #"{"nmae":"x"}"#)
        #expect(typo.ok == false)
        let unknown = try step("record_traffic")
        #expect(unknown.ok == false)
        #expect(unknown.message?.contains("moq.record_traffic") == true)
        let other = try TestEmitter(environment: [:]).handle(EmitRequest(framework: "flutter", phase: "teardown"))
        #expect(other.ok == false)
        #expect(other.message?.contains("flutter") == true)
    }

    private func kotlinStep(_ tool: String, _ arguments: String = "{}") throws -> EmitReply {
        let arguments = try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.utf8))
        return try TestEmitter(environment: [:]).handle(
            EmitRequest(framework: "compose", platform: "android", phase: "step", step: .init(tool: tool, arguments: arguments)))
    }

    @Test("Kotlin setup opens a session on the host the app uses and adds the launch keys to the activity's intent")
    func kotlinSetup() throws {
        let url = try configFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // The config is found through the flow's variables, as flow_start finds it.
        let reply = try TestEmitter(environment: [:]).handle(
            EmitRequest(framework: "compose", platform: "android", phase: "setup", vars: ["moq_config": url.path]))
        #expect(reply.ok == nil)
        #expect(reply.imports == TestEmitter.kotlinImports)
        #expect(reply.members == TestEmitter.kotlinMembers)
        #expect(reply.requires == nil)
        let lines = try #require(reply.lines)
        #expect(lines.first == #"val moqPort = InstrumentationRegistry.getArguments().getString("MOQ_PORT") ?: "8080""#)
        #expect(lines.contains(#"val moqBaseUrl = "http://10.0.2.2:$moqPort""#))
        #expect(lines.contains("val moqClient = MoqClient(moqBaseUrl).createSession()"))
        #expect(lines.contains(#"moqLaunchExtras["APP_MOCK_BASE_URL"] = "$moqBaseUrl/api""#))
        #expect(lines.contains(#"moqLaunchExtras["APP_MOCK_SESSION"] = "$moqSessionId""#))
        #expect(lines.last == "ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(moqLaunchCallback)")

        let teardown = try TestEmitter(environment: [:]).handle(
            EmitRequest(framework: "espresso", platform: "android", phase: "teardown"))
        #expect(teardown.lines == [
            "ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(moqLaunchCallback)",
            "moqSession?.closeSession()",
        ])
    }

    @Test("Each step becomes the Kotlin client's call, with the imports its expectations need")
    func kotlinSteps() throws {
        #expect(try kotlinStep("activate_scenario", #"{"name":"checkout-down"}"#).lines == [
            #"moq().activateScenario("checkout-down")"#
        ])
        #expect(try kotlinStep("select_variant", #"{"endpoint":"get /v1/tasks","variant":"serverError","times":"1"}"#).lines == [
            #"moq().selectVariant("serverError", "GET", "/v1/tasks", times = 1)"#
        ])
        #expect(try kotlinStep("select_variant", #"{"endpoint":"POST /graphql","variant":"error","operation":"GetUser"}"#).lines == [
            #"moq().selectVariant("error", "POST", "/graphql", operation = "GetUser")"#
        ])
        #expect(try kotlinStep("reset_variant", #"{"endpoint":"GET /v1/tasks"}"#).lines == [
            #"moq().resetVariant("GET", "/v1/tasks")"#
        ])
        #expect(try kotlinStep("mark", #"{"name":"before-delete"}"#).lines == ["val moqMarkBeforeDelete = moq().mark()"])
        let request = try kotlinStep(
            "assert_request",
            #"{"endpoint":"GET /v1/tasks","times":1,"headers":[{"name":"Authorization","scheme":"Bearer"},{"name":"Cookie","present":true}],"query":[{"name":"status","equals":"done"}],"claims":{"sub":"user-1"},"since":"before-delete","timeout_ms":3000}"#)
        #expect(request.lines == [
            #"moq().assertRequest("GET /v1/tasks", times = 1, headers = listOf(MoqHeaderExpectation.Scheme("Authorization", "Bearer"), MoqHeaderExpectation.Present("Cookie")), claims = mapOf("sub" to "user-1"), since = moqMarkBeforeDelete, timeoutMillis = 3000, query = listOf(MoqQueryExpectation.Equals("status", "done")))"#
        ])
        #expect(request.imports == [TestEmitter.headerExpectationImport, TestEmitter.queryExpectationImport])
        #expect(request.requires == nil)
        #expect(try kotlinStep("assert_no_rejected_requests", #"{"since":"1700000000"}"#).lines == [
            "moq().assertNoRejectedRequests(since = 1700000000.0)"
        ])
        #expect(try kotlinStep("assert_session_reached", #"{"timeout_ms":5000}"#).lines == ["moq().assertRequest(timeoutMillis = 5000)"])
        #expect(try kotlinStep("assert_no_unmatched_requests").lines == ["moq().assertNoUnmatchedRequests()"])
        #expect(
            try kotlinStep("assert_all_requests_carry_session", #"{"claims":{"sub":"user-1"},"include_unattributed":true}"#).lines == [
                #"moq().assertAllRequestsCarrySession(claims = mapOf("sub" to "user-1"), includeUnattributed = true)"#
            ])
        // A dollar sign from a flow stays text in a Kotlin string.
        #expect(try kotlinStep("activate_scenario", #"{"name":"price $5 \"now\""}"#).lines == [
            #"moq().activateScenario("price \$5 \"now\"")"#
        ])
    }

    @Test("Text from a flow can't break out of a Swift string literal")
    func escaping() throws {
        #expect(try step("activate_scenario", #"{"name":"a\"b\\(c)"}"#).lines == [
            #"try moq().activateScenario("a\"b\\(c)")"#
        ])
    }
}
