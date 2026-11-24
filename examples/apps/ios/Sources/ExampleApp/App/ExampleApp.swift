import APITraceCore
import APITraceDebug
import OSLog
import SwiftCommons
import SwiftUI

@main
struct ExampleApp: App {
    private static let logger = Logger.forType(subsystem: "ExampleApp", ExampleApp.self)

    private let settings: LaunchSettings
    @State private var session: SessionModel

    init() {
        let settings = LaunchSettings()
        // Records the app's own traffic, and writes it as a HAR file when launched with
        // APITRACE_HAR_FILE=1, so a mock bundle can be imported from a real run.
        APITraceDebugBootstrap.install(maxRecords: 500)
        APITrace.start()
        self.settings = settings
        _session = State(initialValue: SessionModel(client: APIClient(settings: settings)))
        Self.logger.infoPublic(
            "Launched mock=\(settings.mockSession != nil) testSession=\(settings.testSession != nil) faults=\(settings.faults.map(\.rawValue).sorted())"
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings, session: session)
        }
    }
}

struct RootView: View {
    let settings: LaunchSettings
    let session: SessionModel

    var body: some View {
        if let problem = settings.problem {
            SessionGuardView(problem: problem)
        } else if case .signedIn(let user) = session.phase {
            TaskListView(session: session, faults: settings.faults)
                .id(user.id)
        } else {
            SignInView(session: session)
        }
    }
}

/// Replaces the whole app when the launch settings can't be trusted, so a misconfigured test
/// run fails on its first step instead of quietly talking to the wrong backend.
private struct SessionGuardView: View {
    let problem: String

    var body: some View {
        ContentUnavailableView(
            "Can't start",
            systemImage: "exclamationmark.triangle",
            description: Text(problem)
        )
        // One element: an identifier on the container alone lands on its image and both texts.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(ID.sessionGuardMessage)
    }
}
