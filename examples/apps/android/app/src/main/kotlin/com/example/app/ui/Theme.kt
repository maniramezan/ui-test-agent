package com.example.app.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp

/** The spacing every screen draws from. */
object Spacing {
    val small = 8.dp
    val medium = 16.dp
    val large = 24.dp
}

@Composable
fun ExampleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = lightColorScheme(), content = content)
}

/**
 * Publishes test tags below this node as resource ids, which is how UI automation finds them.
 * A dialog or bottom sheet is a window of its own, so its content needs this again.
 */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.exposeTestTags(): Modifier = semantics { testTagsAsResourceId = true }
