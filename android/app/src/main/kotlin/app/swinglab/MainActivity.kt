// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.swinglab.core.Core

/**
 * Placeholder entry point while the port is under way.
 *
 * It exists so the very first build is installable and proves the whole chain —
 * signing, sideloading, the core module linking — before any screen is worth
 * having. It says plainly that it measures nothing yet.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Column(
                    modifier = Modifier.fillMaxSize().background(Color.Black).padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("SwingLab for Android", color = Color(0xFFE4F222),
                         style = MaterialTheme.typography.headlineMedium)
                    Text("Port in progress — this build measures nothing yet.",
                         color = Color.White, modifier = Modifier.padding(top = 12.dp))
                    Text("Measurement core: port of ${Core.SOURCE_OF_TRUTH}",
                         color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
                }
            }
        }
    }
}
