// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private val Yellow = Color(0xFFE4F222)

/**
 * Three buttons that answer the two questions the Android port depends on, on
 * the owner's own phone: can an app record 240fps here, and what does a
 * slow-motion file from Samsung's camera actually contain. The output is one
 * plain-text report with Copy and Share, because it gets pasted into a chat.
 */
@Composable
fun DeviceCheckScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var report by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf<String?>(null) }
    var trialPlan by remember { mutableStateOf<HighSpeedTrial.Plan?>(null) }
    var previewSurface by remember { mutableStateOf<Surface?>(null) }

    fun startTrial() {
        val (plan, why) = HighSpeedTrial(context).plan()
        if (plan == null) { report = "Recording trial: $why"; return }
        busy = "Recording ${plan.fps}fps for 3 seconds — point the phone at something moving."
        trialPlan = plan
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startTrial()
        else report = "Camera permission was refused, so the recording trial cannot run. " +
            "Allow it in Settings > Apps > SwingLab > Permissions and try again."
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            busy = "Reading the clip…"
            scope.launch {
                val text = withContext(Dispatchers.IO) {
                    runCatching { ClipInspector.run(context, uri).toString() }.getOrElse { "Clip inspection failed: $it" }
                }
                report = text; busy = null
            }
        }
    }

    // The trial needs the preview surface to exist at the right size first;
    // wait for it briefly, and run recorder-only if it never appears.
    LaunchedEffect(trialPlan) {
        val plan = trialPlan ?: return@LaunchedEffect
        val surface = withTimeoutOrNull(3000) { snapshotFlow { previewSurface }.filterNotNull().first() }
        val text = withContext(Dispatchers.IO) {
            runCatching { HighSpeedTrial(context).run(plan, surface).toString() }.getOrElse { "Recording trial failed: $it" }
        }
        report = text; busy = null; trialPlan = null; previewSurface = null
    }

    Column(
        modifier = Modifier.fillMaxSize().background(Color.Black).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("SwingLab for Android — device check", color = Yellow, fontSize = 20.sp)
        Text("The measuring app is still being ported. These checks find out what this phone can do, so the camera screens are built on facts. Run them, then tap Copy and paste the report into the chat.",
            color = Color.White, fontSize = 13.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val colors = ButtonDefaults.buttonColors(containerColor = Yellow, contentColor = Color.Black)
            Button(enabled = busy == null, colors = colors, onClick = {
                busy = "Reading camera capabilities…"
                scope.launch {
                    val text = withContext(Dispatchers.Default) {
                        runCatching { CameraProbe.run(context).toString() }.getOrElse { "Camera probe failed: $it" }
                    }
                    report = text; busy = null
                }
            }) { Text("1. Camera capabilities") }
            Button(enabled = busy == null, colors = colors, onClick = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startTrial()
                else cameraPermission.launch(Manifest.permission.CAMERA)
            }) { Text("2. Try 240fps (3 s)") }
            Button(enabled = busy == null, colors = colors, onClick = {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
            }) { Text("3. Inspect a slow-mo clip") }
        }
        busy?.let { Text(it, color = Yellow, fontSize = 13.sp) }
        trialPlan?.let { plan ->
            AndroidView(
                modifier = Modifier.size(width = 256.dp, height = 144.dp),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.setFixedSize(plan.size.width, plan.size.height)
                        holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(h: SurfaceHolder) {}
                            override fun surfaceChanged(h: SurfaceHolder, format: Int, w: Int, hgt: Int) {
                                if (w == plan.size.width && hgt == plan.size.height) previewSurface = h.surface
                            }
                            override fun surfaceDestroyed(h: SurfaceHolder) { previewSurface = null }
                        })
                    }
                },
            )
        }
        if (report.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    context.getSystemService(ClipboardManager::class.java)
                        ?.setPrimaryClip(ClipData.newPlainText("SwingLab device check", report))
                }) { Text("Copy report", color = Color.White) }
                OutlinedButton(onClick = {
                    val send = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, report) }
                    context.startActivity(Intent.createChooser(send, "Share the report"))
                }) { Text("Share report", color = Color.White) }
            }
            SelectionContainer(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())) {
                Text(report, color = Color(0xFFDDDDDD), fontFamily = FontFamily.Monospace, fontSize = 11.sp)
            }
        }
    }
}
