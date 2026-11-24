import Foundation
import Testing

@testable import MoqBridge

/// The request-check steps send moqserver's query with the same body as the MoqClient call of the
/// same name, and pass the server's verdict through.
@Suite("Request checks")
struct RequestCheckTests {
    private static let configPath: String = {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "examples/moq.json")
            .path
    }()

    private static func state(marks: [String: Double]? = nil, capabilities: [String]? = nil) -> BridgeState {
        BridgeState(
            configPath: configPath, port: 18080, platform: .ios, sessionId: "S-1", marks: marks,
            capabilities: capabilities)
    }

    private static let passing = #"{"ok":true,"count":1,"expected":1,"matched":[],"nearMisses":[],"unattributed":[],"message":"1 request matched"}"#
    private static let failing = #"{"ok":false,"count":0,"expected":1,"matched":[],"nearMisses":[],"unattributed":[],"message":"Expected 1 request to GET /v1/me, got 0"}"#

    private func run(
        _ tool: String,
        arguments: String = "{}",
        state: BridgeState = RequestCheckTests.state(),
        replies: [String: [StubTransport.Reply]]
    ) async throws -> (ExtensionReply, [StubTransport.Sent]) {
        let transport = StubTransport(replies)
        let encodedState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let request = try JSONDecoder().decode(
            ExtensionRequest.self,
            from: Data(
                #"{"protocol":1,"verb":"step","run":{"id":"r1","platform":"ios"},"state":\#(encodedState),"step":{"tool":"\#(tool)","number":1,"arguments":\#(arguments)}}"#
                    .utf8))
        let reply = try await ExtensionHandler(environment: [:], transport: transport).handle(request)
        return (reply, await transport.sent)
    }

    private func object(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("mark stores the server time under its name for later steps")
    func mark() async throws {
        let (reply, sent) = try await run(
            "mark", arguments: #"{"name":"signed-out"}"#,
            replies: ["POST /_admin/requests/mark": [.status(200, body: #"{"timestamp":1732000123.5}"#)]])
        #expect(reply.ok == true)
        #expect(reply.state?.marks == ["signed-out": 1732000123.5])
        #expect(sent.first?.headers["X-Mock-Session"] == "S-1")
    }

    @Test("assert_request sends assertRequest's query, with since resolved from a mark")
    func assertRequestQuery() async throws {
        let (reply, sent) = try await run(
            "assert_request",
            arguments: #"""
                {"endpoint":"GET /v1/me","times":0,"since":"signed-out",
                 "headers":[{"name":"Authorization","present":true},{"name":"Authorization","scheme":"Bearer"},
                            {"name":"Authorization","fingerprint_of":"tok"},{"name":"Accept","equals":"*/*"}],
                 "claims":{"sub":"user-1"}}
                """#,
            state: Self.state(marks: ["signed-out": 100]),
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(reply.ok == true)
        #expect(reply.message == "1 request matched")
        #expect(reply.state?.marks == ["signed-out": 100])
        #expect(
            sent.first?.body
                == (try object(
                    #"""
                    {"endpoint":"GET /v1/me","times":0,"since":100,"claims":{"sub":"user-1"},
                     "headers":[{"name":"Authorization","present":true},{"name":"Authorization","scheme":"Bearer"},
                                {"name":"Authorization","fingerprintOf":"tok"},{"name":"Accept","equals":"*/*"}]}
                    """#)))
    }

    @Test("assert_request leaves out empty headers, claims, times and since, like the client")
    func assertRequestMinimal() async throws {
        let (_, sent) = try await run(
            "assert_request", arguments: #"{"endpoint":"GET /v1/me"}"#,
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(sent.first?.body == (try object(#"{"endpoint":"GET /v1/me"}"#)))
    }

    @Test("A failing check fails the step with the server's message and keeps the verdict")
    func assertRequestFails() async throws {
        let (reply, _) = try await run(
            "assert_request", arguments: #"{"endpoint":"GET /v1/me","times":1}"#,
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.failing)]])
        #expect(reply.ok == false)
        #expect(reply.message == "Expected 1 request to GET /v1/me, got 0")
        #expect(reply.result == (try object(Self.failing)))
    }

    @Test("timeout_ms re-polls until the check passes")
    func assertRequestPolls() async throws {
        let (reply, sent) = try await run(
            "assert_request", arguments: #"{"endpoint":"GET /v1/me","timeout_ms":2000}"#,
            replies: [
                "POST /_admin/requests/query": [
                    .status(200, body: Self.failing), .status(200, body: Self.failing),
                    .status(200, body: Self.passing),
                ]
            ])
        #expect(reply.ok == true)
        #expect(sent.count == 3)
    }

    @Test("An unknown mark name fails the step before any request")
    func unknownMark() async throws {
        let (reply, sent) = try await run(
            "assert_request", arguments: #"{"endpoint":"GET /v1/me","since":"nope"}"#,
            state: Self.state(marks: ["signed-out": 1]),
            replies: [:])
        #expect(reply.ok == false)
        #expect(reply.message == "Argument since: no moq.mark named 'nope' in this run (marks: signed-out)")
        #expect(sent.isEmpty)
    }

    @Test("A header item needs exactly one predicate")
    func headerPredicateShape() async throws {
        let (reply, _) = try await run(
            "assert_request",
            arguments: #"{"endpoint":"GET /v1/me","headers":[{"name":"Authorization","scheme":"Bearer","present":true}]}"#,
            replies: [:])
        #expect(reply.ok == false)
        #expect(reply.message?.contains("exactly one of present, scheme, fingerprint_of, equals") == true)
    }

    @Test("assert_no_rejected_requests sends assertNoRejectedRequests's query")
    func noRejected() async throws {
        let (reply, sent) = try await run(
            "assert_no_rejected_requests",
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(reply.ok == true)
        #expect(sent.first?.body == (try object(#"{"rejected":true,"times":0}"#)))
    }

    @Test("assert_all_requests_carry_session sends assertAllRequestsCarrySession's query")
    func carrySession() async throws {
        let (_, sent) = try await run(
            "assert_all_requests_carry_session",
            arguments: #"{"claims":{"sub":"user-1"},"include_unattributed":true,"since":5}"#,
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(
            sent.first?.body
                == (try object(
                    #"{"times":0,"scope":"sessionless","since":5,"claims":{"sub":"user-1"},"includeUnattributed":true}"#
                )))
    }

    @Test("Without claims or include_unattributed the session query leaves them out")
    func carrySessionMinimal() async throws {
        let (_, sent) = try await run(
            "assert_all_requests_carry_session",
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(sent.first?.body == (try object(#"{"times":0,"scope":"sessionless"}"#)))
    }

    @Test("assert_session_reached polls an unfiltered session query until a request arrives")
    func sessionReached() async throws {
        let (reply, sent) = try await run(
            "assert_session_reached", arguments: #"{"timeout_ms":2000}"#,
            replies: [
                "POST /_admin/requests/query": [.status(200, body: Self.failing), .status(200, body: Self.passing)]
            ])
        #expect(reply.ok == true)
        #expect(reply.message == "The app reached session S-1")
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.body == .object([:]) && $0.headers["X-Mock-Session"] == "S-1" })
    }

    @Test("assert_session_reached fails with a hint when nothing arrives")
    func sessionNotReached() async throws {
        let (reply, _) = try await run(
            "assert_session_reached", arguments: #"{"timeout_ms":150}"#,
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.failing)]])
        #expect(reply.ok == false)
        #expect(
            reply.message
                == "No request reached session S-1 within 150 ms. The app may have launched without the session key and be calling its real backend."
        )
    }

    @Test("Without header capture the server's 409 reason fails the step")
    func headerCaptureOff() async throws {
        let (reply, _) = try await run(
            "assert_request", arguments: #"{"endpoint":"GET /v1/me","headers":[{"name":"Authorization","present":false}]}"#,
            replies: [
                "POST /_admin/requests/query": [
                    .status(409, body: #"{"reason":"Header predicates need serve --capture-request-headers"}"#)
                ]
            ])
        #expect(reply.ok == false)
        #expect(reply.message?.hasSuffix("Header predicates need serve --capture-request-headers") == true)
    }

    @Test("select_variant with times sends a one-shot override")
    func limitedVariant() async throws {
        let (reply, sent) = try await run(
            "select_variant", arguments: #"{"endpoint":"GET /v1/me","variant":"unauthorized","times":"1"}"#,
            replies: ["PUT /_admin/endpoints/GET/v1/me/variant": [.status(200)]])
        #expect(reply.ok == true)
        #expect(reply.message == "GET /v1/me → unauthorized for the next 1 request(s)")
        #expect(sent.first?.body == (try object(#"{"variant":"unauthorized","times":1}"#)))
    }

    @Test("select_variant refuses times below 1")
    func limitedVariantBounds() async throws {
        let (reply, sent) = try await run(
            "select_variant", arguments: #"{"endpoint":"GET /v1/me","variant":"unauthorized","times":0}"#,
            replies: [:])
        #expect(reply.ok == false)
        #expect(sent.isEmpty)
    }

    @Test("assert_no_unmatched_requests sends the clients' unmatched query")
    func noUnmatched() async throws {
        let (reply, sent) = try await run(
            "assert_no_unmatched_requests",
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.failing)]])
        #expect(reply.ok == false)
        #expect(sent.first?.body == (try object(#"{"unmatched":true,"times":0}"#)))
    }

    @Test("A query step on a server without request-query fails without querying")
    func missingRequestQuery() async throws {
        let (reply, sent) = try await run(
            "assert_no_unmatched_requests", state: Self.state(capabilities: ["limited-overrides"]), replies: [:])
        #expect(reply.ok == false)
        #expect(reply.message == BridgeError.missingCapability("request-query", step: "assert_no_unmatched_requests").errorDescription)
        #expect(sent.isEmpty)
    }

    @Test("select_variant needs limited-overrides only when it sets times")
    func selectVariantTimesCapability() async throws {
        let route = "PUT /_admin/endpoints/GET/v1/me/variant"
        let (plain, _) = try await run(
            "select_variant", arguments: #"{"endpoint":"GET /v1/me","variant":"error"}"#,
            state: Self.state(capabilities: []), replies: [route: [.status(200)]])
        #expect(plain.ok == true)
        let (limited, sent) = try await run(
            "select_variant", arguments: #"{"endpoint":"GET /v1/me","variant":"error","times":"1"}"#,
            state: Self.state(capabilities: []), replies: [route: [.status(200)]])
        #expect(limited.ok == false)
        #expect(limited.message?.contains("limited-overrides") == true)
        #expect(sent.isEmpty)
    }

    @Test("State from before capabilities were recorded skips the check")
    func noRecordedCapabilities() async throws {
        let (reply, _) = try await run(
            "assert_no_unmatched_requests", state: Self.state(),
            replies: ["POST /_admin/requests/query": [.status(200, body: Self.passing)]])
        #expect(reply.ok == true)
    }
}
