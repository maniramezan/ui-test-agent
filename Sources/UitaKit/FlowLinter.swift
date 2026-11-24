import ExtensionKit
import Foundation
import OSLog
import SwiftCommons

/// One thing `uita lint` found in a flow.
public struct Finding: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        /// The run can pass while checking nothing, or disturb other runs.
        case error
        /// Likely to make the run flaky or harder to read.
        case warning
    }

    public var rule: String
    public var severity: Severity
    /// 1-based, as amoo numbers steps; nil for a finding about the whole flow.
    public var step: Int?
    public var message: String

    public init(rule: String, severity: Severity, step: Int? = nil, message: String) {
        self.rule = rule
        self.severity = severity
        self.step = step
        self.message = message
    }
}

/// Checks a flow, without a device, for mistakes that have made runs pass wrongly or flake.
public struct FlowLinter: Sendable {
    private static let logger = Logger.forType(subsystem: "UITestAgent", FlowLinter.self)

    /// Steps that state an outcome themselves, so a tap before one needs no expectation.
    static let observingTools: Set<String> = [
        "wait_for", "assert_visible", "assert_enabled", "assert_value", "assert_selected", "assert_checked",
        "assert_state_description", "assert_screen_changed",
    ]
    static let tapExpectations = ["expect_id", "expect_label", "expect_contains_text"]
    /// `moq.*` steps that read the session's request history.
    static let requestChecks: Set<String> = [
        "assert_request", "assert_no_rejected_requests", "assert_no_unmatched_requests",
        "assert_all_requests_carry_session",
    ]
    static let endpointSteps: Set<String> = ["select_variant", "reset_variant", "assert_request"]

    /// `METHOD /path` keys of the mock bundle, when one was given.
    private let endpoints: Set<String>?
    /// Where relative paths in the flow's variables resolve: amoo's working directory.
    private let workingDirectory: URL
    private let fileExists: @Sendable (String) -> Bool

    public init(
        endpoints: Set<String>? = nil,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.endpoints = endpoints.map { Set($0.map(Self.normalized)) }
        self.workingDirectory = workingDirectory
        self.fileExists = fileExists
    }

    public func lint(_ flow: Flow) -> [Finding] {
        var findings: [Finding] = []
        findings += appLifetime(flow)
        findings += sessionReached(flow)
        findings += extensionsStarted(flow)
        findings += configFiles(flow)
        findings += marks(flow)
        findings += endpointKeys(flow)
        findings += tapOutcomes(flow)
        Self.logger.infoPublic("Linted a flow steps=\(flow.steps.count) findings=\(findings.count)")
        return findings.sorted { ($0.step ?? 0, $0.rule) < ($1.step ?? 0, $1.rule) }
    }

    private func launches(_ flow: Flow) -> Bool {
        flow.steps.contains { $0.tool == "device_launch_app" }
    }

    /// An app left running keeps sending its released session id, and other runs' session checks
    /// on a shared server see it.
    private func appLifetime(_ flow: Flow) -> [Finding] {
        guard launches(flow), flow.terminateAppAtEnd != true else {
            return []
        }
        let mocked = flow.uses(extension: "moq")
        return [
            Finding(
                rule: "terminate-app-at-end", severity: mocked ? .error : .warning,
                message: mocked
                    ? "Set \"terminate_app_at_end\": true. The app outlives the run's session and keeps sending its id, which other runs' session checks on the same server then see."
                    : "Set \"terminate_app_at_end\": true so the next run starts from a fresh launch.")
        ]
    }

    /// A launch that never joined the session leaves an empty history, on which every request
    /// check passes.
    private func sessionReached(_ flow: Flow) -> [Finding] {
        guard flow.uses(extension: "moq"), launches(flow) else {
            return []
        }
        let moqSteps = flow.steps.enumerated().filter { $0.element.extensionPrefix == "moq" }
        guard let reached = moqSteps.first(where: { $0.element.localTool == "assert_session_reached" }) else {
            return [
                Finding(
                    rule: "session-reached", severity: .error,
                    message: "Add moq.assert_session_reached after the app's first request. Without it, a launch that never joined the session leaves an empty history, and every other request check passes on it.")
            ]
        }
        guard
            let early = moqSteps.first(where: { Self.requestChecks.contains($0.element.localTool) }),
            early.offset < reached.offset
        else {
            return []
        }
        return [
            Finding(
                rule: "session-reached", severity: .warning, step: early.offset + 1,
                message: "moq.\(early.element.localTool) runs before moq.assert_session_reached (step \(reached.offset + 1)). Check the session was reached first, so this step can't pass on an empty history.")
        ]
    }

