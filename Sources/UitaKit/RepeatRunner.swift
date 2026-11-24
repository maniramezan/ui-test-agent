import Foundation
import OSLog
import SwiftCommons

/// How many runs it takes to see a flake.
public enum RunCount {
    public static let minimum = 10

    /// Runs needed to see, with 95% confidence, at least one failure of a flow that fails
    /// `failureRate` of the time: n ≥ ln(0.05) / ln(1 − p), and never fewer than ten.
    public static func needed(failureRate: Double) -> Int {
        guard failureRate > 0, failureRate < 1 else {
            return minimum
        }
        return max(minimum, Int((log(0.05) / log(1 - failureRate)).rounded(.up)))
    }

    /// The failure rate that `runs` straight passes rule out with 95% confidence.
    public static func ruledOutFailureRate(afterPasses runs: Int) -> Double {
        runs > 0 ? 1 - pow(0.05, 1 / Double(runs)) : 1
    }
}

/// One run of the flow.
public struct RunOutcome: Codable, Sendable, Equatable {
    /// Where a failed run stopped.
    public struct Failure: Codable, Sendable, Equatable, Hashable {
        public var step: Int?
        public var name: String?
        public var tool: String?
        /// amoo's classification of the failure; the grouping key, never the message text.
        public var kind: String?

        public init(step: Int? = nil, name: String? = nil, tool: String? = nil, kind: String? = nil) {
            self.step = step
            self.name = name
            self.tool = tool
            self.kind = kind
        }
    }

    public var run: Int
    public var runtime: String?
    public var passed: Bool
    public var exitStatus: Int32
    public var elapsedMs: Int?
    public var failure: Failure?
    /// From the run's `moq-session.json`, when the flow used a mock session.
    public var requests: Int?
    public var unmatched: Int?
    public var rejected: Int?
    public var outputDirectory: String
}

/// Failed runs that stopped at the same step for the same reason.
public struct FailureGroup: Codable, Sendable, Equatable {
    public var failure: RunOutcome.Failure
    public var runs: [Int]
}

/// What `uita repeat` reports.
public struct RepeatSummary: Codable, Sendable, Equatable {
    public var flow: String
    public var runs: Int
    public var passed: Int
    public var wallSeconds: Double
    /// Per-run flow time in milliseconds, from amoo's reports.
    public var fastestMs: Int?
    public var medianMs: Int?
    public var slowestMs: Int?
    public var failures: [FailureGroup]
    /// Passing runs whose mock session saw requests no endpoint matched, or refused ones.
    public var runsWithUnmatched: [Int]
    public var runsWithRejected: [Int]
    public var outcomes: [RunOutcome]

    public var passRate: Double {
        runs == 0 ? 0 : Double(passed) / Double(runs)
    }

    init(flow: String, outcomes: [RunOutcome], wallSeconds: Double) {
        self.flow = flow
        self.outcomes = outcomes.sorted { $0.run < $1.run }
        runs = outcomes.count
        passed = outcomes.count { $0.passed }
        self.wallSeconds = wallSeconds
        let times = outcomes.compactMap(\.elapsedMs).sorted()
        fastestMs = times.first
        slowestMs = times.last
        medianMs = times.isEmpty ? nil : times[times.count / 2]
        var groups: [RunOutcome.Failure: [Int]] = [:]
        for outcome in self.outcomes where !outcome.passed {
            groups[outcome.failure ?? RunOutcome.Failure(), default: []].append(outcome.run)
        }
        failures = groups.map { FailureGroup(failure: $0.key, runs: $0.value) }
            .sorted { ($1.runs.count, $0.runs[0]) < ($0.runs.count, $1.runs[0]) }
        runsWithUnmatched = self.outcomes.filter { ($0.unmatched ?? 0) > 0 }.map(\.run)
        runsWithRejected = self.outcomes.filter { ($0.rejected ?? 0) > 0 }.map(\.run)
    }

