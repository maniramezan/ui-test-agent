import Foundation

public enum AuthError: Error, Equatable, LocalizedError {
    case configNotGiven
    case configUnreadable(path: String, reason: String)
    case configInvalid(path: String, problem: String)
    case hostNotGiven
    case notAnEmulator(host: String)
    case emulatorNotReachable(url: String)
    case emulatorRefused(action: String, status: Int, reason: String?)
    case malformedResponse(action: String)
    case noAccount(email: String)
    case noRunState

    public var errorDescription: String? {
        switch self {
        case .configNotGiven:
            "No per-app config: set the flow variable \(AuthHandler.configVariable) (or \(AuthHandler.moqConfigVariable)) or the environment variable \(AuthHandler.configEnvironmentVariable)"
        case .configUnreadable(let path, let reason):
            "Can't read config \(path): \(reason)"
        case .configInvalid(let path, let problem):
            "Config \(path) is invalid: \(problem)"
        case .hostNotGiven:
            "No emulator host: set auth.host in the config or \(AuthConfig.hostEnvironmentVariable)"
        case .notAnEmulator(let host):
            "\(host) is a Google host; auth.* steps only act on a local emulator"
        case .emulatorNotReachable(let url):
            "The auth emulator did not answer \(url); start it first"
        case .emulatorRefused(let action, let status, let reason):
            "The auth emulator refused \(action) (\(status))" + (reason.map { ": \($0)" } ?? "")
        case .malformedResponse(let action):
            "Unexpected response from the auth emulator to \(action)"
        case .noAccount(let email):
            "The auth emulator has no account with email \(email)"
        case .noRunState:
            "No auth state for this run; flow_start did not succeed"
        }
    }
}
