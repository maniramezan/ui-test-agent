import Foundation
import Testing

@testable import UitaKit

/// Stands in for amoo: writes the report a run would leave, and fails the runs it is told to.
actor StubAmoo: CommandRunner {
    private let failing: [Int: String]
    private(set) var calls: [[String]] = []

    /// - Parameter failing: run number → the failure kind that run stops with at step 3.
    init(failing: [Int: String] = [:]) {
        self.failing = failing
    }

    func run(_ executable: String, _ arguments: [String], output: URL?) async throws -> CommandResult {
        calls.append(arguments)
        if arguments.first == "endpoint" {
            let listing = #"{"endpoints": [{"id": "a", "method": "get", "path": "/v1/tasks"}, {"id": "b", "method": "DELETE", "path": "/v1/tasks/{id}"}]}"#
            return CommandResult(status: 0, output: Data(listing.utf8))
        }
        guard let index = arguments.firstIndex(of: "--output-dir") else {
            return CommandResult(status: 2, output: Data())
        }
        let directory = URL(filePath: arguments[index + 1])
        let number = Int(directory.lastPathComponent.dropFirst(4)) ?? 0
        let kind = failing[number]
        let failed = kind.map {
            #", {"number": 3, "name": "Count", "tool": "assert_visible", "status": "failed", "result": {"failure_kind": "\#($0)"}}"#
        } ?? ""
        let report = #"{"elapsed_ms": \#(1000 + number), "steps": [{"number": 1, "tool": "device_launch_app", "status": "passed"}\#(failed)]}"#
        try Data(report.utf8).write(to: directory.appending(path: "report.json"))
        let session = #"{"schema": 1, "requests": 3, "unmatched": \#(number == 2 ? 1 : 0), "rejected": 0}"#
        try Data(session.utf8).write(to: directory.appending(path: "moq-session.json"))
        return CommandResult(status: kind == nil ? 0 : 1, output: Data())
    }
}

@Suite("RepeatRunner")
struct RepeatRunnerTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "uita-\(UUID().uuidString)")
    }

    @Test("Run counts: ln(0.05) / ln(1 − p), at least ten")
    func runCount() {
        #expect(RunCount.needed(failureRate: 0.2) == 14)
        #expect(RunCount.needed(failureRate: 0.1) == 29)
        #expect(RunCount.needed(failureRate: 0.5) == 10)
        #expect(RunCount.needed(failureRate: 0) == 10)
        #expect(abs(RunCount.ruledOutFailureRate(afterPasses: 14) - 0.193) < 0.001)
    }

    @Test("Every run gets its own output directory and runtime, and the extra arguments")
    func spreadsRuns() async throws {
        let amoo = StubAmoo()
        let output = directory()
        let summary = try await RepeatRunner(runner: amoo).run(
            flow: "flow.amoo.json", runs: 6, runtimes: ["runtime-a", "runtime-b"], outputDirectory: output,
            extraArguments: ["--var", "moq_port=8095"])
        #expect(summary.runs == 6)
        #expect(summary.passed == 6)
        #expect(summary.failures == [])
        #expect(summary.fastestMs == 1001)
        #expect(summary.slowestMs == 1006)
        let calls = await amoo.calls
        #expect(calls.count == 6)
        #expect(calls.allSatisfy { $0.prefix(2) == ["flow", "flow.amoo.json"] && $0.suffix(2) == ["--var", "moq_port=8095"] })
        let runtimes = calls.compactMap { call in call.firstIndex(of: "--runtime-id").map { call[$0 + 1] } }
        #expect(Set(runtimes) == ["runtime-a", "runtime-b"])
        #expect(Set(summary.outcomes.map(\.outputDirectory)).count == 6)
        #expect(summary.runsWithUnmatched == [2])
        #expect(summary.text.contains("6 of 6 runs passed (100%)"))
        #expect(summary.text.contains("Unmatched requests reached the mock session in runs 2"))
    }

    @Test("Failures are grouped by step, tool and failure kind, largest group first")
    func groupsFailures() async throws {
        let amoo = StubAmoo(failing: [1: "assertion_mismatch", 3: "timeout", 4: "assertion_mismatch"])
        let summary = try await RepeatRunner(runner: amoo).run(
            flow: "flow.amoo.json", runs: 5, runtimes: [], outputDirectory: directory())
        #expect(summary.passed == 2)
        #expect(summary.failures == [
            FailureGroup(
                failure: .init(step: 3, name: "Count", tool: "assert_visible", kind: "assertion_mismatch"),
                runs: [1, 4]),
            FailureGroup(failure: .init(step: 3, name: "Count", tool: "assert_visible", kind: "timeout"), runs: [3]),
        ])
        #expect(summary.text.contains(#"2× step 3 assert_visible (assertion_mismatch) "Count": runs 1, 4"#))
        #expect(await amoo.calls.allSatisfy { !$0.contains("--runtime-id") })
    }

    @Test("Zero runs is refused")
    func zeroRuns() async {
        await #expect(throws: UitaError.self) {
            try await RepeatRunner(runner: StubAmoo()).run(
                flow: "flow.amoo.json", runs: 0, runtimes: [], outputDirectory: directory())
        }
    }

    @Test("Bundle endpoint keys come from moq-author's listing")
    func bundleEndpoints() async throws {
        let keys = try await BundleEndpoints(runner: StubAmoo()).keys(ofBundleAt: "example.moqproj")
        #expect(keys == ["GET /v1/tasks", "DELETE /v1/tasks/{id}"])
    }
}
