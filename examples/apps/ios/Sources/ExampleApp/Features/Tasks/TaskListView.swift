import SwiftUI

struct TaskListView: View {
    let session: SessionModel
    let faults: Set<Fault>

    @State private var model: TasksModel
    @State private var editMode = EditMode.inactive
    @State private var showingFilter = false
    @State private var showingNewTask = false
    @State private var confirmingDeleteAll = false

    init(session: SessionModel, faults: Set<Fault>) {
        self.session = session
        self.faults = faults
        _model = State(initialValue: TasksModel(session: session))
    }

    var body: some View {
        NavigationStack {
            TaskListContent(model: model)
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { id in
                    TaskDetailView(id: id, session: session) { changed in
                        model.replace(changed)
                    }
                }
                .environment(\.editMode, $editMode)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                            }
                        }
                        .accessibilityIdentifier(ID.tasksEdit)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Filter", systemImage: "line.3.horizontal.decrease") {
                            showingFilter = true
                        }
                        .accessibilityIdentifier(ID.tasksFilter)
                        Button("Add", systemImage: "plus") {
                            showingNewTask = true
                        }
                        .accessibilityIdentifier(ID.tasksAdd)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Sign Out") {
                            Task {
                                await session.signOut()
                            }
                        }
                        .accessibilityIdentifier(ID.tasksSignOut)
                        Spacer()
                        if editMode.isEditing {
                            Button("Delete All", role: .destructive) {
                                deleteAllTapped()
                            }
                            .disabled(model.items.isEmpty)
                            .accessibilityIdentifier(ID.tasksDeleteAll)
                        }
                    }
                }
                .sheet(isPresented: $showingFilter) {
                    FilterSheet(current: model.filter) { picked in
                        Task {
                            await model.apply(picked)
                        }
                    }
                }
                .sheet(isPresented: $showingNewTask) {
                    NewTaskView(session: session) { created in
                        model.add(created)
                    }
                }
                .alert("Delete all tasks?", isPresented: $confirmingDeleteAll) {
                    Button("Delete All", role: .destructive) {
                        deleteAll()
                    }
                    .accessibilityIdentifier(ID.tasksDeleteAllConfirm)
                    Button("Cancel", role: .cancel) {}
                        .accessibilityIdentifier(ID.tasksDeleteAllCancel)
                } message: {
                    Text("This can't be undone.")
                }
                .alert(
                    "Couldn't finish",
                    isPresented: Binding(
                        get: { model.actionError != nil },
                        set: { showing in
                            if !showing {
                                model.actionError = nil
                            }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.actionError ?? "")
                        .accessibilityIdentifier(ID.tasksActionError)
                }
                .task {
                    await model.load()
                }
        }
    }

    private func deleteAllTapped() {
        if faults.contains(.skipDeleteConfirmation) {
            deleteAll()
        } else {
            confirmingDeleteAll = true
        }
    }

    private func deleteAll() {
        Task {
            await model.deleteAll()
            editMode = .inactive
        }
    }
}

/// The list area in each of its states: loading, failed, empty, or the rows.
private struct TaskListContent: View {
    let model: TasksModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading tasks")
                .accessibilityIdentifier(ID.tasksLoading)
        case .failed(let message):
            LoadFailureView(message: message) {
                Task {
                    await model.load()
                }
            }
        case .loaded:
            VStack(spacing: 0) {
                TaskListSummary(total: model.total, filter: model.filter)
                if model.items.isEmpty {
                    EmptyTasksView(filter: model.filter)
                } else {
                    TaskRows(model: model)
                }
            }
        }
    }
}

private struct TaskListSummary: View {
    let total: Int
    let filter: StatusFilter

    var body: some View {
        HStack {
            Text(total == 1 ? "1 task" : "\(total) tasks")
                .accessibilityIdentifier(ID.tasksCount)
            Spacer()
            Text(filter.title)
                .accessibilityIdentifier(ID.tasksFilterLabel)
        }
        .font(Theme.Typography.detail)
        .foregroundStyle(Theme.Palette.secondary)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }
}

private struct TaskRows: View {
    let model: TasksModel

    var body: some View {
        List {
            ForEach(model.items) { task in
                NavigationLink(value: task.id) {
                    TaskRow(task: task)
                }
                .accessibilityIdentifier(ID.taskRow(task.id))
                .accessibilityValue(task.done ? "Done" : "Open")
            }
            .onDelete { offsets in
                let doomed = offsets.map { model.items[$0] }
                Task {
                    for task in doomed {
                        await model.delete(task)
                    }
                }
            }
            if model.hasMore {
                Button(model.loadingMore ? "Loading…" : "Load more") {
                    Task {
                        await model.loadMore()
                    }
                }
                .disabled(model.loadingMore)
                .accessibilityIdentifier(ID.tasksLoadMore)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier(ID.tasksList)
        .refreshable {
            await model.refresh()
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if task.done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.done)
                    .accessibilityIdentifier(ID.taskRowDone(task.id))
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Theme.Palette.secondary)
            }
            Text(task.title)
                .font(Theme.Typography.body)
        }
    }
}

private struct EmptyTasksView: View {
    let filter: StatusFilter

    var body: some View {
        ContentUnavailableView(
            filter == .all ? "No tasks yet" : "No \(filter.title.lowercased()) tasks",
            systemImage: "checklist",
            description: Text("Tap + to add one.")
        )
        .accessibilityIdentifier(ID.tasksEmpty)
    }
}

private struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Text(message)
                .font(Theme.Typography.body)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(ID.tasksError)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(ID.tasksRetry)
        }
        .padding(Theme.Spacing.large)
    }
}
