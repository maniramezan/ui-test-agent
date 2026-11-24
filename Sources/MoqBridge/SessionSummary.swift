import Foundation
import OSLog
import SwiftCommons

/// What the run's moqserver session saw, read just before `flow_end` releases it and written to
/// `moq-session.json` in the run's output directory. amoo doesn't surface a `flow_end` reply, so
/// this file is how a person or a triage tool learns that no request reached the session, or that
/// some went unmatched or were rejected. The bridge records the counts and judges nothing.
public struct SessionSummary: Codable, Sendable, Equatable {
    public static let fileName = "moq-session.json"
    public static let schemaVersion = 1

    public var schema = SessionSummary.schemaVersion
    public var session: String
    /// Requests that reached this session; `nil` when the query failed.
    public var requests: Int?
    public var unmatched: Int?
    public var rejected: Int?
    /// As amoo reported it. `false` covers both "launched no app" and "left an app running".
    public var appTerminated: Bool?

    enum CodingKeys: String, CodingKey {
        case schema, session, requests, unmatched, rejected
        case appTerminated = "app_terminated"
    }

    /// The three queries, with the same bodies the matching steps send, so a count here and a
    /// step's verdict come from the same server-side predicate.
    static var queries: [(key: WritableKeyPath<SessionSummary, Int?>, body: JSONValue)] {
        [
            (\.requests, .object([:])),
            (\.unmatched, .object(["unmatched": .bool(true), "times": .number(0)])),
            (\.rejected, .object(["rejected": .bool(true), "times": .number(0)])),
        ]
    }

    private static let logger = Logger.forType(subsystem: "UITestAgent", SessionSummary.self)

    /// Reads the counts. A failed query leaves its count `nil` instead of failing the release.
    static func read(
        client: AdminClient, session: String, appTerminated: Bool?
    ) async -> SessionSummary {
        var summary = SessionSummary(session: session, appTerminated: appTerminated)
        for query in queries {
            do {
                let verdict = try await client.query(query.body, session: session)
                if case .object(let fields) = verdict.body, case .number(let count) = fields["count"] {
                    summary[keyPath: query.key] = Int(count)
                }
            } catch {
                logger.error(
                    "Session summary query failed", error: error, context: "session=\(session)")
            }
        }
        return summary
    }

    /// Writes the file into `directory`. A write failure is logged, never thrown: the session
    /// must still be released.
    func write(to directory: URL) {
        let url = directory.appending(path: Self.fileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            Self.logger.infoPublic("Wrote \(Self.fileName) for session \(session)")
        } catch {
            Self.logger.error(
                "Could not write session summary", error: error, context: "session=\(session)")
        }
    }
}
