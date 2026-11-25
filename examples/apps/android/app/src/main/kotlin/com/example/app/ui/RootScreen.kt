package com.example.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.example.app.Ids
import com.example.app.LaunchSettings
import com.example.app.SessionModel

@Composable
fun RootScreen(settings: LaunchSettings, session: SessionModel) {
    Surface(modifier = Modifier.fillMaxSize().exposeTestTags()) {
        val problem = settings.problem
        val phase = session.phase
        when {
            problem != null -> SessionGuard(problem)
            phase is SessionModel.Phase.SignedIn ->
                key(phase.user.id) {
                    TasksHome(session, settings.faults)
                }
            else -> SignInScreen(session)
        }
    }
}

/**
 * Replaces the whole app when the launch settings can't be trusted, so a misconfigured test run
 * fails on its first step instead of quietly talking to the wrong backend.
 */
@Composable
private fun SessionGuard(problem: String) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(Spacing.large)
            // One element, so the identifier matches once.
            .semantics(mergeDescendants = true) {}
            .testTag(Ids.SESSION_GUARD_MESSAGE),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Can't start", style = MaterialTheme.typography.titleLarge)
        Text(problem, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
    }
}
