package com.example.app

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** The task list: what is loaded, under which filter, and what last went wrong. */
class TasksModel(private val session: SessionModel) {
    sealed interface Phase {
        data object Loading : Phase

        data object Loaded : Phase

        data class Failed(val message: String) : Phase
    }

    private val client = session.client
    private var page = 1

    var phase: Phase by mutableStateOf(Phase.Loading)
        private set

    var items: List<TaskItem> by mutableStateOf(emptyList())
        private set

    var total: Int by mutableStateOf(0)
        private set

    var hasMore: Boolean by mutableStateOf(false)
        private set

    var filter: StatusFilter by mutableStateOf(StatusFilter.All)
        private set

    var loadingMore: Boolean by mutableStateOf(false)
        private set

    var refreshing: Boolean by mutableStateOf(false)
        private set

    /** Why the last delete or change failed; the list itself is still shown. */
    var actionError: String? by mutableStateOf(null)

    suspend fun load() {
        phase = Phase.Loading
        fetchFirstPage(refreshing = false)
    }

    suspend fun refresh() {
        refreshing = true
        fetchFirstPage(refreshing = true)
        refreshing = false
    }

    suspend fun apply(newFilter: StatusFilter) {
        if (newFilter == filter) {
            return
        }
        filter = newFilter
        load()
    }

    suspend fun loadMore() {
        if (!hasMore || loadingMore) {
            return
        }
        loadingMore = true
        val next = page + 1
        Log.i(TAG, "Loading page $next filter=${filter.key}")
        try {
            val result = client.tasks(filter, next, refreshing = false)
            page = next
            items = items + result.items
            total = result.total
            hasMore = result.hasMore
            Log.i(TAG, "Loaded page $next: ${result.items.size} tasks")
        } catch (error: ApiError) {
            report(error, "loadMore")
        }
        loadingMore = false
    }

    fun add(task: TaskItem) {
        if (filter == StatusFilter.Done) {
            return
        }
        items = listOf(task) + items
        total += 1
    }

    fun replace(task: TaskItem) {
        items = items.map { if (it.id == task.id) task else it }
    }

    suspend fun delete(task: TaskItem) {
        Log.i(TAG, "Deleting task=${task.id}")
        try {
            client.deleteTask(task.id)
            items = items.filterNot { it.id == task.id }
            total = maxOf(0, total - 1)
            Log.i(TAG, "Deleted task=${task.id}")
        } catch (error: ApiError) {
            report(error, "delete task=${task.id}")
        }
    }

    suspend fun deleteAll() {
        Log.i(TAG, "Deleting all tasks")
        try {
            val deleted = client.deleteAllTasks()
            Log.i(TAG, "Deleted $deleted tasks")
            load()
        } catch (error: ApiError) {
            report(error, "deleteAll")
        }
    }

    private suspend fun fetchFirstPage(refreshing: Boolean) {
        Log.i(TAG, "Loading tasks filter=${filter.key} refreshing=$refreshing")
        try {
            val result = client.tasks(filter, 1, refreshing)
            page = 1
            items = result.items
            total = result.total
            hasMore = result.hasMore
            phase = Phase.Loaded
            Log.i(TAG, "Loaded ${result.items.size} of ${result.total} tasks")
        } catch (error: ApiError) {
            if (error.endsSession) {
                session.sessionEnded(error)
            } else {
                Log.e(TAG, "Loading tasks failed feature=tasks action=load", error)
                phase = Phase.Failed(error.userMessage)
            }
        }
    }

    private fun report(error: ApiError, action: String) {
        Log.e(TAG, "Task action failed feature=tasks action=$action", error)
        if (error.endsSession) {
            session.sessionEnded(error)
        } else {
            actionError = error.userMessage
        }
    }

    private companion object {
        const val TAG = "ExampleApp.TasksModel"
    }
}
