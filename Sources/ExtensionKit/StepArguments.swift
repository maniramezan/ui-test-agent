import Foundation

/// A step argument that is missing, malformed or unknown.
public struct ArgumentError: Error, Equatable, LocalizedError {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    public var errorDescription: String? {
        "Argument \(name): \(reason)"
    }
}

/// A step's arguments, read strictly: every argument must be consumed, so a typo fails the step
/// instead of being ignored. Numbers and booleans may also arrive as strings, since amoo
/// substitutes `${name}` into strings.
public struct StepArguments {
    private let values: [String: JSONValue]
    private var read: Set<String> = []

    public init(_ values: [String: JSONValue]) {
        self.values = values
    }

    public mutating func string(_ name: String) throws -> String {
        guard let value = try optionalString(name) else {
            throw ArgumentError(name: name, reason: "required")
        }
        return value
    }

    public mutating func optionalString(_ name: String) throws -> String? {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return nil
        case .string(let value) where !value.isEmpty:
            return value
        default:
            throw ArgumentError(name: name, reason: "must be a non-empty string")
        }
    }

    public mutating func optionalInt(_ name: String, minimum: Int) throws -> Int? {
        read.insert(name)
        let number: Double
        switch values[name] {
        case nil, .null:
            return nil
        case .number(let value):
            number = value
        case .string(let text):
            guard let value = Double(text) else {
                throw ArgumentError(name: name, reason: "must be a whole number")
            }
            number = value
        default:
            throw ArgumentError(name: name, reason: "must be a whole number")
        }
        guard number.rounded() == number, number >= Double(minimum), number <= Double(Int32.max) else {
            throw ArgumentError(
                name: name, reason: "must be a whole number of at least \(minimum)")
        }
        return Int(number)
    }

    public mutating func optionalBool(_ name: String) throws -> Bool? {
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
            throw ArgumentError(name: name, reason: "must be true or false")
        }
    }

    /// An object of string values, e.g. `claims: {"sub": "user-1"}`.
    public mutating func stringMap(_ name: String) throws -> [String: String] {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return [:]
        case .object(let object):
            return try object.mapValues { value in
                guard case .string(let text) = value else {
                    throw ArgumentError(name: name, reason: "values must be strings")
                }
                return text
            }
        default:
            throw ArgumentError(name: name, reason: "must be an object of strings")
        }
    }

    public mutating func array(_ name: String) throws -> [JSONValue] {
        read.insert(name)
        switch values[name] {
        case nil, .null:
            return []
        case .array(let items):
            return items
        default:
            throw ArgumentError(name: name, reason: "must be an array")
        }
    }

    /// The raw value, marked as read, for a reader the typed accessors don't cover.
    public mutating func value(_ name: String) -> JSONValue? {
        read.insert(name)
        return values[name]
    }

    /// Fails on any argument no accessor read.
    public func finish() throws {
        let unknown = Set(values.keys).subtracting(read).sorted()
        guard unknown.isEmpty else {
            throw ArgumentError(
                name: unknown.joined(separator: ", "), reason: "not an argument of this step")
        }
    }
}
