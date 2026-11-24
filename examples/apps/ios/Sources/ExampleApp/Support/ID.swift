/// Accessibility identifiers, as listed in `examples/ids.json`.
enum ID {
    static let sessionGuardMessage = "sessionGuard.message"

    static let signInEmail = "signIn.email"
    static let signInPassword = "signIn.password"
    static let signInSubmit = "signIn.submit"
    static let signInError = "signIn.error"

    static let tasksList = "tasks.list"
    static let tasksCount = "tasks.count"
    static let tasksFilterLabel = "tasks.filterLabel"
    static let tasksLoading = "tasks.loading"
    static let tasksEmpty = "tasks.empty"
    static let tasksError = "tasks.error"
    static let tasksRetry = "tasks.retry"
    static let tasksLoadMore = "tasks.loadMore"
    static let tasksAdd = "tasks.add"
    static let tasksFilter = "tasks.filter"
    static let tasksEdit = "tasks.edit"
    static let tasksDeleteAll = "tasks.deleteAll"
    static let tasksDeleteAllConfirm = "tasks.deleteAll.confirm"
    static let tasksDeleteAllCancel = "tasks.deleteAll.cancel"
    static let tasksActionError = "tasks.actionError"
    static let tasksSignOut = "tasks.signOut"

    static func taskRow(_ id: String) -> String {
        "tasks.row.\(id)"
    }

    static func taskRowDone(_ id: String) -> String {
        "tasks.row.\(id).done"
    }

    static func filter(_ filter: StatusFilter) -> String {
        "filter.\(filter.rawValue)"
    }

    static let filterClose = "filter.close"

    static let newTaskTitle = "newTask.title"
    static let newTaskNotes = "newTask.notes"
    static let newTaskSave = "newTask.save"
    static let newTaskCancel = "newTask.cancel"
    static let newTaskError = "newTask.error"

    static let taskTitle = "task.title"
    static let taskNotes = "task.notes"
    static let taskDone = "task.done"
    static let taskError = "task.error"
}
