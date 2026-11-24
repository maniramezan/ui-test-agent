import Foundation

/// amoo's `emit` request (mobile-testing docs/flow-extensions.md, "Generated tests"): asks an
/// extension for the test code of its setup, its teardown, or one of its steps.
public struct EmitRequest: Decodable, Sendable {
    public struct Step: Decodable, Sendable {
        public var tool: String
        public var arguments: [String: JSONValue]?

        public init(tool: String, arguments: [String: JSONValue]? = nil) {
            self.tool = tool
            self.arguments = arguments
        }
    }

    public var `protocol`: Int
    public var verb: String
    /// `xcuitest`, `espresso` or `compose`.
    public var framework: String
    public var platform: String?
    /// `setup`, `teardown` or `step`.
    public var phase: String
    /// The app's test context, as amoo read it; nil when the app has none.
    public var testContext: JSONValue?
    public var step: Step?

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case verb
        case framework
        case platform
        case phase
        case testContext = "test_context"
        case step
    }

    public init(
        framework: String, platform: String? = nil, phase: String, testContext: JSONValue? = nil,
        step: Step? = nil
    ) {
        self.protocol = 1
        self.verb = "emit"
        self.framework = framework
        self.platform = platform
        self.phase = phase
        self.testContext = testContext
        self.step = step
    }
}

/// The code for one `emit` request. `ok: false` with a message means this part can't be written
/// for the framework, and amoo stops generation naming it.
public struct EmitReply: Encodable, Sendable, Equatable {
    public var `protocol` = 1
    public var ok: Bool?
    public var message: String?
    /// Modules (Swift) or fully qualified names (Kotlin) to import.
    public var imports: [String]?
    /// Declarations on the test class.
    public var members: [String]?
    /// The phase's statements.
    public var lines: [String]?
    /// `throws` and/or `async`: what the surrounding function needs.
    public var requires: [String]?

    public init(
        ok: Bool? = nil, message: String? = nil, imports: [String]? = nil, members: [String]? = nil,
        lines: [String]? = nil, requires: [String]? = nil
    ) {
        self.ok = ok
        self.message = message
        self.imports = imports
        self.members = members
        self.lines = lines
        self.requires = requires
    }

    public static func unsupported(_ message: String) -> EmitReply {
        EmitReply(ok: false, message: message)
    }
}
