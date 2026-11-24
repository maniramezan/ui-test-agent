import OSLog
import SwiftCommons
import SwiftUI

/// One task, loaded by id, with a switch for its done state.
struct TaskDetailView: View {
    private static let logger = Logger.forType(subsystem: "ExampleApp", TaskDetailView.self)

    let id: String
    let session: SessionModel
    let onChange: (TaskItem) -> Void

    @State private var task: TaskItem?
    @State private var problem: String?

    var body: some View {
        Form {
            if let task {
                Section {
                    Text(task.title)
                        .accessibilityIdentifier(ID.taskTitle)
                    if let notes = task.notes {
                        Text(notes)
                            .foregroundStyle(Theme.Palette.secondary)
                            .accessibilityIdentifier(ID.taskNotes)
                    }
                }
                Section {
                    Toggle(
                        "Done",
                        isOn: Binding(
                            get: { task.done },
                            set: { done in
                                Task {
                                    await setDone(done)
                                }
                            }
                        )
                    )
                    .accessibilityIdentifier(ID.taskDone)
                }
            } else if problem == nil {
                ProgressView()
            }
            if let problem {
                Section {
                    Text(problem)
                        .foregroundStyle(Theme.Palette.failure)
                        .accessibilityIdentifier(ID.taskError)
                }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {
        Self.logger.infoPublic("Loading task=\(id)")
        do {
            task = try await session.client.task(id: id)
            Self.logger.infoPublic("Loaded task=\(id)")
        } catch {
            report(error, action: "load")
        }
    }

    private func setDone(_ done: Bool) async {
        Self.logger.infoPublic("Setting task=\(id) done=\(done)")
        do {
            let changed = try await session.client.setDone(done, id: id)
            task = changed
            problem = nil
            onChange(changed)
            Self.logger.infoPublic("Changed task=\(id)")
        } catch {
            report(error, action: "setDone")
        }
    }

    private func report(_ error: any Error, action: String) {
        Self.logger.error("Task detail failed", error: error, context: "feature=task action=\(action) task=\(id)")
        let failure = error as? APIError ?? .malformed
        if failure.endsSession {
            session.sessionEnded(failure)
        } else {
            problem = failure.message
        }
    }
}
