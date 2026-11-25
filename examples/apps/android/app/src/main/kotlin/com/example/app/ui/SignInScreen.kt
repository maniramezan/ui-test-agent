package com.example.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import com.example.app.Ids
import com.example.app.SessionModel
import kotlinx.coroutines.launch

@Composable
fun SignInScreen(session: SessionModel) {
    var email by rememberSaveable { mutableStateOf("") }
    val password = rememberTextFieldState()
    val scope = rememberCoroutineScope()
    val busy = session.phase is SessionModel.Phase.SigningIn

    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(Spacing.medium),
        verticalArrangement = Arrangement.spacedBy(Spacing.small),
    ) {
        Text("Sign in", style = MaterialTheme.typography.headlineMedium)
        OutlinedTextField(
            value = email,
            onValueChange = { email = it },
            label = { Text("Email") },
            singleLine = true,
            isError = session.fieldErrors["email"] != null,
            supportingText = session.fieldErrors["email"]?.let { problem -> { Text(problem) } },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            modifier = Modifier.fillMaxWidth().testTag(Ids.SIGN_IN_EMAIL),
        )
        OutlinedSecureTextField(
            state = password,
            label = { Text("Password") },
            isError = session.fieldErrors["password"] != null,
            supportingText = session.fieldErrors["password"]?.let { problem -> { Text(problem) } },
            modifier = Modifier.fillMaxWidth().testTag(Ids.SIGN_IN_PASSWORD),
        )
        session.message?.let { message ->
            Text(
                message,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.testTag(Ids.SIGN_IN_ERROR),
            )
        }
        Button(
            onClick = { scope.launch { session.signIn(email, password.text.toString()) } },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth().testTag(Ids.SIGN_IN_SUBMIT),
        ) {
            Text(if (busy) "Signing in…" else "Sign in")
        }
    }
}
