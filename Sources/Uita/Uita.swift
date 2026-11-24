import ArgumentParser
import Foundation
import UitaKit

@main
struct Uita: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uita",
        abstract: "Checks and repeats amoo flows, with or without a mock server.",
        subcommands: [Lint.self, Repeat.self]
    )

    struct Lint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lint",
            abstract: "Check flows, without a device, for mistakes that make runs pass wrongly or flake.",
            discussion: """
                Run it from the directory amoo runs in, so relative config paths resolve the same way. \
                Exits 1 when any flow has an error; warnings alone exit 0.
                """
        )

        @Argument(help: "Flow files (*.amoo.json).")
        var flows: [String]

        @Option(name: .long, help: "A .moqproj bundle: check every endpoint key the flows name against it.")
        var bundle: String?

        @Option(name: .long, help: "The moq-author command that reads the bundle.")
        var moqAuthor = "moq-author"

        @Flag(name: .long, help: "Print the findings as JSON.")
        var json = false

        func run() async throws {
            var endpoints: Set<String>?
            if let bundle {
                endpoints = try await BundleEndpoints(moqAuthor: moqAuthor).keys(ofBundleAt: bundle)
            }
            let linter = FlowLinter(endpoints: endpoints)
            var byFlow: [String: [Finding]] = [:]
            for path in flows {
                byFlow[path] = linter.lint(try Flow.load(from: URL(filePath: path)))
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(byFlow), as: UTF8.self))
            } else {
                for path in flows {
                    let findings = byFlow[path] ?? []
                    print(findings.isEmpty ? "\(path): ok" : "\(path):")
                    for finding in findings {
                        let place = finding.step.map { "step \($0)" } ?? "flow"
                        print("  \(finding.severity.rawValue) [\(finding.rule)] \(place): \(finding.message)")
                    }
                }
            }
            if byFlow.values.contains(where: { $0.contains { $0.severity == .error } }) {
                throw ExitCode.failure
            }
        }
    }

    struct Repeat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repeat",
            abstract: "Run a flow many times and group the failures by step, tool and failure kind.",
            discussion: """
                Give --runs, or --failure-rate to have the count worked out: the runs needed to see, \
                with 95% confidence, a flow that fails that often (0.2 → 14, 0.1 → 29), never fewer \
                than 10. With several --runtime-id values the runs are spread over those amoo \
                runtimes in parallel. Arguments after -- go to every `amoo flow` call. Exits 1 \
                unless every run passed.
                """
        )

        @Argument(help: "The flow file (*.amoo.json).")
        var flow: String

        @Option(name: .long, help: "How many times to run the flow.")
        var runs: Int?

        @Option(name: .long, help: "The failure rate to be able to see, between 0 and 1.")
        var failureRate: Double?

        @Option(name: .long, help: "An amoo runtime to run on (amoo env up). Repeat it to run in parallel.")
        var runtimeId: [String] = []

        @Option(name: .long, help: "Where each run's report goes, as run-001, run-002, …")
        var outputDir: String

        @Option(name: .long, help: "The amoo command.")
        var amoo = "amoo"

        @Flag(name: .long, help: "Print the summary as JSON.")
        var json = false

        @Argument(parsing: .postTerminator, help: "Arguments for every amoo flow call, after --.")
        var amooArguments: [String] = []

        func run() async throws {
            if let failureRate, !(failureRate > 0 && failureRate < 1) {
                throw ValidationError("--failure-rate must be between 0 and 1")
            }
            let count = runs ?? failureRate.map(RunCount.needed(failureRate:)) ?? RunCount.minimum
            let summary = try await RepeatRunner(amoo: amoo).run(
                flow: flow, runs: count, runtimes: runtimeId, outputDirectory: URL(filePath: outputDir),
                extraArguments: amooArguments)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            } else {
                print(summary.text)
            }
            if summary.passed != summary.runs {
                throw ExitCode.failure
            }
        }
    }
}
