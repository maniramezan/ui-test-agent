package com.example.app

import android.util.Log
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Keeps cookies for the life of the process, so every launch starts signed out. */
private class MemoryCookieJar : CookieJar {
    private val cookies = mutableMapOf<String, Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { this.cookies[it.name] = it }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> = cookies.values.filter { it.matches(url) }

    @Synchronized
    fun clear() {
        cookies.clear()
    }
}

/**
 * Talks to the API in `examples/openapi.yaml`. It keeps the bearer token and the session cookie in
 * memory. A 401 on a signed-in call is answered by one token refresh and one retry. Calls that
 * fail together share one refresh, and once the session is over every call fails with the reason
 * it ended.
 */
class ApiClient(private val settings: LaunchSettings) {
    private class Reply(val status: Int, val body: String)

    private val json = Json { ignoreUnknownKeys = true }
    private val cookies = MemoryCookieJar()
    private val http = OkHttpClient.Builder()
        .cookieJar(if (Fault.OmitCookie in settings.faults) CookieJar.NO_COOKIES else cookies)
        .callTimeout(15, TimeUnit.SECONDS)
        .build()
    private val refreshLock = Mutex()

    @Volatile private var token: String? = null

    /** Why the session ended, until the next sign-in. */
    @Volatile private var ended: ApiError? = null

    // Session

    suspend fun signIn(email: String, password: String): User {
        val body = buildJsonObject {
            put("email", email)
            put("password", password)
        }
        val payload: SessionPayload = decode(send("POST", "/v1/session", body = body, authorized = false))
        token = payload.token
        ended = null
        return payload.user
    }

    suspend fun signOut() {
        try {
            send("DELETE", "/v1/session")
        } catch (error: ApiError) {
            Log.e(TAG, "Sign-out call failed action=signOut", error)
        }
        forgetSession(ApiError.SignedOut)
    }

    // Tasks

    suspend fun tasks(status: StatusFilter, page: Int, refreshing: Boolean): TaskPage {
        val sent = if (Fault.IgnoreFilter in settings.faults) StatusFilter.All else status
        return decode(
            send(
                "GET",
                "/v1/tasks",
                query = listOf("status" to sent.key, "page" to page.toString(), "limit" to PAGE_SIZE.toString()),
                dropAuthorization = refreshing && Fault.DropAuthorizationOnRefresh in settings.faults,
            ),
        )
    }

    suspend fun task(id: String): TaskItem = decode(send("GET", "/v1/tasks/$id"))

    suspend fun createTask(title: String, notes: String?): TaskItem {
        val body = buildJsonObject {
            put("title", title)
            if (notes != null) {
                put("notes", notes)
            }
        }
        return decode(send("POST", "/v1/tasks", body = body))
    }

    suspend fun setDone(done: Boolean, id: String): TaskItem =
        decode(send("PATCH", "/v1/tasks/$id", body = buildJsonObject { put("done", done) }))

    suspend fun deleteTask(id: String) {
        send("DELETE", "/v1/tasks/$id")
    }

    suspend fun deleteAllTasks(): Int = decode<DeletedCount>(send("DELETE", "/v1/tasks")).deleted

    // Transport

    private inline fun <reified T> decode(body: String): T =
        try {
            json.decodeFromString<T>(body)
        } catch (error: SerializationException) {
            Log.e(TAG, "Unreadable reply type=${T::class.simpleName}", error)
            throw ApiError.Malformed
        } catch (error: IllegalArgumentException) {
            Log.e(TAG, "Unreadable reply type=${T::class.simpleName}", error)
            throw ApiError.Malformed
        }

