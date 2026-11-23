import Foundation

/// A step's arguments, read strictly: every argument must be consumed, so a typo fails the step
/// instead of being ignored.
struct StepArguments {
    private let values: [String: JSONValue]
    private var read: Set<String> = []

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    mutating func string(_ name: String) throws -> String {
        guard let value = try optionalString(name) else {
            throw BridgeError.invalidArgument(name: name, reason: "required")
        }
        return value
    }

    mutating func optionalString(_ name: String) throws -> String? {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return nil
        case .string(let value) where !value.isEmpty:
            return value
        default:
            throw BridgeError.invalidArgument(name: name, reason: "must be a non-empty string")
        }
    }

    func finish() throws {
        let unknown = Set(values.keys).subtracting(read).sorted()
        guard unknown.isEmpty else {
            throw BridgeError.invalidArgument(
                name: unknown.joined(separator: ", "), reason: "not an argument of this step")
        }
    }
}

/// Runs one `moq.*` step against the run's session.
struct StepRunner {
    let client: AdminClient
    let session: String

    func run(tool: String, arguments: StepArguments) async throws -> ExtensionReply {
        var arguments = arguments
        switch tool {
        case "activate_scenario":
            let name = try arguments.string("name")
            try arguments.finish()
            try await client.activateScenario(name, session: session)
            return ExtensionReply(
                ok: true, message: "Activated scenario \(name)", result: .object(["scenario": .string(name)]))

        case "select_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            let variant = try arguments.string("variant")
            try arguments.finish()
            try await client.selectVariant(variant, for: endpoint, session: session)
            return ExtensionReply(
                ok: true,
                message: "\(endpoint.key) → \(variant)",
                result: .object(["endpoint": .string(endpoint.key), "variant": .string(variant)])
            )

        case "reset_variant":
            let endpoint = try EndpointRef(
                arguments.string("endpoint"), operation: arguments.optionalString("operation"))
            try arguments.finish()
            try await client.resetVariant(for: endpoint, session: session)
            return ExtensionReply(
                ok: true,
                message: "\(endpoint.key) back to normal selection",
                result: .object(["endpoint": .string(endpoint.key)])
            )

        case "assert_no_unmatched_requests":
            try arguments.finish()
            let records = try await client.requests(session: session)
            let unmatched = records.filter { $0.endpoint == nil }
            return Self.assertion(
                passed: "No unmatched requests (\(records.count) checked)",
                failed: "\(unmatched.count) request(s) matched no mocked endpoint",
                offenders: unmatched,
                checked: records.count,
                key: "unmatched"
            )

        case "assert_no_rejected_requests":
            try arguments.finish()
            let records = try await client.requests(session: session)
            let rejected = records.filter { $0.rejection != nil }
            return Self.assertion(
                passed: "No rejected requests (\(records.count) checked)",
                failed: "\(rejected.count) request(s) rejected by moqserver",
                offenders: rejected,
                checked: records.count,
                key: "rejected"
            )

        default:
            throw BridgeError.invalidArgument(name: "tool", reason: "moq.\(tool) is not a step of this build")
        }
    }

    private static func assertion(
        passed: String,
        failed: String,
        offenders: [RequestRecord],
        checked: Int,
        key: String
    ) -> ExtensionReply {
        let rows: [JSONValue] = offenders.map { record in
            var row: [String: JSONValue] = [
                "method": .string(record.method),
                "path": .string(record.path),
            ]
            if let endpoint = record.endpoint {
                row["endpoint"] = .string(endpoint)
            }
            if let status = record.status {
                row["status"] = .number(Double(status))
            }
            if let rejection = record.rejection {
                row["rejection"] = .object([
                    "kind": .string(rejection.kind),
                    "code": .string(rejection.code),
                    "message": .string(rejection.message),
                ])
            }
            return .object(row)
        }
        let result = JSONValue.object(["checked": .number(Double(checked)), key: .array(rows)])
        guard !offenders.isEmpty else {
            return ExtensionReply(ok: true, message: passed, result: result)
        }
        let summary = offenders.prefix(5).map { record in
            "\(record.method) \(record.path)" + (record.rejection.map { " (\($0.message))" } ?? "")
        }
        let more = offenders.count > 5 ? ", …" : ""
        return ExtensionReply(
            ok: false,
            message: "\(failed): \(summary.joined(separator: ", "))\(more)",
            result: result
        )
    }
}
