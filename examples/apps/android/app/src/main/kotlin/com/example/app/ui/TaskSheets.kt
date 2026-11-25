package com.example.app.ui

import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import com.example.app.ApiError
import com.example.app.Ids
import com.example.app.SessionModel
import com.example.app.StatusFilter
import com.example.app.TaskItem
import kotlinx.coroutines.launch

/** Picks the list's filter. Choosing an option applies it and closes the sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilterSheet(current: StatusFilter, onPick: (StatusFilter) -> Unit, onClose: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onClose) {
        Column(modifier = Modifier.fillMaxWidth().exposeTestTags().padding(bottom = Spacing.large)) {
            Text(
                "Show",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = Spacing.medium, vertical = Spacing.small),
            )
            StatusFilter.entries.forEach { option ->
                FilterOption(option = option, selected = option == current) {
                    onPick(option)
                    onClose()
                }
            }
            TextButton(
                onClick = onClose,
                modifier = Modifier.padding(horizontal = Spacing.small).testTag(Ids.FILTER_CLOSE),
            ) {
                Text("Close")
            }
        }
    }
}

@Composable
private fun FilterOption(option: StatusFilter, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { stateDescription = if (selected) "Selected" else "" }
            .testTag(Ids.filter(option))
            .padding(horizontal = Spacing.medium, vertical = Spacing.medium),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(option.title, style = MaterialTheme.typography.bodyLarge)
        if (selected) {
            Text("✓", style = MaterialTheme.typography.bodyLarge)
        }
    }
}

private const val TAG = "ExampleApp.NewTask"

/** The form for a new task. A validation problem from the server shows under the title field. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewTaskScreen(session: SessionModel, onCreate: (TaskItem) -> Unit, onClose: () -> Unit) {
    var title by rememberSaveable { mutableStateOf("") }
    var notes by rememberSaveable { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var titleProblem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    BackHandler(onBack = onClose)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Task") },
                navigationIcon = {
                    TextButton(onClick = onClose, modifier = Modifier.testTag(Ids.NEW_TASK_CANCEL)) { Text("Cancel") }
                },
                actions = {
                    TextButton(
                        enabled = !saving,
                        onClick = {
                            scope.launch {
                                saving = true
                                problem = null
                                titleProblem = null
                                Log.i(TAG, "Creating a task")
                                try {
                                    val created = session.client.createTask(title, notes.ifBlank { null })
                                    Log.i(TAG, "Created task=${created.id}")
                                    onCreate(created)
                                    onClose()
                                } catch (error: ApiError) {
                                    Log.e(TAG, "Creating a task failed feature=newTask action=save", error)
                                    if (error.endsSession) {
                                        session.sessionEnded(error)
                                    } else {
                                        titleProblem = (error as? ApiError.Rejected)?.fields?.get("title")
                                        problem = error.userMessage
                                    }
                                }
                                saving = false
                            }
                        },
                        modifier = Modifier.testTag(Ids.NEW_TASK_SAVE),
                    ) {
                        Text("Save")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(Spacing.medium),
            verticalArrangement = Arrangement.spacedBy(Spacing.small),
        ) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Title") },
                singleLine = true,
                isError = titleProblem != null,
                supportingText = titleProblem?.let { text -> { Text(text) } },
                modifier = Modifier.fillMaxWidth().testTag(Ids.NEW_TASK_TITLE),
            )
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes") },
                modifier = Modifier.fillMaxWidth().testTag(Ids.NEW_TASK_NOTES),
            )
            problem?.let { message ->
                Text(
                    message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.testTag(Ids.NEW_TASK_ERROR),
                )
            }
        }
    }
}
