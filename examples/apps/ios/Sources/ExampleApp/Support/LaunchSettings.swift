import Foundation

/// A bug the app can be launched with (`APP_FAULT`, comma-separated), so a test suite can be
/// measured by whether it notices.
enum Fault: String, CaseIterable, Sendable {
    /// A pull-to-refresh sends the list request without its `Authorization` header.
    case dropAuthorizationOnRefresh = "drop-authorization-on-refresh"
    /// No request carries the session cookie.
    case omitCookie = "omit-cookie"
    /// The list request always asks for `status=all`, whatever filter is shown.
    case ignoreFilter = "ignore-filter"
    /// Delete All deletes without asking.
    case skipDeleteConfirmation = "skip-delete-confirmation"
}

/// What the launch environment tells the app: where its backend is and, under test, which mock
/// session or backend test session it belongs to.
struct LaunchSettings: Sendable, Equatable {
    static let baseURLKey = "APP_BASE_URL"
    static let mockBaseURLKey = "APP_MOCK_BASE_URL"
    static let mockSessionKey = "APP_MOCK_SESSION"
    static let testSessionKey = "APP_TEST_SESSION"
    static let faultKey = "APP_FAULT"
    /// The on-device recorder's own launch key: write the run's traffic to a HAR file.
    static let recordKey = "APITRACE_HAR_FILE"
    static let defaultBaseURL = "http://127.0.0.1:8081"
    static let mockSessionHeader = "X-Mock-Session"
    static let testSessionHeader = "X-Test-Session"

    var baseURL: URL
    var mockSession: String?
    /// Under test against the real backend: the data set this launch reads and writes, so tests
    /// running at the same time don't see each other's changes.
    var testSession: String?
    var faults: Set<Fault>
    var recordsTraffic: Bool
    /// Set when the launch can't be trusted, and shown instead of the app.
    var problem: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let mockBase = environment[Self.mockBaseURLKey].flatMap { $0.isEmpty ? nil : $0 }
        let session = environment[Self.mockSessionKey].flatMap { $0.isEmpty ? nil : $0 }
        let raw = mockBase ?? environment[Self.baseURLKey] ?? Self.defaultBaseURL
        var problem: String?
        if mockBase != nil, session == nil {
            // Without this guard the app would talk to the mock server outside any session, or,
            // in an app with a production default, to its real backend, and every request check
            // would pass on an empty history.
            problem = "\(Self.mockBaseURLKey) is set but \(Self.mockSessionKey) is not."
        }
        if let url = URL(string: raw), url.scheme != nil, url.host() != nil {
            baseURL = url
        } else {
            baseURL = URL(filePath: "/")
            problem = "\(raw) is not a base URL."
        }
        mockSession = mockBase == nil ? nil : session
        testSession = environment[Self.testSessionKey].flatMap { $0.isEmpty ? nil : $0 }
        recordsTraffic = environment[Self.recordKey] == "1"
        faults = Set(
            (environment[Self.faultKey] ?? "")
                .split(separator: ",")
                .compactMap { Fault(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        self.problem = problem
    }
}
