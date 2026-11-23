import Foundation

public enum BridgeError: Error, Equatable, LocalizedError {
    case configUnreadable(path: String, reason: String)
    case configInvalid(path: String, problems: [String])
    case configNotGiven
    case platformNotConfigured(platform: String, app: String)
    case unknownPlatform(String?)
    case unknownPlaceholder(name: String)
    case missingAdminCredential(environmentVariable: String)
    case serverNotReady(url: String, seconds: Double)
    case adminUnauthorized(url: String)
    case unexpectedStatus(method: String, url: String, status: Int, reason: String? = nil)
    case malformedResponse(url: String)
    case invalidArgument(name: String, reason: String)
    case unsupportedProtocol(Int)
    case noSession

    public var errorDescription: String? {
        switch self {
        case .configUnreadable(let path, let reason):
            "Can't read config \(path): \(reason)"
        case .configInvalid(let path, let problems):
            "Config \(path) is invalid:\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
        case .configNotGiven:
            "No per-app config: set the flow variable \(ExtensionHandler.configVariable) or the environment variable \(ExtensionHandler.configEnvironmentVariable)"
        case .platformNotConfigured(let platform, let app):
            "Config for \(app) has no platforms.\(platform)"
        case .unknownPlatform(let platform):
            "Run platform \(platform.map { "'\($0)'" } ?? "(none)") is not ios or android"
        case .unknownPlaceholder(let name):
            "Unknown launch placeholder {{\(name)}}"
        case .missingAdminCredential(let variable):
            "Admin credential environment variable \(variable) is not set"
        case .serverNotReady(let url, let seconds):
            "moqserver did not answer \(url) within \(seconds.formatted())s; start it first (for example the app's serve script)"
        case .adminUnauthorized(let url):
            "moqserver refused admin credentials at \(url) (401)"
        case .unexpectedStatus(let method, let url, let status, let reason):
            "\(method) \(url) answered \(status)" + (reason.map { ": \($0)" } ?? "")
        case .malformedResponse(let url):
            "Unexpected response body from \(url)"
        case .invalidArgument(let name, let reason):
            "Argument \(name): \(reason)"
        case .unsupportedProtocol(let version):
            "amoo sent protocol \(version); this amoo-ext-moq speaks protocol \(ExtensionReply.protocolVersion)"
        case .noSession:
            "No moqserver session for this run; flow_start did not succeed"
        }
    }
}