    /// The summary as the lines `uita repeat` prints.
    public var text: String {
        var lines = ["\(passed) of \(runs) runs passed (\(Self.percent(passRate))) in \(Int(wallSeconds.rounded())) s"]
        if let fastestMs, let medianMs, let slowestMs {
            lines.append("Flow time: fastest \(fastestMs) ms, median \(medianMs) ms, slowest \(slowestMs) ms")
        }
        if failures.isEmpty, runs > 0 {
            lines.append(
                "No failures: a failure rate above \(Self.percent(RunCount.ruledOutFailureRate(afterPasses: runs))) is unlikely (95%)."
            )
        }
        for group in failures {
            let failure = group.failure
            let step = failure.step.map { "step \($0)" } ?? "before any step"
            let tool = failure.tool.map { " \($0)" } ?? ""
            let kind = failure.kind.map { " (\($0))" } ?? ""
            let name = failure.name.map { " \"\($0)\"" } ?? ""
            lines.append(
                "\(group.runs.count)× \(step)\(tool)\(kind)\(name): runs \(group.runs.map(String.init).joined(separator: ", "))"
            )
        }
        if !runsWithUnmatched.isEmpty {
            lines.append(
                "Unmatched requests reached the mock session in runs \(runsWithUnmatched.map(String.init).joined(separator: ", "))"
            )
        }
        if !runsWithRejected.isEmpty {
            lines.append(
                "The mock server refused requests in runs \(runsWithRejected.map(String.init).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        let scaled = (value * 1000).rounded() / 10
        return scaled == scaled.rounded() ? "\(Int(scaled))%" : "\(scaled)%"
    }
}

/// Runs one flow many times with `amoo flow`, spread over the given amoo runtimes, and groups
/// the failures by where and why they stopped.
public struct RepeatRunner: Sendable {
    private static let logger = Logger.forType(subsystem: "UITestAgent", RepeatRunner.self)

    private let runner: any CommandRunner
    private let amoo: String

    public init(runner: any CommandRunner = ProcessRunner(), amoo: String = "amoo") {
        self.runner = runner
        self.amoo = amoo
    }

    /// Hands out run numbers to the workers, one per runtime.
    private actor Queue {
        private var next = 1
        private let last: Int

        init(runs: Int) {
            last = runs
        }

        func take() -> Int? {
            guard next <= last else {
                return nil
            }
            defer { next += 1 }
            return next
        }
    }

    /// - Parameters:
    ///   - runtimes: amoo runtime ids to spread the runs over, one worker each. Empty runs them
    ///     one after another on whatever `AMOO_RUNTIME_ID` or `extraArguments` select.
    ///   - extraArguments: passed to every `amoo flow` call as they are.
    public func run(
        flow: String, runs: Int, runtimes: [String], outputDirectory: URL, extraArguments: [String] = []
    ) async throws -> RepeatSummary {
        guard runs > 0 else {
            throw UitaError.invalidOption(name: "runs", reason: "must be at least 1")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let queue = Queue(runs: runs)
        let workers: [String?] = runtimes.isEmpty ? [nil] : runtimes
        let started = Date()
        Self.logger.infoPublic("Repeating a flow runs=\(runs) workers=\(workers.count)")
        let outcomes = await withTaskGroup(of: [RunOutcome].self) { group in
            for runtime in workers {
                group.addTask {
                    var done: [RunOutcome] = []
                    while let number = await queue.take() {
                        done.append(
                            await self.once(
                                flow: flow, number: number, runtime: runtime, outputDirectory: outputDirectory,
                                extraArguments: extraArguments))
                    }
                    return done
                }
            }
            var all: [RunOutcome] = []
            for await done in group {
                all += done
            }
            return all
        }
        let summary = RepeatSummary(flow: flow, outcomes: outcomes, wallSeconds: Date().timeIntervalSince(started))
        Self.logger.infoPublic("Repeated a flow runs=\(summary.runs) passed=\(summary.passed)")
        return summary
    }

    private func once(
        flow: String, number: Int, runtime: String?, outputDirectory: URL, extraArguments: [String]
    ) async -> RunOutcome {
        let directory = outputDirectory.appending(path: String(format: "run-%03d", number))
        var arguments = ["flow", flow, "--output-dir", directory.path]
        if let runtime {
            arguments += ["--runtime-id", runtime]
        }
        arguments += extraArguments
        var status: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            status = try await runner.run(amoo, arguments, output: directory.appending(path: "amoo.log")).status
        } catch {
            Self.logger.error("A run could not start", error: error, context: "run=\(number)")
        }
        var outcome = RunOutcome(
            run: number, runtime: runtime, passed: status == 0, exitStatus: status,
            outputDirectory: directory.path)
        if let report = Self.read(Report.self, at: directory.appending(path: "report.json")) {
            outcome.elapsedMs = report.elapsedMs
            if status != 0, let failed = report.steps?.first(where: { $0.status == "failed" }) {
                outcome.failure = .init(
                    step: failed.number, name: failed.name, tool: failed.tool, kind: failed.result?.failureKind)
            }
        }
        if let session = Self.read(SessionRecord.self, at: directory.appending(path: "moq-session.json")) {
            outcome.requests = session.requests
            outcome.unmatched = session.unmatched
            outcome.rejected = session.rejected
        }
        Self.logger.infoPublic("Run \(number) finished passed=\(outcome.passed)")
        return outcome
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The parts of amoo's `report.json` the summary needs.
    private struct Report: Decodable {
        struct Step: Decodable {
            struct Result: Decodable {
                let failureKind: String?

                enum CodingKeys: String, CodingKey {
                    case failureKind = "failure_kind"
                }
            }

            let number: Int?
            let name: String?
            let tool: String?
            let status: String?
            let result: Result?
        }

        let elapsedMs: Int?
        let steps: [Step]?

        enum CodingKeys: String, CodingKey {
            case elapsedMs = "elapsed_ms"
            case steps
        }
    }

    /// The bridge's `moq-session.json`.
    private struct SessionRecord: Decodable {
        let requests: Int?
        let unmatched: Int?
        let rejected: Int?
    }
}
