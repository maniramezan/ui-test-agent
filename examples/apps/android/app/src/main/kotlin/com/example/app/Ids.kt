package com.example.app

/** The accessibility identifiers of `examples/ids.json`, exposed as test tags. */
object Ids {
    const val SESSION_GUARD_MESSAGE = "sessionGuard.message"

    const val SIGN_IN_EMAIL = "signIn.email"
    const val SIGN_IN_PASSWORD = "signIn.password"
    const val SIGN_IN_SUBMIT = "signIn.submit"
    const val SIGN_IN_ERROR = "signIn.error"

    const val TASKS_LIST = "tasks.list"
    const val TASKS_COUNT = "tasks.count"
    const val TASKS_FILTER_LABEL = "tasks.filterLabel"
    const val TASKS_LOADING = "tasks.loading"
    const val TASKS_EMPTY = "tasks.empty"
    const val TASKS_ERROR = "tasks.error"
    const val TASKS_RETRY = "tasks.retry"
    const val TASKS_LOAD_MORE = "tasks.loadMore"
    const val TASKS_ADD = "tasks.add"
    const val TASKS_FILTER = "tasks.filter"
    const val TASKS_EDIT = "tasks.edit"
    const val TASKS_DELETE_ALL = "tasks.deleteAll"
    const val TASKS_DELETE_ALL_CONFIRM = "tasks.deleteAll.confirm"
    const val TASKS_DELETE_ALL_CANCEL = "tasks.deleteAll.cancel"
    const val TASKS_ACTION_ERROR = "tasks.actionError"
    const val TASKS_SIGN_OUT = "tasks.signOut"

    const val FILTER_CLOSE = "filter.close"

    const val NEW_TASK_TITLE = "newTask.title"
    const val NEW_TASK_NOTES = "newTask.notes"
    const val NEW_TASK_SAVE = "newTask.save"
    const val NEW_TASK_CANCEL = "newTask.cancel"
    const val NEW_TASK_ERROR = "newTask.error"

    const val TASK_TITLE = "task.title"
    const val TASK_NOTES = "task.notes"
    const val TASK_DONE = "task.done"
    const val TASK_ERROR = "task.error"

    fun taskRow(id: String) = "tasks.row.$id"

    fun taskRowDone(id: String) = "tasks.row.$id.done"

    fun filter(option: StatusFilter) = "filter.${option.key}"
}
