import ArgumentParser
import Foundation
import MoqBridge

@main
struct AmooExtMoq: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amoo-ext-moq",
        abstract: "Bridge between amoo flows and a moqserver mock server.",
        discussion: """
            amoo runs describe, flow_start, step and flow_end for moq.* flow steps, and emit when it \
            generates a test from a flow, with one JSON \
            request on stdin and one JSON reply on stdout (amoo's flow-extension protocol 1). \
            session and config are for use outside amoo: open a session before launching the \
            app, merge the printed launchEnvironment into the launch, and release it afterwards.
            """,
        subcommands: [
            Verb.Describe.self, Verb.FlowStart.self, Verb.Step.self, Verb.FlowEnd.self, Verb.Emit.self,
            Session.self, Config.self,
        ]
    )
}

/// amoo's flow-extension verbs. Each reads one request from stdin and prints one reply.
enum Verb {
    static func answer() async throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder().decode(ExtensionRequest.self, from: input)
        let reply = try await ExtensionHandler().handle(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    }

    struct Emit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "emit",
            abstract: "amoo: write the MoqClient test code for the session or one moq.* step.")

        func run() throws {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode(EmitRequest.self, from: input)
            let reply = try TestEmitter().handle(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(reply), as: UTF8.self))
        }
    }

    struct Describe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "describe", abstract: "amoo: list the moq.* steps.")

        func run() async throws {
            try await Verb.answer()
        }
    }

    struct FlowStart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "flow_start", abstract: "amoo: open this run's moqserver session.")

        func run() async throws {
            try await Verb.answer()
        }
    }

    struct Step: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "step", abstract: "amoo: run one moq.* step.")

        func run() async throws {
            try await Verb.answer()
        }
    }

    struct FlowEnd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "flow_end", abstract: "amoo: release this run's moqserver session.")

        func run() async throws {
            try await Verb.answer()
        }
    }
}

struct ConfigOptions: ParsableArguments {
    @Option(name: .long, help: "Per-app config file, kept in the app's repo.")
    var config: String

    @Option(name: .long, help: "moqserver port, overriding server.port (e.g. the runner's MOQ_PORT).")
    var port: Int?

    func load() throws -> AppConfig {
        try AppConfig.load(from: URL(filePath: config))
    }
}

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open or release an isolated moqserver session.",
        subcommands: [Start.self, End.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wait for moqserver, open a session and print its launch keys as JSON."
        )

        @OptionGroup var options: ConfigOptions

        @Option(name: .long, help: "ios or android.")
        var platform: Platform

        func run() async throws {
            let lifecycle = SessionLifecycle(config: try options.load(), portOverride: options.port)
            let started = try await lifecycle.start(platform: platform)
            try printJSON(started)
        }
    }

    struct End: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Release a session. Succeeds if it is already gone."
        )

        @OptionGroup var options: ConfigOptions

        @Option(name: .customLong("session"), help: "The sessionId printed by session start.")
        var sessionId: String

        func run() async throws {
            let lifecycle = SessionLifecycle(config: try options.load(), portOverride: options.port)
            try await lifecycle.end(sessionId: sessionId)
            try printJSON(["released": sessionId])
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Per-app config commands.",
        subcommands: [Check.self]
    )

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate a per-app config without contacting moqserver."
        )

        @Option(name: .long, help: "Per-app config file.")
        var config: String

        func run() throws {
            let loaded = try AppConfig.load(from: URL(filePath: config))
            print("\(loaded.app): OK (\(loaded.platforms.keys.sorted().joined(separator: ", ")))")
        }
    }
}

extension Platform: ExpressibleByArgument {}

private func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}
