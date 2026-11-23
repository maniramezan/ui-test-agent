import Foundation
import Testing

@testable import MoqBridge

@Suite("SessionLifecycle")
struct SessionLifecycleTests {
    private func lifecycle(
        _ transport: StubTransport,
        config: AppConfig = Fixtures.config(),
        port: Int? = nil,
        environment: [String: String] = [:]
    ) -> SessionLifecycle {
        SessionLifecycle(
            config: config,
            portOverride: port,
            environment: environment,
            transport: transport,
            pollInterval: .milliseconds(10)
        )
    }

    @Test("Start waits for readiness, opens a session and renders launch keys per platform")
    func startRendersLaunchEnvironment() async throws {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.failure, .status(503), .status(200, body: "[]")],
            "POST /_admin/sessions": [.status(200, body: #"{"id":"S-1"}"#)],
        ])
        let started = try await lifecycle(transport, port: 18080).start(platform: .android)
        #expect(started.sessionId == "S-1")
        #expect(started.adminBaseURL == "http://127.0.0.1:18080")
        #expect(!started.requireSession)
        #expect(
            started.launchEnvironment == [
                "APP_BASE_URL": "http://10.0.2.2:18080",
                "APP_SESSION": "S-1",
                "APP_FIXED": "127.0.0.1:9099",
            ])
        let sent = await transport.sent
        #expect(sent.map(\.method) == ["GET", "GET", "GET", "POST"])
    }

    @Test("Start fails with serverNotReady when the server never answers")
    func startTimesOut() async {
        let transport = StubTransport(["GET /_admin/endpoints": [.failure]])
        let config = Fixtures.config(readinessTimeoutSeconds: 0.05)
        await #expect(
            throws: BridgeError.serverNotReady(
                url: "http://127.0.0.1:8080/_admin/endpoints", seconds: 0.05)
        ) {
            try await lifecycle(transport, config: config).start(platform: .ios)
        }
    }

    @Test("A 401 during readiness fails at once instead of waiting")
    func unauthorizedFailsFast() async {
        let transport = StubTransport(["GET /_admin/endpoints": [.status(401)]])
        await #expect(
            throws: BridgeError.adminUnauthorized(url: "http://127.0.0.1:8080/_admin/endpoints")
        ) {
            try await lifecycle(transport, config: Fixtures.config(readinessTimeoutSeconds: 30))
                .start(platform: .ios)
        }
        #expect(await transport.sent.count == 1)
    }

    @Test("Admin credentials come from the named environment variable")
    func bearerCredential() async throws {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(200, body: #"{"id":"S-2"}"#)],
        ])
        let config = Fixtures.config(adminAuth: .bearer(tokenEnv: "MOQ_ADMIN_TOKEN"))
        _ = try await lifecycle(transport, config: config, environment: ["MOQ_ADMIN_TOKEN": "t0k"])
            .start(platform: .ios)
        let sent = await transport.sent
        #expect(sent.allSatisfy { $0.headers["Authorization"] == "Bearer t0k" })
    }

    @Test("A missing credential variable fails before any request")
    func missingCredential() async {
        let transport = StubTransport([:])
        let config = Fixtures.config(adminAuth: .apiKey(header: "X-Admin-Key", valueEnv: "MOQ_KEY"))
        await #expect(throws: BridgeError.missingAdminCredential(environmentVariable: "MOQ_KEY")) {
            try await lifecycle(transport, config: config).start(platform: .ios)
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test("A session response without an id is malformed")
    func malformedSession() async {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(200, body: "{}")],
        ])
        await #expect(throws: BridgeError.malformedResponse(url: "http://127.0.0.1:8080/_admin/sessions")) {
            try await lifecycle(transport).start(platform: .ios)
        }
    }

    @Test("Session capacity (409) surfaces as an unexpected status")
    func capacityReached() async {
        let transport = StubTransport([
            "GET /_admin/endpoints": [.status(200)],
            "POST /_admin/sessions": [.status(409)],
        ])
        await #expect(
            throws: BridgeError.unexpectedStatus(
                method: "POST", url: "http://127.0.0.1:8080/_admin/sessions", status: 409)
        ) {
            try await lifecycle(transport).start(platform: .ios)
        }
    }

    @Test("End releases the session and treats 404 as already released", arguments: [200, 204, 404])
    func endIsIdempotent(status: Int) async throws {
        let transport = StubTransport(["DELETE /_admin/sessions/S-3": [.status(status)]])
        try await lifecycle(transport).end(sessionId: "S-3")
        #expect(await transport.sent.map(\.path) == ["/_admin/sessions/S-3"])
    }

    @Test("End reports other failures")
    func endFails() async {
        let transport = StubTransport(["DELETE /_admin/sessions/S-4": [.status(500)]])
        await #expect(
            throws: BridgeError.unexpectedStatus(
                method: "DELETE", url: "http://127.0.0.1:8080/_admin/sessions/S-4", status: 500)
        ) {
            try await lifecycle(transport).end(sessionId: "S-4")
        }
    }
}
