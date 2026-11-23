import Foundation

/// A step's arguments, read strictly: every argument must be consumed, so a typo fails the step
/// instead of being ignored. Numbers and booleans may also arrive as strings, since amoo
/// substitutes `${name}` into strings.
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

    mutating func optionalInt(_ name: String, minimum: Int) throws -> Int? {
        read.insert(name)
        let number: Double
        switch values[name] {
        case nil, .null:
            return nil
        case .number(let value):
            number = value
        case .string(let text):
            guard let value = Double(text) else {
                throw BridgeError.invalidArgument(name: name, reason: "must be a whole number")
            }
            number = value
        default:
            throw BridgeError.invalidArgument(name: name, reason: "must be a whole number")
        }
        guard number.rounded() == number, number >= Double(minimum), number <= Double(Int32.max) else {
            throw BridgeError.invalidArgument(
                name: name, reason: "must be a whole number of at least \(minimum)")
        }
        return Int(number)
    }

    mutating func optionalBool(_ name: String) throws -> Bool? {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return nil
        case .bool(let value):
            return value
        case .string("true"):
            return true
        case .string("false"):
            return false
        default:
            throw BridgeError.invalidArgument(name: name, reason: "must be true or false")
        }
    }

    /// An object of string values, e.g. `claims: {"sub": "user-1"}`.
    mutating func stringMap(_ name: String) throws -> [String: String] {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return [:]
        case .object(let object):
            return try object.mapValues { value in
                guard case .string(let text) = value else {
                    throw BridgeError.invalidArgument(name: name, reason: "values must be strings")
                }
                return text
            }
        default:
            throw BridgeError.invalidArgument(name: name, reason: "must be an object of strings")
        }
    }

    mutating func array(_ name: String) throws -> [JSONValue] {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return []
        case .array(let items):
            return items
        default:
            throw BridgeError.invalidArgument(name: name, reason: "must be an array")
        }
    }

    /// `since`: the name of an earlier `moq.mark`, or Unix seconds on the server's clock.
    mutating func since(marks: [String: Double]) throws -> Double? {
        read.insert("since")
        switch values["since"] {
        case nil, .null:
            return nil
        case .number(let value):
            return value
        case .string(let text):
            if let mark = marks[text] {
                return mark
            }
            if let seconds = Double(text) {
                return seconds
            }
            let known = marks.keys.sorted()
            throw BridgeError.invalidArgument(
                name: "since",
                reason: "no moq.mark named '\(text)' in this run"
                    + (known.isEmpty ? "" : " (marks: \(known.joined(separator: ", ")))")
            )
        default:
            throw BridgeError.invalidArgument(name: "since", reason: "must be a mark name or a number")
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

/// Runs one `moq.*` step against the run's session. Request checks send moqserver's query
/// (`POST /_admin/requests/query`) with the same body the MoqClient call of the same name sends,
/// so a flow step and a generated test get the same verdict.
struct StepRunner {
    let client: AdminClient
    let session: String
    private(set) var marks: [String: Double]

    static let pollInterval: Duration = .milliseconds(100)

    init(client: AdminClient, session: String, marks: [String: Double] = [:]) {
        self.client = client
        self.session = session
        self.marks = marks
    }

    mutating func run(tool: String, arguments: StepArguments) async throws -> ExtensionReply {
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
            let times = try arguments.optionalInt("times", minimum: 1)
            try arguments.finish()
            try await client.selectVariant(variant, for: endpoint, times: times, session: session)
            var result: [String: JSONValue] = [
                "endpoint": .string(endpoint.key), "variant": .string(variant),
            ]
            if let times {
                result["times"] = .number(Double(times))
            }
            let scope = times.map { " for the next \($0) request(s)" } ?? ""
            return ExtensionReply(
                ok: true, message: "\(endpoint.key) → \(variant)\(scope)", result: .object(result))

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

        case "mark":
            let name = try arguments.string("name")
            try arguments.finish()
            let timestamp = try await client.mark(session: session)
            marks[name] = timestamp
            return ExtensionReply(
                ok: true,
                message: "Marked \(name)",
                result: .object(["name": .string(name), "timestamp": .number(timestamp)])
            )

        case "assert_request":
            let endpoint = try arguments.string("endpoint")
            let times = try arguments.optionalInt("times", minimum: 0)
            let headers = try Self.headerPredicates(arguments.array("headers"))
            let claims = try arguments.stringMap("claims")
            let since = try arguments.since(marks: marks)
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0) ?? 0
            try arguments.finish()
            var query: [String: JSONValue] = ["endpoint": .string(endpoint)]
            query["since"] = since.map(JSONValue.number)
            query["headers"] = headers.isEmpty ? nil : .array(headers)
            query["claims"] = claims.isEmpty ? nil : .object(claims.mapValues(JSONValue.string))
            query["times"] = times.map { .number(Double($0)) }
            return try await verdict(of: .object(query), timeout: .milliseconds(timeout))

        case "assert_no_rejected_requests":
            let since = try arguments.since(marks: marks)
            try arguments.finish()
            var query: [String: JSONValue] = ["rejected": .bool(true), "times": .number(0)]
            query["since"] = since.map(JSONValue.number)
            return try await verdict(of: .object(query), timeout: .zero)

        case "assert_all_requests_carry_session":
            let claims = try arguments.stringMap("claims")
            let includeUnattributed = try arguments.optionalBool("include_unattributed") ?? false
            let since = try arguments.since(marks: marks)
            try arguments.finish()
            var query: [String: JSONValue] = ["times": .number(0), "scope": .string("sessionless")]
            query["since"] = since.map(JSONValue.number)
            query["claims"] = claims.isEmpty ? nil : .object(claims.mapValues(JSONValue.string))
            query["includeUnattributed"] = includeUnattributed ? .bool(true) : nil
            return try await verdict(of: .object(query), timeout: .zero)

        case "assert_session_reached":
            let timeout = try arguments.optionalInt("timeout_ms", minimum: 0) ?? 0
            try arguments.finish()
            var reply = try await verdict(of: .object([:]), timeout: .milliseconds(timeout))
            if reply.ok == true {
                reply.message = "The app reached session \(session)"
            } else {
                reply.message =
                    "No request reached session \(session) within \(timeout) ms. The app may have launched without the session key and be calling its real backend."
            }
            return reply

        case "assert_no_unmatched_requests":
            try arguments.finish()
            return try await verdict(of: .object(["unmatched": .bool(true), "times": .number(0)]), timeout: .zero)

        default:
            throw BridgeError.invalidArgument(name: "tool", reason: "moq.\(tool) is not a step of this build")
        }
    }

    /// Polls the query until it passes or `timeout` runs out, like MoqClient's `timeout`.
    private func verdict(of query: JSONValue, timeout: Duration) async throws -> ExtensionReply {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let verdict = try await client.query(query, session: session)
            let remaining = deadline - clock.now
            if verdict.ok || remaining <= .zero {
                return ExtensionReply(
                    ok: verdict.ok,
                    message: verdict.message ?? (verdict.ok ? "Request check passed" : "Request check failed"),
                    result: verdict.body
                )
            }
            try await Task.sleep(for: min(Self.pollInterval, remaining))
        }
    }

    /// Flow header expectations, one predicate per item like MoqClient's `MoqHeaderExpectation`:
    /// `{name, present: true|false}`, `{name, scheme}`, `{name, fingerprint_of}` or `{name, equals}`.
    static func headerPredicates(_ items: [JSONValue]) throws -> [JSONValue] {
        try items.enumerated().map { index, item in
            let label = "headers[\(index)]"
            guard case .object(let fields) = item, case .string(let name) = fields["name"], !name.isEmpty
            else {
                throw BridgeError.invalidArgument(name: label, reason: "needs a non-empty name")
            }
            let predicates = fields.filter { $0.key != "name" }
            guard predicates.count == 1, let (key, value) = predicates.first else {
                throw BridgeError.invalidArgument(
                    name: label,
                    reason: "needs exactly one of present, scheme, fingerprint_of, equals")
            }
            switch (key, value) {
            case ("present", .bool(let present)):
                return .object(["name": .string(name), "present": .bool(present)])
            case ("scheme", .string(let scheme)):
                return .object(["name": .string(name), "scheme": .string(scheme)])
            case ("fingerprint_of", .string(let credential)):
                return .object(["name": .string(name), "fingerprintOf": .string(credential)])
            case ("equals", .string(let expected)):
                return .object(["name": .string(name), "equals": .string(expected)])
            default:
                throw BridgeError.invalidArgument(
                    name: "\(label).\(key)",
                    reason: "present takes true or false; scheme, fingerprint_of and equals take a string")
            }
        }
    }
}
