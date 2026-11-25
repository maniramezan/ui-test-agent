package com.example.app

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class User(val id: String, val name: String, val email: String)

@Serializable
data class SessionPayload(val token: String, val user: User)

@Serializable
data class TaskItem(
    val id: String,
    val title: String,
    val notes: String? = null,
    val done: Boolean,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class TaskPage(
    val items: List<TaskItem>,
    val page: Int,
    val limit: Int,
    val total: Int,
    @SerialName("has_more") val hasMore: Boolean,
)

@Serializable
data class DeletedCount(val deleted: Int)

@Serializable
data class ErrorBody(val error: String, val message: String, val fields: Map<String, String>? = null)

enum class StatusFilter(val key: String, val title: String) {
    All("all", "All"),
    Open("open", "Open"),
    Done("done", "Done"),
}

/** Why a call failed, in terms a screen can act on. */
sealed class ApiError(val userMessage: String) : Exception(userMessage) {
    /** The session is over and could not be renewed; the user must sign in again. */
    data object SignedOut : ApiError("Your session ended. Sign in again.") {
        private fun readResolve(): Any = SignedOut
    }

    data object AccountDisabled : ApiError("This account is disabled.") {
        private fun readResolve(): Any = AccountDisabled
    }

    /** The server refused the request and said why. */
    data class Rejected(
        val status: Int,
        val code: String,
        val text: String,
        val fields: Map<String, String>,
    ) : ApiError(text)

    data class Server(val status: Int) : ApiError("The server had a problem ($status). Try again.")

    data object Unreachable : ApiError("Can't reach the server. Check your connection and try again.") {
        private fun readResolve(): Any = Unreachable
    }

    /** The response was not what the API promises. */
    data object Malformed : ApiError("The server sent something unexpected. Try again.") {
        private fun readResolve(): Any = Malformed
    }

    /** True when the app can no longer act for this user. */
    val endsSession: Boolean
        get() = this is SignedOut || this is AccountDisabled
}
