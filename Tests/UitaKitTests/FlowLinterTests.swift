import ExtensionKit
import Foundation
import Testing

@testable import UitaKit

@Suite("FlowLinter")
struct FlowLinterTests {
    static let endpoints: Set<String> = ["GET /v1/tasks", "DELETE /v1/tasks", "DELETE /v1/tasks/{id}"]

    private func flow(_ json: String) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
    }

    private func lint(_ json: String, endpoints: Set<String>? = FlowLinterTests.endpoints) throws -> [Finding] {
        FlowLinter(
            endpoints: endpoints, workingDirectory: URL(filePath: "/work"),
            fileExists: { $0 == "/work/moq.json" }
        ).lint(try flow(json))
    }

    static let good = """
        {
          "platform": "ios",
          "terminate_app_at_end": true,
          "vars": {"moq_config": "moq.json", "app_id": "com.example.app"},
          "steps": [
            {"tool": "device_launch_app", "arguments": {"app_id": "${app_id}"}},
            {"tool": "tap_element", "arguments": {"id": "signIn.submit", "expect_id": "tasks.count"}},
            {"tool": "moq.assert_session_reached", "arguments": {"timeout_ms": 5000}},
            {"tool": "moq.assert_request", "arguments": {"endpoint": "GET /v1/tasks/", "times": 1}},
            {"tool": "moq.mark", "arguments": {"name": "before-delete"}},
            {"tool": "tap_element", "arguments": {"label": "Delete"}},
            {"tool": "assert_visible", "arguments": {"id": "tasks.count"}},
            {"tool": "moq.assert_request", "arguments": {"endpoint": "delete /v1/tasks/{id}", "since": "before-delete"}}
          ]
        }
        """

    @Test("A flow that follows the rules has no findings")
    func clean() throws {
        #expect(try lint(Self.good) == [])
    }

    @Test("A launched app that isn't ended is an error with a mock session, a warning without")
    func appLifetime() throws {
        let mocked = try lint(Self.good.replacingOccurrences(of: #""terminate_app_at_end": true,"#, with: ""))
        #expect(mocked.map(\.rule) == ["terminate-app-at-end"])
        #expect(mocked.first?.severity == .error)
        let plain = try lint(#"{"steps": [{"tool": "device_launch_app", "arguments": {"app_id": "com.example.app"}}]}"#)
        #expect(plain.map(\.severity) == [.warning])
        let noLaunch = try lint(#"{"steps": [{"tool": "moq.mark", "arguments": {"name": "a"}}]}"#)
        #expect(noLaunch == [])
    }

    @Test("A mocked flow that launches an app must check the session was reached, before other request checks")
    func sessionReached() throws {
        let missing = try lint(
            Self.good.replacingOccurrences(
                of: #"{"tool": "moq.assert_session_reached", "arguments": {"timeout_ms": 5000}},"#, with: ""))
        #expect(missing.map(\.rule) == ["session-reached"])
        #expect(missing.first?.severity == .error)

        let late = try lint(
            """
            {"terminate_app_at_end": true, "steps": [
              {"tool": "device_launch_app", "arguments": {"app_id": "com.example.app"}},
              {"tool": "moq.assert_no_rejected_requests"},
              {"tool": "moq.assert_session_reached"}
            ]}
            """)
        #expect(late == [
            Finding(
                rule: "session-reached", severity: .warning, step: 2,
                message: "moq.assert_no_rejected_requests runs before moq.assert_session_reached (step 3). Check the session was reached first, so this step can't pass on an empty history.")
        ])
    }

    @Test("Variables alone don't start an extension")
    func extensionNotStarted() throws {
        let moq = try lint(#"{"vars": {"moq_port": "8095"}, "steps": [{"tool": "screenshot"}]}"#)
        #expect(moq.map(\.rule) == ["extension-not-started"])
        let declared = try lint(#"{"extensions": ["moq"], "vars": {"moq_port": "8095"}, "steps": [{"tool": "screenshot"}]}"#)
        #expect(declared == [])
        let auth = try lint(#"{"vars": {"auth_config": "moq.json"}, "steps": [{"tool": "screenshot"}]}"#)
        #expect(auth.map(\.rule) == ["extension-not-started"])
        let authStep = try lint(
            #"{"vars": {"auth_config": "moq.json"}, "steps": [{"tool": "auth.disable_user", "arguments": {"email": "user@example.com"}}]}"#
        )
        #expect(authStep == [])
    }

    @Test("A config path that doesn't exist where amoo runs is an error")
    func configMissing() throws {
        let findings = try lint(
            #"{"extensions": ["moq"], "vars": {"moq_config": "configs/moq.json"}, "steps": [{"tool": "screenshot"}]}"#)
        #expect(findings.map(\.rule) == ["config-missing"])
        #expect(findings.first?.message.contains("configs/moq.json") == true)
    }

    @Test("since must name an earlier mark; a number or a run-time variable is left alone")
    func undefinedMark() throws {
        let findings = try lint(
            """
            {"steps": [
              {"tool": "moq.assert_no_rejected_requests", "arguments": {"since": "start"}},
              {"tool": "moq.mark", "arguments": {"name": "start"}},
              {"tool": "moq.assert_no_rejected_requests", "arguments": {"since": "start"}},
              {"tool": "moq.assert_no_rejected_requests", "arguments": {"since": "1800000000"}},
              {"tool": "moq.assert_no_rejected_requests", "arguments": {"since": "${from_outside}"}}
            ]}
            """)
        #expect(findings.map(\.rule) == ["undefined-mark"])
        #expect(findings.first?.step == 1)
    }

    @Test("An endpoint key the bundle doesn't have is an error with the closest key; no bundle, no check")
    func unknownEndpoint() throws {
        let json = #"{"steps": [{"tool": "moq.select_variant", "arguments": {"endpoint": "DELETE /v1/task/{id}", "variant": "notFound"}}]}"#
        let findings = try lint(json)
        #expect(findings.map(\.rule) == ["unknown-endpoint"])
        #expect(findings.first?.message.contains(#"Closest: "DELETE /v1/tasks/{id}""#) == true)
        #expect(try lint(json, endpoints: nil) == [])
    }

    @Test("A tap needs an outcome on itself or an observing step right after it")
    func tapOutcome() throws {
        let findings = try lint(
            """
            {"steps": [
              {"tool": "tap_element", "arguments": {"id": "a"}},
              {"tool": "tap_element", "arguments": {"id": "b", "expect_label": "Done"}},
              {"tool": "tap_element", "arguments": {"id": "c"}},
              {"tool": "wait_for", "arguments": {"id": "d"}},
              {"tool": "tap_element", "arguments": {"id": "e"}}
            ]}
            """)
        #expect(findings.map(\.rule) == ["tap-outcome", "tap-outcome"])
        #expect(findings.map(\.step) == [1, 5])
        #expect(findings.allSatisfy { $0.severity == .warning })
    }

    @Test("The example's flows are clean")
    func exampleFlows() throws {
        let examples = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "examples")
        let directory = examples.appending(path: "flows/ios")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".amoo.json") }
        #expect(!files.isEmpty)
        let linter = FlowLinter(workingDirectory: examples)
        for file in files {
            #expect(linter.lint(try Flow.load(from: file)) == [], "\(file.lastPathComponent)")
        }
    }
}
