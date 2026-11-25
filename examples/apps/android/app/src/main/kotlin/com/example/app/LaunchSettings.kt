package com.example.app

import android.content.Intent
import java.net.URI

/**
 * A bug the app can be launched with (`APP_FAULT`, comma-separated), so a test suite can be
 * measured by whether it notices.
 */
enum class Fault(val key: String) {
    /** A pull-to-refresh sends the list request without its `Authorization` header. */
    DropAuthorizationOnRefresh("drop-authorization-on-refresh"),

    /** No request carries the session cookie. */
    OmitCookie("omit-cookie"),

    /** The list request always asks for `status=all`, whatever filter is shown. */
    IgnoreFilter("ignore-filter"),

    /** Delete All deletes without asking. */
    SkipDeleteConfirmation("skip-delete-confirmation"),
}

/**
 * What the launch intent's extras tell the app: where its backend is and, under test, which mock
 * session or backend test session it belongs to.
 */
data class LaunchSettings(
    val baseUrl: String,
    val mockSession: String?,
    /**
     * Under test against the real backend: the data set this launch reads and writes, so tests
     * running at the same time don't see each other's changes.
     */
    val testSession: String?,
    val faults: Set<Fault>,
    /** Set when the launch can't be trusted, and shown instead of the app. */
    val problem: String?,
) {
    companion object {
        const val BASE_URL_KEY = "APP_BASE_URL"
        const val MOCK_BASE_URL_KEY = "APP_MOCK_BASE_URL"
        const val MOCK_SESSION_KEY = "APP_MOCK_SESSION"
        const val TEST_SESSION_KEY = "APP_TEST_SESSION"
        const val FAULT_KEY = "APP_FAULT"
        const val MOCK_SESSION_HEADER = "X-Mock-Session"
        const val TEST_SESSION_HEADER = "X-Test-Session"

        /** The development machine as an emulator reaches it. */
        const val DEFAULT_BASE_URL = "http://10.0.2.2:8081"

        fun from(intent: Intent?): LaunchSettings = from { key -> intent?.getStringExtra(key) }

        fun from(value: (String) -> String?): LaunchSettings {
            val mockBase = value(MOCK_BASE_URL_KEY)?.takeIf { it.isNotEmpty() }
            val session = value(MOCK_SESSION_KEY)?.takeIf { it.isNotEmpty() }
            val raw = mockBase ?: value(BASE_URL_KEY)?.takeIf { it.isNotEmpty() } ?: DEFAULT_BASE_URL
            var problem: String? = null
            if (mockBase != null && session == null) {
                // Without this guard the app would talk to the mock server outside any session,
                // or, in an app with a production default, to its real backend, and every request
                // check would pass on an empty history.
                problem = "$MOCK_BASE_URL_KEY is set but $MOCK_SESSION_KEY is not."
            }
            val parsed = runCatching { URI(raw) }.getOrNull()
            if (parsed?.scheme == null || parsed.host == null) {
                problem = "$raw is not a base URL."
            }
            val faults = (value(FAULT_KEY) ?: "")
                .split(",")
                .mapNotNull { name -> Fault.entries.firstOrNull { it.key == name.trim() } }
                .toSet()
            return LaunchSettings(
                baseUrl = raw.trimEnd('/'),
                mockSession = if (mockBase == null) null else session,
                testSession = value(TEST_SESSION_KEY)?.takeIf { it.isNotEmpty() },
                faults = faults,
                problem = problem,
            )
        }
    }
}
