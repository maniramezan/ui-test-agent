package com.example.app

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Who is signed in, and why the sign-in screen is showing when nobody is. */
class SessionModel(val client: ApiClient) {
    sealed interface Phase {
        data object SignedOut : Phase

        data object SigningIn : Phase

        data class SignedIn(val user: User) : Phase
    }

    var phase: Phase by mutableStateOf(Phase.SignedOut)
        private set

    var message: String? by mutableStateOf(null)
        private set

    var fieldErrors: Map<String, String> by mutableStateOf(emptyMap())
        private set

    suspend fun signIn(email: String, password: String) {
        phase = Phase.SigningIn
        message = null
        fieldErrors = emptyMap()
        Log.i(TAG, "Signing in")
        try {
            val user = client.signIn(email, password)
            Log.i(TAG, "Signed in user=${user.id}")
            phase = Phase.SignedIn(user)
        } catch (error: ApiError) {
            Log.e(TAG, "Sign-in failed feature=signIn action=signIn", error)
            if (error is ApiError.Rejected) {
                fieldErrors = error.fields
            }
            message = error.userMessage
            phase = Phase.SignedOut
        }
    }

    suspend fun signOut() {
        Log.i(TAG, "Signing out")
        client.signOut()
        Log.i(TAG, "Signed out")
        message = null
        phase = Phase.SignedOut
    }

    /** Called when a signed-in call found the session over. */
    fun sessionEnded(error: ApiError) {
        Log.i(TAG, "Session ended: ${if (error is ApiError.AccountDisabled) "account disabled" else "signed out"}")
        message = error.userMessage
        phase = Phase.SignedOut
    }

    private companion object {
        const val TAG = "ExampleApp.SessionModel"
    }
}
