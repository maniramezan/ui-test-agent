import Foundation

/// Any JSON value, for step arguments and results.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// What the bridge keeps between calls in one amoo run. amoo stores it and sends it back unread.
public struct BridgeState: Codable, Sendable, Equatable {
    public var configPath: String
    public var port: Int
    public var platform: Platform
    public var sessionId: String
    /// `moq.mark` names → server timestamps, for later steps' `since`.
    public var marks: [String: Double]?

    public init(
        configPath: String, port: Int, platform: Platform, sessionId: String,
        marks: [String: Double]? = nil
    ) {
        self.configPath = configPath
        self.port = port
        self.platform = platform
        self.sessionId = sessionId
        self.marks = marks
    }
}

/// One request from amoo's flow-extension protocol, version 1 (mobile-testing docs/flow-extensions.md).
public struct ExtensionRequest: Decodable, Sendable {
    public struct Run: Decodable, Sendable {
        public var id: String?
        public var flow: String?
        public var outputDir: String?
        public var platform: String?
        public var deviceId: String?

        enum CodingKeys: String, CodingKey {
            case id
            case flow
            case outputDir = "output_dir"
            case platform
            case deviceId = "device_id"
        }
    }

    public struct Step: Decodable, Sendable {
        public var tool: String
        public var name: String?
        public var number: Int?
        public var arguments: [String: JSONValue]?
    }

    public var `protocol`: Int
    public var verb: String
    public var run: Run?
    public var state: BridgeState?
    public var vars: [String: String]?
    public var step: Step?
    public var passed: Bool?
}

public struct ExtensionReply: Encodable, Sendable, Equatable {
    public static let protocolVersion = 1

    public var `protocol` = ExtensionReply.protocolVersion
    public var ok: Bool?
    public var message: String?
    public var result: JSONValue?
    public var state: BridgeState?
    public var launchEnvironment: [String: String]?
    public var vars: [String: String]?
    public var steps: [String]?

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case ok
        case message
        case result
        case state
        case launchEnvironment = "launch_environment"
        case vars
        case steps
    }

    public init(
        ok: Bool? = nil,
        message: String? = nil,
        result: JSONValue? = nil,
        state: BridgeState? = nil,
        launchEnvironment: [String: String]? = nil,
        vars: [String: String]? = nil,
        steps: [String]? = nil
    ) {
        self.ok = ok
        self.message = message
        self.result = result
        self.state = state
        self.launchEnvironment = launchEnvironment
        self.vars = vars
        self.steps = steps
    }
}
