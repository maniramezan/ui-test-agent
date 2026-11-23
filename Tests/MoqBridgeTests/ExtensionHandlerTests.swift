import Foundation
import Testing

@testable import MoqBridge

@Suite("ExtensionHandler")
struct ExtensionHandlerTests {
    private static let configPath: String = {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "examples/moq.json")
            .path
    }()

    private static let state = BridgeState(
        configPath: configPath, port: 18080, platform: .ios, sessionId: "S-1")

    private func handler(_ transport: StubTransport, environment: [String: String] = [:])
        -> ExtensionHandler
    {
        ExtensionHandler(
            environment: environment, transport: transport, pollInterval: .milliseconds(10))
    }

    private func request(_ json: String) throws -> ExtensionRequest {
        try JSONDecoder().decode(ExtensionRequest.self, from: Data(json.utf8))
    }

    private func stepRequest(_ tool: String, arguments: String = "{}") throws -> ExtensionRequest {
        let state = String(decoding: try JSONEncoder().encode(Self.state), as: UTF8.self)
        return try request(
            #"{"protocol":1,"verb":"step","run":{"id":"r1","platform":"ios"},"state":\#(state),"step":{"tool":"\#(tool)","number":2,"arguments":\#(arguments)}}"#
        )
    }

    @Test("describe lists the implemented steps")
    func describe() async throws {
        let reply = try await handler(StubTransport([:]))
            .handle(request(#"{"protocol":1,"verb":"describe","run":{"id":"r1"},"state":null}"#))
        #expect(reply.steps == ExtensionHandler.steps)
    }

    @Test("Another protocol version is refused")
    func protocolMismatch() async throws {
        await #expect(throws: BridgeError.unsupportedProtocol(2)) {
            try await handler(StubTransport([:]))
                .handle(request(#"{"protocol":2,"verb":"describe","state":null}"#))
        }
    }

    @Test("flow_start opens a session for the run's platform and returns its launch keys")
    func flowStart() async throws {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(200, body: #"{"id":"S-9"}"#)],
        ])
        let reply = try await handler(transport).handle(
            request(
                #"{"protocol":1,"verb":"flow_start","run":{"id":"r1","platform":"android","device_id":"emulator-5554"},"state":null,"vars":{"moq_config":"\#(Self.configPath)","moq_port":"18080"}}"#
            ))
        #expect(reply.ok == true)
        #expect(reply.state == BridgeState(configPath: Self.configPath, port: 18080, platform: .android, sessionId: "S-9"))
        #expect(reply.launchEnvironment?["APP_MOCK_BASE_URL"] == "http://10.0.2.2:18080")
        #expect(reply.launchEnvironment?["APP_MOCK_SESSION"] == "S-9")
        #expect(reply.vars == ["moq_session": "S-9"])
    }

    @Test("flow_start reads the config path and port from the environment when the flow has none")
    func flowStartFromEnvironment() async throws {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(200, body: #"{"id":"S-8"}"#)],
        ])
        let reply = try await handler(
            transport,
            environment: ["AMOO_EXT_MOQ_CONFIG": Self.configPath, "MOQ_PORT": "19090"]
        ).handle(request(#"{"protocol":1,"verb":"flow_start","run":{"platform":"ios"},"state":null,"vars":{}}"#))
        #expect(reply.ok == true)
        #expect(reply.state?.port == 19090)
    }

    @Test("A relative moq_config resolves against the working directory itself")
    func relativeConfigPath() async throws {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(200, body: #"{"id":"S-7"}"#)],
        ])
        let repoRoot = URL(filePath: Self.configPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let handler = ExtensionHandler(
            environment: [:], transport: transport, currentDirectory: repoRoot,
            pollInterval: .milliseconds(10))
        let reply = try await handler.handle(
            request(
                #"{"protocol":1,"verb":"flow_start","run":{"platform":"ios"},"state":null,"vars":{"moq_config":"examples/../examples/moq.json"}}"#
            ))
        #expect(reply.ok == true)
        #expect(reply.state?.configPath == Self.configPath)
    }

    @Test("flow_start without a config fails the run with a message")
    func flowStartWithoutConfig() async throws {
        let reply = try await handler(StubTransport([:]))
            .handle(request(#"{"protocol":1,"verb":"flow_start","run":{"platform":"ios"},"state":null,"vars":{}}"#))
        #expect(reply.ok == false)
        #expect(reply.message?.contains("moq_config") == true)
    }

    @Test("flow_start rejects an unknown platform")
    func flowStartUnknownPlatform() async throws {
        let reply = try await handler(StubTransport([:])).handle(
            request(
                #"{"protocol":1,"verb":"flow_start","run":{"platform":"web"},"state":null,"vars":{"moq_config":"\#(Self.configPath)"}}"#
            ))
        #expect(reply.ok == false)
        #expect(reply.message == BridgeError.unknownPlatform("web").errorDescription)
    }

    @Test("select_variant sets the override inside the run's session")
    func selectVariant() async throws {
        let transport = StubTransport([
            "PUT /_admin/endpoints/GET/v1/words/%7Bid%7D/variant": [.status(200)]
        ])
        let reply = try await handler(transport).handle(
            stepRequest("select_variant", arguments: #"{"endpoint":"get /v1/words/{id}","variant":"server-error"}"#))
        #expect(reply.ok == true)
        #expect(reply.state == Self.state)
        let sent = await transport.sent
        #expect(sent.first?.headers["X-Mock-Session"] == "S-1")
    }

    @Test("A variant moqserver doesn't know fails the step with the server's reason")
    func selectUnknownVariant() async throws {
        let transport = StubTransport([
            "PUT /_admin/endpoints/GET/v1/me/variant": [
                .status(400, body: #"{"error":"Bad Request","reason":"Variant 'nope' not found for GET /v1/me"}"#)
            ]
        ])
        let reply = try await handler(transport).handle(
            stepRequest("select_variant", arguments: #"{"endpoint":"GET /v1/me","variant":"nope"}"#))
        #expect(reply.ok == false)
        #expect(reply.message?.hasSuffix("Variant 'nope' not found for GET /v1/me") == true)
    }

    @Test("An unknown argument fails the step instead of being ignored")
    func unknownArgument() async throws {
        let reply = try await handler(StubTransport([:])).handle(
            stepRequest("activate_scenario", arguments: #"{"name":"home-error","scenario":"x"}"#))
        #expect(reply.ok == false)
        #expect(reply.message == "Argument scenario: not an argument of this step")
    }

    @Test("activate_scenario and reset_variant call their admin routes")
    func scenarioAndReset() async throws {
        let transport = StubTransport([
            "PUT /_admin/scenario": [.status(200)],
            "DELETE /_admin/endpoints/POST/graphql/variant": [.status(200)],
        ])
        let activated = try await handler(transport).handle(
            stepRequest("activate_scenario", arguments: #"{"name":"home-error"}"#))
        let reset = try await handler(transport).handle(
            stepRequest("reset_variant", arguments: #"{"endpoint":"POST /graphql","operation":"GetUser"}"#))
        #expect(activated.ok == true)
        #expect(reset.ok == true)
        #expect(await transport.sent.map(\.method) == ["PUT", "DELETE"])
    }

    @Test("A step before a session exists fails")
    func stepWithoutSession() async throws {
        let reply = try await handler(StubTransport([:])).handle(
            request(#"{"protocol":1,"verb":"step","state":null,"step":{"tool":"activate_scenario","number":1,"arguments":{"name":"x"}}}"#))
        #expect(reply.ok == false)
        #expect(reply.message == BridgeError.noSession.errorDescription)
    }

    @Test("flow_end warns when amoo reports the app wasn't ended")
    func flowEndWarnsWhenAppStillRuns() async throws {
        let state = String(decoding: try JSONEncoder().encode(Self.state), as: UTF8.self)
        let warned = try await handler(StubTransport(["DELETE /_admin/sessions/S-1": [.status(200)]])).handle(
            request(#"{"protocol":1,"verb":"flow_end","state":\#(state),"passed":true,"app_terminated":false}"#))
        #expect(warned.ok == true)
        #expect(warned.message?.contains("terminate_app_at_end") == true)
        let quiet = try await handler(StubTransport(["DELETE /_admin/sessions/S-1": [.status(200)]])).handle(
            request(#"{"protocol":1,"verb":"flow_end","state":\#(state),"passed":true,"app_terminated":true}"#))
        #expect(quiet.message == "Released moqserver session S-1")
    }

    @Test("flow_end releases the session, and is a no-op without one")
    func flowEnd() async throws {
        let transport = StubTransport(["DELETE /_admin/sessions/S-1": [.status(200)]])
        let state = String(decoding: try JSONEncoder().encode(Self.state), as: UTF8.self)
        let released = try await handler(transport).handle(
            request(#"{"protocol":1,"verb":"flow_end","state":\#(state),"passed":true}"#))
        #expect(released.ok == true)
        #expect(await transport.sent.map(\.path) == ["/_admin/sessions/S-1"])

        let none = try await handler(StubTransport([:]))
            .handle(request(#"{"protocol":1,"verb":"flow_end","state":null,"passed":false}"#))
        #expect(none.ok == true)
    }
}
