package com.example.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.example.app.Fault
import com.example.app.Ids
import com.example.app.SessionModel
import com.example.app.StatusFilter
import com.example.app.TaskItem
import com.example.app.TasksModel
import kotlinx.coroutines.launch

/** Where the signed-in user is: the list, one task, or the new-task form. */
private sealed interface Place {
    data object List : Place

    data class Detail(val id: String) : Place

    data object NewTask : Place
}

/** Everything behind sign-in. The list's model outlives a visit to a task or the form. */
@Composable
fun TasksHome(session: SessionModel, faults: Set<Fault>) {
    val model = remember { TasksModel(session) }
    var place by remember { mutableStateOf<Place>(Place.List) }

    LaunchedEffect(model) {
        model.load()
    }
    when (val current = place) {
        Place.List ->
            TaskListScreen(
                session = session,
                model = model,
                faults = faults,
                onOpen = { place = Place.Detail(it) },
                onAdd = { place = Place.NewTask },
            )
        is Place.Detail ->
            TaskDetailScreen(
                id = current.id,
                session = session,
                onChange = model::replace,
                onBack = { place = Place.List },
            )
        Place.NewTask -> NewTaskScreen(session = session, onCreate = model::add, onClose = { place = Place.List })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskListScreen(
    session: SessionModel,
    model: TasksModel,
    faults: Set<Fault>,
    onOpen: (String) -> Unit,
    onAdd: () -> Unit,
) {
    var editing by remember { mutableStateOf(false) }
    var showingFilter by remember { mutableStateOf(false) }
    var confirmingDeleteAll by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Tasks") },
                navigationIcon = {
                    TextButton(onClick = { editing = !editing }, modifier = Modifier.testTag(Ids.TASKS_EDIT)) {
                        Text(if (editing) "Done" else "Edit")
                    }
                },
                actions = {
                    TextButton(onClick = { showingFilter = true }, modifier = Modifier.testTag(Ids.TASKS_FILTER)) {
                        Text("Filter")
                    }
                    TextButton(onClick = onAdd, modifier = Modifier.testTag(Ids.TASKS_ADD)) {
                        Text("Add")
                    }
                },
            )
        },
        bottomBar = {
            BottomAppBar {
                TextButton(
                    onClick = { scope.launch { session.signOut() } },
                    modifier = Modifier.testTag(Ids.TASKS_SIGN_OUT),
                ) {
                    Text("Sign Out")
                }
                Spacer(Modifier.weight(1f))
                if (editing) {
                    TextButton(
                        enabled = model.items.isNotEmpty(),
                        onClick = {
                            if (Fault.SkipDeleteConfirmation in faults) {
                                scope.launch { model.deleteAll() }
                            } else {
                                confirmingDeleteAll = true
                            }
                        },
                        modifier = Modifier.testTag(Ids.TASKS_DELETE_ALL),
                    ) {
                        Text("Delete All", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (val phase = model.phase) {
                TasksModel.Phase.Loading ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(modifier = Modifier.testTag(Ids.TASKS_LOADING))
                    }
                is TasksModel.Phase.Failed ->
                    LoadFailure(message = phase.message) {
                        scope.launch { model.load() }
                    }
                TasksModel.Phase.Loaded -> {
                    TaskListSummary(total = model.total, filter = model.filter)
                    HorizontalDivider()
                    if (model.items.isEmpty()) {
                        EmptyTasks(model.filter)
                    } else {
                        PullToRefreshBox(
                            isRefreshing = model.refreshing,
                            onRefresh = { scope.launch { model.refresh() } },
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            LazyColumn(modifier = Modifier.fillMaxSize().testTag(Ids.TASKS_LIST)) {
                                items(model.items, key = { it.id }) { task ->
                                    TaskRow(
                                        task = task,
                                        onOpen = { onOpen(task.id) },
                                        onDelete = { scope.launch { model.delete(task) } },
                                    )
                                    HorizontalDivider()
                                }
                                if (model.hasMore) {
                                    item(key = Ids.TASKS_LOAD_MORE) {
                                        TextButton(
                                            enabled = !model.loadingMore,
                                            onClick = { scope.launch { model.loadMore() } },
                                            modifier = Modifier.fillMaxWidth().testTag(Ids.TASKS_LOAD_MORE),
                                        ) {
                                            Text(if (model.loadingMore) "Loading…" else "Load More")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showingFilter) {
        FilterSheet(
            current = model.filter,
            onPick = { picked -> scope.launch { model.apply(picked) } },
            onClose = { showingFilter = false },
        )
    }
    if (confirmingDeleteAll) {
        AlertDialog(
            onDismissRequest = { confirmingDeleteAll = false },
            title = { Text("Delete all tasks?") },
            text = { Text("This can't be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDeleteAll = false
                        scope.launch { model.deleteAll() }
                    },
                    modifier = Modifier.testTag(Ids.TASKS_DELETE_ALL_CONFIRM),
                ) {
                    Text("Delete All", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmingDeleteAll = false },
                    modifier = Modifier.testTag(Ids.TASKS_DELETE_ALL_CANCEL),
                ) {
                    Text("Cancel")
                }
            },
            modifier = Modifier.exposeTestTags(),
        )
    }
    model.actionError?.let { message ->
        AlertDialog(
            onDismissRequest = { model.actionError = null },
            title = { Text("Couldn't finish") },
            text = { Text(message, modifier = Modifier.testTag(Ids.TASKS_ACTION_ERROR)) },
            confirmButton = { TextButton(onClick = { model.actionError = null }) { Text("OK") } },
            modifier = Modifier.exposeTestTags(),
        )
    }
}

@Composable
private fun TaskListSummary(total: Int, filter: StatusFilter) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.medium, vertical = Spacing.small),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            if (total == 1) "1 task" else "$total tasks",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag(Ids.TASKS_COUNT),
        )
        Text(
            filter.title,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag(Ids.TASKS_FILTER_LABEL),
        )
    }
}

/** A row that opens its task on a tap and deletes it on a swipe to the left. */
@Composable
private fun TaskRow(task: TaskItem, onOpen: () -> Unit, onDelete: () -> Unit) {
    val state = rememberSwipeToDismissBoxState()
    LaunchedEffect(state.currentValue) {
        if (state.currentValue == SwipeToDismissBoxValue.EndToStart) {
            onDelete()
        }
    }
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier.fillMaxSize().padding(horizontal = Spacing.medium),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text("Delete", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelLarge)
            }
        },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen)
                .testTag(Ids.taskRow(task.id))
                .padding(horizontal = Spacing.medium, vertical = Spacing.medium),
            horizontalArrangement = Arrangement.spacedBy(Spacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (task.done) {
                Text(
                    "✓",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.testTag(Ids.taskRowDone(task.id)),
                )
            }
            Text(task.title, style = MaterialTheme.typography.bodyLarge)
        }
    }
}

@Composable
private fun EmptyTasks(filter: StatusFilter) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(Spacing.large)
            // One element, so the identifier matches once.
            .semantics(mergeDescendants = true) {}
            .testTag(Ids.TASKS_EMPTY),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            if (filter == StatusFilter.All) "No tasks yet" else "No ${filter.title.lowercase()} tasks",
            style = MaterialTheme.typography.titleMedium,
        )
        Text("Tap Add to make one.", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun LoadFailure(message: String, retry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(Spacing.large),
        verticalArrangement = Arrangement.spacedBy(Spacing.medium, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            message,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.testTag(Ids.TASKS_ERROR),
        )
        Button(onClick = retry, modifier = Modifier.testTag(Ids.TASKS_RETRY)) {
            Text("Try Again")
        }
    }
}