    /// Variables alone don't start an extension: it needs a step of its own or a declaration.
    private func extensionsStarted(_ flow: Flow) -> [Finding] {
        let vars = flow.vars ?? [:]
        var findings: [Finding] = []
        if vars["moq_config"] != nil || vars["moq_port"] != nil, !flow.uses(extension: "moq"), !flow.uses(extension: "auth") {
            findings.append(
                Finding(
                    rule: "extension-not-started", severity: .error,
                    message: "The flow sets moq_config or moq_port but has no moq.* step and doesn't declare \"extensions\": [\"moq\"], so no session is opened and the app launches without one."))
        }
        if vars["auth_config"] != nil, !flow.uses(extension: "auth") {
            findings.append(
                Finding(
                    rule: "extension-not-started", severity: .error,
                    message: "The flow sets auth_config but has no auth.* step and doesn't declare \"extensions\": [\"auth\"], so the auth extension never starts."))
        }
        return findings
    }

    private func configFiles(_ flow: Flow) -> [Finding] {
        var findings: [Finding] = []
        for name in ["moq_config", "auth_config"] {
            guard let raw = flow.vars?[name], let path = flow.resolved(raw) else {
                continue
            }
            let full = path.hasPrefix("/") ? path : workingDirectory.appending(path: path).standardizedFileURL.path
            if !fileExists(full) {
                findings.append(
                    Finding(
                        rule: "config-missing", severity: .error,
                        message: "\(name) is \(path), which doesn't exist under \(workingDirectory.path). Relative paths resolve against the directory amoo runs in."))
            }
        }
        return findings
    }

    /// A `since` that names no earlier mark fails at run time, after the device work is done.
    private func marks(_ flow: Flow) -> [Finding] {
        var defined: Set<String> = []
        var findings: [Finding] = []
        for (index, step) in flow.steps.enumerated() where step.extensionPrefix == "moq" {
            if step.localTool == "mark", let name = flow.string("name", of: step) {
                defined.insert(name)
            }
            guard let since = flow.string("since", of: step), Double(since) == nil, !defined.contains(since) else {
                continue
            }
            findings.append(
                Finding(
                    rule: "undefined-mark", severity: .error, step: index + 1,
                    message: "since is \"\(since)\", but no earlier moq.mark step has that name."))
        }
        return findings
    }

    /// An unknown endpoint key matches nothing: a `times: 0` check passes on a typo.
    private func endpointKeys(_ flow: Flow) -> [Finding] {
        guard let endpoints else {
            return []
        }
        var findings: [Finding] = []
        for (index, step) in flow.steps.enumerated()
        where step.extensionPrefix == "moq" && Self.endpointSteps.contains(step.localTool) {
            guard let endpoint = flow.string("endpoint", of: step), !endpoints.contains(Self.normalized(endpoint))
            else {
                continue
            }
            let closest = Self.closest(to: Self.normalized(endpoint), in: endpoints)
            findings.append(
                Finding(
                    rule: "unknown-endpoint", severity: .error, step: index + 1,
                    message: "\"\(endpoint)\" is not an endpoint of the bundle."
                        + (closest.map { " Closest: \"\($0)\"." } ?? "")))
        }
        return findings
    }

    /// amoo knows where it tapped, not what was meant: a tap states its outcome, or the next
    /// step observes it.
    private func tapOutcomes(_ flow: Flow) -> [Finding] {
        var findings: [Finding] = []
        for (index, step) in flow.steps.enumerated() where step.tool == "tap_element" {
            let arguments = step.arguments ?? [:]
            guard !Self.tapExpectations.contains(where: { arguments[$0] != nil }) else {
                continue
            }
            let next = index + 1 < flow.steps.count ? flow.steps[index + 1] : nil
            if let next, Self.observingTools.contains(next.tool) {
                continue
            }
            findings.append(
                Finding(
                    rule: "tap-outcome", severity: .warning, step: index + 1,
                    message: "This tap states no outcome (expect_id, expect_label or expect_contains_text; expect_absent=true for something that should close) and the next step doesn't observe one, so a dropped tap goes unnoticed until a later step fails."))
        }
        return findings
    }

    /// `METHOD /path`, upper-cased method, no trailing slash.
    static func normalized(_ key: String) -> String {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return key
        }
        var path = parts[1].trimmingCharacters(in: .whitespaces)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(parts[0].uppercased()) \(path)"
    }

    /// The key of the same method fewest edits away from `key`.
    static func closest(to key: String, in keys: Set<String>) -> String? {
        let method = key.split(separator: " ").first.map(String.init) ?? ""
        return keys.filter { $0.hasPrefix(method + " ") }
            .min { (distance($0, key), $0) < (distance($1, key), $1) }
    }

    /// Levenshtein distance.
    static func distance(_ first: String, _ second: String) -> Int {
        let a = Array(first)
        let b = Array(second)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j] + (left == right ? 0 : 1), previous[j + 1] + 1, current[j] + 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
