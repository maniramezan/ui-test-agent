import ExtensionKit
import Foundation

/// An amoo flow file (`*.amoo.json`), as far as `uita` needs to read it.
public struct Flow: Decodable, Sendable, Equatable {
    public struct Step: Decodable, Sendable, Equatable {
        public var name: String?
        public var tool: String
        public var arguments: [String: JSONValue]?

        public init(name: String? = nil, tool: String, arguments: [String: JSONValue]? = nil) {
            self.name = name
            self.tool = tool
            self.arguments = arguments
        }

        /// The extension a `prefix.step` tool belongs to; nil for amoo's own tools.
        public var extensionPrefix: String? {
            guard let dot = tool.firstIndex(of: "."), dot != tool.startIndex else {
                return nil
            }
            return String(tool[..<dot])
        }

        /// The tool without its extension prefix.
        public var localTool: String {
            guard let dot = tool.firstIndex(of: ".") else {
                return tool
            }
            return String(tool[tool.index(after: dot)...])
        }
    }

    public var platform: String?
    public var terminateAppAtEnd: Bool?
    public var extensions: [String]?
    public var vars: [String: String]?
    public var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case platform
        case terminateAppAtEnd = "terminate_app_at_end"
        case extensions
        case vars
        case steps
    }

    public init(
        platform: String? = nil,
        terminateAppAtEnd: Bool? = nil,
        extensions: [String]? = nil,
        vars: [String: String]? = nil,
        steps: [Step]
    ) {
        self.platform = platform
        self.terminateAppAtEnd = terminateAppAtEnd
        self.extensions = extensions
        self.vars = vars
        self.steps = steps
    }

    public static func load(from url: URL) throws -> Flow {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UitaError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Flow.self, from: data)
        } catch {
            throw UitaError.notAFlow(path: url.path, reason: String(describing: error))
        }
    }

    /// Whether the run starts `prefix`'s extension: a step of its own, or a declaration.
    public func uses(extension prefix: String) -> Bool {
        (extensions ?? []).contains(prefix) || steps.contains { $0.extensionPrefix == prefix }
    }

    /// `text` with each `${name}` the flow's `vars` define filled in. Nil when a name is left
    /// over, because its value only exists at run time.
    public func resolved(_ text: String) -> String? {
        var result = text
        for (name, value) in vars ?? [:] {
            result = result.replacingOccurrences(of: "${\(name)}", with: value)
        }
        return result.contains("${") ? nil : result
    }

    /// A string argument of `step`, with flow variables filled in when they can be.
    public func string(_ name: String, of step: Step) -> String? {
        guard case .string(let text) = step.arguments?[name] else {
            return nil
        }
        return resolved(text)
    }
}

public enum UitaError: Error, Equatable, LocalizedError {
    case unreadable(path: String, reason: String)
    case notAFlow(path: String, reason: String)
    case toolFailed(tool: String, reason: String)
    case invalidOption(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Can't read \(path): \(reason)"
        case .notAFlow(let path, let reason):
            "\(path) is not an amoo flow: \(reason)"
        case .toolFailed(let tool, let reason):
            "\(tool) failed: \(reason)"
        case .invalidOption(let name, let reason):
            "\(name): \(reason)"
        }
    }
}
