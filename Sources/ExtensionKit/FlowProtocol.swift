import Foundation

/// One request from amoo's flow-extension protocol, version 1 (mobile-testing docs/flow-extensions.md).
/// `State` is the extension's own per-run data, which amoo stores and sends back unread.
public struct FlowRequest<State: Codable & Sendable>: Decodable, Sendable {
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
    public var state: State?
    public var vars: [String: String]?
    public var step: Step?
    public var passed: Bool?
    /// Sent with `flow_end` by amoo 638c4b8 and later: whether every app the run launched was ended
    /// (`terminate_app_at_end`). nil from older amoo builds.
    public var appTerminated: Bool?
    /// Sent with `flow_end` by amoo 686317a and later: how many apps the run launched. With it,
    /// `app_terminated: false` and `apps_launched: 0` means there was nothing to end.
    public var appsLaunched: Int?

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case verb
        case run
        case state
        case vars
        case step
        case passed
        case appTerminated = "app_terminated"
        case appsLaunched = "apps_launched"
    }
}

/// One reply to amoo. Any field may be omitted; see amoo's docs/flow-extensions.md for what each does.
public struct FlowReply<State: Codable & Sendable & Equatable>: Encodable, Sendable, Equatable {
    public static var protocolVersion: Int { 1 }

    public var `protocol` = 1
    public var ok: Bool?
    public var message: String?
    public var result: JSONValue?
    public var state: State?
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
        state: State? = nil,
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
