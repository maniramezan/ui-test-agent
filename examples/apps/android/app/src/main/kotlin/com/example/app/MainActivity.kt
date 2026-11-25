package com.example.app

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.lifecycle.ViewModel
import com.example.app.ui.ExampleTheme
import com.example.app.ui.RootScreen

/** Keeps the session across configuration changes; a new process starts signed out. */
class AppState : ViewModel() {
    private var held: Pair<LaunchSettings, SessionModel>? = null

    fun start(settings: () -> LaunchSettings): Pair<LaunchSettings, SessionModel> {
        held?.let { return it }
        val read = settings()
        val created = read to SessionModel(ApiClient(read))
        held = created
        return created
    }
}

class MainActivity : ComponentActivity() {
    private val state: AppState by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val (settings, session) = state.start { LaunchSettings.from(intent) }
        Log.i(
            TAG,
            "Launched mock=${settings.mockSession != null} testSession=${settings.testSession != null} " +
                "faults=${settings.faults.map { it.key }.sorted()}",
        )
        setContent {
            ExampleTheme {
                RootScreen(settings, session)
            }
        }
    }

    private companion object {
        const val TAG = "ExampleApp.MainActivity"
    }
}