    private suspend fun send(
        method: String,
        path: String,
        query: List<Pair<String, String>> = emptyList(),
        body: JsonObject? = null,
        authorized: Boolean = true,
        dropAuthorization: Boolean = false,
    ): String {
        if (authorized) {
            ended?.let { throw it }
        }
        val used = token
        val first = perform(method, path, query, body, authorized && !dropAuthorization)
        if (first.status != 401 || !authorized) {
            return checked(first)
        }
        Log.i(TAG, "401 on $method $path; refreshing the token")
        refreshToken(stale = used)
        val second = perform(method, path, query, body, authorized = true)
        if (second.status == 401) {
            forgetSession(ApiError.SignedOut)
            throw ApiError.SignedOut
        }
        return checked(second)
    }

    /**
     * Refreshes the token once for every call waiting on it. A second refresh after the first one
     * ended the session would go out without its cookie and report the wrong reason.
     */
    private suspend fun refreshToken(stale: String?) {
        refreshLock.withLock {
            ended?.let { throw it }
            if (token != null && token != stale) {
                return
            }
            val reply = perform("POST", "/v1/session/refresh", emptyList(), null, authorized = false)
            when (reply.status) {
                in 200..299 -> {
                    token = decode<SessionPayload>(reply.body).token
                    Log.i(TAG, "Token refreshed")
                }
                403 -> {
                    Log.i(TAG, "Refresh refused: account disabled")
                    forgetSession(ApiError.AccountDisabled)
                    throw ApiError.AccountDisabled
                }
                401 -> {
                    Log.i(TAG, "Refresh refused: session ended")
                    forgetSession(ApiError.SignedOut)
                    throw ApiError.SignedOut
                }
                else -> throw ApiError.Server(reply.status)
            }
        }
    }

    private fun forgetSession(reason: ApiError) {
        if (ended == null) {
            ended = reason
        }
        token = null
        cookies.clear()
    }

    private suspend fun perform(
        method: String,
        path: String,
        query: List<Pair<String, String>>,
        body: JsonObject?,
        authorized: Boolean,
    ): Reply {
        val base = (settings.baseUrl + path).toHttpUrlOrNull() ?: throw ApiError.Unreachable
        val url = base.newBuilder().apply { query.forEach { (name, value) -> addQueryParameter(name, value) } }.build()
        val request = Request.Builder().url(url).header("Accept", "application/json").apply {
            settings.mockSession?.let { header(LaunchSettings.MOCK_SESSION_HEADER, it) }
            settings.testSession?.let { header(LaunchSettings.TEST_SESSION_HEADER, it) }
            val bearer = token
            if (authorized && bearer != null) {
                header("Authorization", "Bearer $bearer")
            }
            // OkHttp refuses a POST without a body, and the refresh call has none.
            val needsBody = method == "POST" || method == "PUT" || method == "PATCH"
            method(method, body?.toString()?.toRequestBody(JSON_TYPE) ?: if (needsBody) "".toRequestBody(null) else null)
        }.build()
        Log.d(TAG, "$method $path")
        return withContext(Dispatchers.IO) {
            try {
                http.newCall(request).execute().use { response ->
                    Log.d(TAG, "$method $path answered ${response.code}")
                    Reply(response.code, response.body.string())
                }
            } catch (error: IOException) {
                Log.e(TAG, "Request failed request=$method $path", error)
                throw ApiError.Unreachable
            }
        }
    }

    private fun checked(reply: Reply): String {
        if (reply.status in 200..299) {
            return reply.body
        }
        if (reply.status >= 500) {
            throw ApiError.Server(reply.status)
        }
        val error = runCatching { json.decodeFromString<ErrorBody>(reply.body) }.getOrNull()
            ?: throw ApiError.Server(reply.status)
        if (reply.status == 403 && error.error == "account_disabled") {
            throw ApiError.AccountDisabled
        }
        throw ApiError.Rejected(reply.status, error.error, error.message, error.fields ?: emptyMap())
    }

    companion object {
        const val PAGE_SIZE = 20
        private const val TAG = "ExampleApp.ApiClient"
        private val JSON_TYPE = "application/json".toMediaType()
    }
}
