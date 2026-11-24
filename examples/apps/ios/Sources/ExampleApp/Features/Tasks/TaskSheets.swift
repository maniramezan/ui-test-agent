import OSLog
import SwiftCommons
import SwiftUI

/// Picks the list's filter. Choosing an option applies it and closes the sheet.
struct FilterSheet: View {
    let current: StatusFilter
    let onPick: (StatusFilter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(StatusFilter.allCases) { option in
                Button {
                    onPick(option)
                    dismiss()
                } label: {
                    FilterOptionLabel(option: option, selected: option == current)
                }
                .accessibilityIdentifier(ID.filter(option))
                .accessibilityValue(option == current ? "Selected" : "")
            }
            .navigationTitle("Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier(ID.filterClose)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct FilterOptionLabel: View {
    let option: StatusFilter
    let selected: Bool

    var body: some View {
        HStack {
            Text(option.title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }
}

/// The form for a new task. A validation problem from the server shows under the title field.
struct NewTaskView: View {
    private static let logger = Logger.forType(subsystem: "ExampleApp", NewTaskView.self)

    let session: SessionModel
    let onCreate: (TaskItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var titleProblem: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier(ID.newTaskTitle)
                    FieldProblem(text: titleProblem)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .accessibilityIdentifier(ID.newTaskNotes)
                }
                if let problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(Theme.Palette.failure)
                            .accessibilityIdentifier(ID.newTaskError)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier(ID.newTaskCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier(ID.newTaskSave)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        titleProblem = nil
        problem = nil
        Self.logger.infoPublic("Creating task")
        do {
            let created = try await session.client.createTask(
                title: title, notes: notes.isEmpty ? nil : notes)
            Self.logger.infoPublic("Created task=\(created.id)")
            onCreate(created)
            dismiss()
        } catch let error as APIError {
            Self.logger.error("Creating task failed", error: error, context: "feature=newTask action=save")
            if error.endsSession {
                dismiss()
                session.sessionEnded(error)
            } else if case .rejected(_, _, let message, let fields) = error {
                titleProblem = fields["title"]
                problem = titleProblem == nil ? message : nil
            } else {
                problem = error.message
            }
        } catch {
            Self.logger.error("Creating task failed", error: error, context: "feature=newTask action=save")
            problem = APIError.malformed.message
        }
    }
}
