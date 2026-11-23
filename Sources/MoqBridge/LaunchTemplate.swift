import Foundation

/// Renders `{{name}}` placeholders in launch-environment values.
public enum LaunchTemplate {
    public static let baseURL = "baseURL"
    public static let sessionId = "sessionId"
    public static let known: Set<String> = [baseURL, sessionId]

    /// The placeholder names a value uses, in order of appearance.
    public static func placeholders(in value: String) -> [String] {
        value.matches(of: /\{\{([A-Za-z]+)\}\}/).map { String($0.output.1) }
    }

    public static func render(_ value: String, values: [String: String]) throws -> String {
        try value.replacing(/\{\{([A-Za-z]+)\}\}/) { match in
            let name = String(match.output.1)
            guard let replacement = values[name] else {
                throw BridgeError.unknownPlaceholder(name: name)
            }
            return replacement
        }
    }

    public static func render(_ environment: [String: String], values: [String: String]) throws
        -> [String: String]
    {
        try environment.mapValues { try render($0, values: values) }
    }
}
