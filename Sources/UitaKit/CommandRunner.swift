import Foundation
import OSLog
import SwiftCommons

/// What a finished command left behind.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var output: Data

    public init(status: Int32, output: Data) {
        self.status = status
        self.output = output
    }
}

/// Runs one command to its end. Swapped for a stub in tests.
public protocol CommandRunner: Sendable {
    /// - Parameter output: where stdout and stderr go; nil collects stdout into the result.
    func run(_ executable: String, _ arguments: [String], output: URL?) async throws -> CommandResult
}

/// Runs commands found on `PATH`.
public struct ProcessRunner: CommandRunner {
    private static let logger = Logger.forType(subsystem: "UITestAgent", ProcessRunner.self)

    public init() {}

    public func run(_ executable: String, _ arguments: [String], output: URL?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let pipe = Pipe()
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        }
        Self.logger.debugPublic("Starting \(executable) arguments=\(arguments.count)")
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = output == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
                Self.logger.debugPublic("\(executable) exited status=\(finished.terminationStatus)")
                continuation.resume(returning: CommandResult(status: finished.terminationStatus, output: data))
            }
            do {
                try process.run()
            } catch {
                Self.logger.error("Could not start a command", error: error, context: "executable=\(executable)")
                process.terminationHandler = nil
                continuation.resume(throwing: UitaError.toolFailed(tool: executable, reason: error.localizedDescription))
            }
        }
    }
}

/// Reads a mock bundle's endpoint keys through `moq-author`, the bundle's own tool.
public struct BundleEndpoints: Sendable {
    private let runner: any CommandRunner
    private let moqAuthor: String

    public init(runner: any CommandRunner = ProcessRunner(), moqAuthor: String = "moq-author") {
        self.runner = runner
        self.moqAuthor = moqAuthor
    }

    private struct Listing: Decodable {
        struct Endpoint: Decodable {
            let method: String
            let path: String
        }

        let endpoints: [Endpoint]
    }

    /// `METHOD /path` for every endpoint of the bundle at `path`.
    public func keys(ofBundleAt path: String) async throws -> Set<String> {
        let result = try await runner.run(moqAuthor, ["endpoint", "list", "--project", path], output: nil)
        guard result.status == 0 else {
            throw UitaError.toolFailed(
                tool: moqAuthor, reason: "endpoint list exited \(result.status) for \(path)")
        }
        do {
            let listing = try JSONDecoder().decode(Listing.self, from: result.output)
            return Set(listing.endpoints.map { "\($0.method.uppercased()) \($0.path)" })
        } catch {
            throw UitaError.toolFailed(tool: moqAuthor, reason: "endpoint list printed something unexpected")
        }
    }
}
