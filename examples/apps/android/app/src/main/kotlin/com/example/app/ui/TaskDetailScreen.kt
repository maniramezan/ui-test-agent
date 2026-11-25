package com.example.app.ui

import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import com.example.app.ApiError
import com.example.app.Ids
import com.example.app.SessionModel
import com.example.app.TaskItem
import kotlinx.coroutines.launch

private const val TAG = "ExampleApp.TaskDetail"

/** One task: its title, notes and a Done switch that saves as it is flipped. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailScreen(id: String, session: SessionModel, onChange: (TaskItem) -> Unit, onBack: () -> Unit) {
    var task by remember { mutableStateOf<TaskItem?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun report(error: ApiError, action: String) {
        Log.e(TAG, "Task detail failed feature=task action=$action task=$id", error)
        if (error.endsSession) {
            session.sessionEnded(error)
        } else {
            problem = error.userMessage
        }
    }

    LaunchedEffect(id) {
        Log.i(TAG, "Loading task=$id")
        try {
            task = session.client.task(id)
            Log.i(TAG, "Loaded task=$id")
        } catch (error: ApiError) {
            report(error, "load")
        }
    }
    BackHandler(onBack = onBack)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Task") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(Spacing.medium),
            verticalArrangement = Arrangement.spacedBy(Spacing.medium),
        ) {
            val loaded = task
            if (loaded == null && problem == null) {
                CircularProgressIndicator()
            }
            if (loaded != null) {
                Text(loaded.title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.testTag(Ids.TASK_TITLE))
                loaded.notes?.let { notes ->
                    Text(notes, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.testTag(Ids.TASK_NOTES))
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Done", style = MaterialTheme.typography.bodyLarge)
                    Switch(
                        checked = loaded.done,
                        onCheckedChange = { done ->
                            scope.launch {
                                Log.i(TAG, "Setting done=$done task=$id")
                                try {
                                    val changed = session.client.setDone(done, id)
                                    task = changed
                                    problem = null
                                    onChange(changed)
                                    Log.i(TAG, "Set done=$done task=$id")
                                } catch (error: ApiError) {
                                    report(error, "setDone")
                                }
                            }
                        },
                        modifier = Modifier.testTag(Ids.TASK_DONE),
                    )
                }
            }
            problem?.let { message ->
                Text(
                    message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.testTag(Ids.TASK_ERROR),
                )
            }
        }
    }
}
