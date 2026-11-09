// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraConstrainedHighSpeedCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import android.util.Range
import android.util.Size
import android.view.Surface
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Asks the camera for 240fps and times every frame it actually delivers.
 *
 * [CameraProbe] reports what the phone ADVERTISES. That is not enough: one
 * developer reports Samsung phones that advertise 120/240fps to apps and then
 * fail to deliver it. The only proof is to open a high-speed session, record a
 * few seconds, and read the sensor's own timestamp on every frame. The clip is
 * saved to the Gallery (Movies/SwingLab) and inspected afterwards with
 * [ClipInspector], which shows what a file recorded this way looks like — the
 * same question the Samsung camera app's own slow-motion files raise.
 *
 * Every step reports its failure as text rather than crashing: a failure here
 * IS the answer to the question, and the owner needs to be able to copy it.
 */
class HighSpeedTrial(private val context: Context) {

    data class Plan(val cameraId: String, val size: Size, val fpsRange: Range<Int>, val highSpeed: Boolean) {
        val fps: Int get() = fpsRange.upper
        override fun toString() =
            "camera $cameraId, ${size.width}x${size.height}, fps range $fpsRange, " +
                if (highSpeed) "constrained high-speed session" else "normal session (no high-speed mode advertised)"
    }

    /**
     * The best thing to ask for: 1920x1080 at 240 if any back camera offers it,
     * else the largest size at the highest rate on offer, else a normal session
     * at its fastest AE range — which at least says what the ceiling is.
     */
    fun plan(): Pair<Plan?, String> {
        val mgr = context.getSystemService(CameraManager::class.java)
        val ids = runCatching { mgr.cameraIdList.toList() }.getOrElse { return null to "Cannot list cameras: $it" }
        var best: Plan? = null
        fun score(p: Plan): Long =
            (if (p.size.width >= 1920 && p.size.height >= 1080) 1L shl 40 else 0L) +
                p.fps.toLong() * 100_000_000L + p.size.width.toLong() * p.size.height
        for (id in ids) {
            val c = runCatching { mgr.getCameraCharacteristics(id) }.getOrNull() ?: continue
            if (c.get(CameraCharacteristics.LENS_FACING) != CameraMetadata.LENS_FACING_BACK) continue
            val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
            val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: continue
            if (CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO in caps) {
                for (s in map.highSpeedVideoSizes) {
                    val ranges = map.getHighSpeedVideoFpsRangesFor(s)
                    // A FIXED range (240, 240) is the recording range; (30, 240)
                    // is for preview. Prefer fixed at the highest rate.
                    val r = ranges.filter { it.lower == it.upper }.maxByOrNull { it.upper }
                        ?: ranges.maxByOrNull { it.upper } ?: continue
                    val p = Plan(id, s, r, highSpeed = true)
                    if (best.let { it == null || score(p) > score(it) }) best = p
                }
            }
        }
        if (best != null) return best to "Trying the best advertised high-speed mode."
        // No high-speed mode: report the normal-session ceiling instead.
        for (id in ids) {
            val c = runCatching { mgr.getCameraCharacteristics(id) }.getOrNull() ?: continue
            if (c.get(CameraCharacteristics.LENS_FACING) != CameraMetadata.LENS_FACING_BACK) continue
            val r = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.filter { it.lower == it.upper }?.maxByOrNull { it.upper } ?: continue
            return Plan(id, Size(1920, 1080), r, highSpeed = false) to
                "No back camera advertises high-speed video; trying the fastest normal mode to show the ceiling."
        }
        return null to "No usable back camera found."
    }

    @SuppressLint("MissingPermission") // the caller asks for CAMERA first
    suspend fun run(plan: Plan, preview: Surface?, seconds: Double = 3.0): Report {
        val r = Report()
        r.line("SwingLab device check — ${plan.fps}fps recording trial")
        r.line("Device: ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}")
        r.line("Asked for: $plan")
        r.line("Preview surface: ${if (preview != null) "yes" else "none (recorder only)"}")

        val thread = HandlerThread("devcheck-camera").apply { start() }
        val handler = Handler(thread.looper)
        val executor = Executor { handler.post(it) }
        val mgr = context.getSystemService(CameraManager::class.java)

        val timestamps = ArrayList<Long>()
        val exposures = ArrayList<Long>()
        val durations = ArrayList<Long>()
        val isos = ArrayList<Int>()
        var failures = 0
        val lock = Any()

        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var recorder: MediaRecorder? = null
        var uri: Uri? = null
        var recorded = false
        try {
            uri = newGalleryVideo(plan)
            val pfd = context.contentResolver.openFileDescriptor(uri, "w")
                ?: throw IllegalStateException("could not open the Gallery file for writing")
            recorder = (if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()).apply {
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(pfd.fileDescriptor)
                setVideoEncodingBitRate(if (plan.fps >= 200) 60_000_000 else 20_000_000)
                setVideoFrameRate(plan.fps)
                setVideoSize(plan.size.width, plan.size.height)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                prepare()
            }
            pfd.close()
            val surfaces = listOfNotNull(preview, recorder.surface)

            device = suspendCancellableCoroutine { cont ->
                mgr.openCamera(plan.cameraId, object : CameraDevice.StateCallback() {
                    override fun onOpened(d: CameraDevice) { if (cont.isActive) cont.resume(d) else d.close() }
                    override fun onDisconnected(d: CameraDevice) {
                        d.close(); if (cont.isActive) cont.resumeWithException(IllegalStateException("camera disconnected"))
                    }
                    override fun onError(d: CameraDevice, error: Int) {
                        d.close(); if (cont.isActive) cont.resumeWithException(IllegalStateException("camera error $error"))
                    }
                }, handler)
            }
            r.line("Camera opened.")

            val type = if (plan.highSpeed) SessionConfiguration.SESSION_HIGH_SPEED else SessionConfiguration.SESSION_REGULAR
            val configured: CameraCaptureSession = suspendCancellableCoroutine { cont ->
                val cfg = SessionConfiguration(type, surfaces.map { OutputConfiguration(it) }, executor,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) { if (cont.isActive) cont.resume(s) }
                        override fun onConfigureFailed(s: CameraCaptureSession) {
                            if (cont.isActive) cont.resumeWithException(IllegalStateException(
                                "the camera REFUSED the session configuration (this is the failure mode reported for phones that advertise high speed but do not deliver it)"))
                        }
                    })
                device!!.createCaptureSession(cfg)
            }
            session = configured
            r.line("Session configured: ${configured.javaClass.simpleName}")

            val callback = object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(s: CameraCaptureSession, req: CaptureRequest, res: TotalCaptureResult) {
                    synchronized(lock) {
                        res.get(CaptureResult.SENSOR_TIMESTAMP)?.let { timestamps.add(it) }
                        res.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { exposures.add(it) }
                        res.get(CaptureResult.SENSOR_FRAME_DURATION)?.let { durations.add(it) }
                        res.get(CaptureResult.SENSOR_SENSITIVITY)?.let { isos.add(it) }
                    }
                }
                override fun onCaptureFailed(s: CameraCaptureSession, req: CaptureRequest, f: android.hardware.camera2.CaptureFailure) {
                    synchronized(lock) { failures++ }
                }
            }
            val builder = device!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                surfaces.forEach { addTarget(it) }
                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, plan.fpsRange)
            }
            val s = configured
            if (plan.highSpeed) {
                val hs = s as? CameraConstrainedHighSpeedCaptureSession
                    ?: throw IllegalStateException("asked for a high-speed session and got ${s.javaClass.simpleName}")
                val burst = hs.createHighSpeedRequestList(builder.build())
                r.line("High-speed burst of ${burst.size} requests per batch.")
                hs.setRepeatingBurst(burst, callback, handler)
            } else {
                s.setRepeatingRequest(builder.build(), callback, handler)
            }
            recorder.start()
            recorded = true
            delay((seconds * 1000).toLong())
            runCatching { s.stopRepeating() }
            runCatching { recorder.stop() }.onFailure { r.line("Recorder stop failed: $it"); recorded = false }
        } catch (e: Exception) {
            r.line("FAILED: ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            runCatching { session?.close() }
            runCatching { device?.close() }
            runCatching { recorder?.release() }
            thread.quitSafely()
            uri?.let { finishGalleryVideo(it, keep = recorded) }
        }

        val ts: List<Long>; val ex: List<Long>; val du: List<Long>; val iso: List<Int>; val failed: Int
        synchronized(lock) { ts = timestamps.toList(); ex = exposures.toList(); du = durations.toList(); iso = isos.toList(); failed = failures }

        r.section("Frames the camera delivered (sensor timestamps)")
        val stats = IntervalStats.of(ts.map { it / 1000 })
        if (stats == null) r.line("No frames were delivered.") else stats.describe(r, "Delivered")
        r.line("Failed captures: $failed")
        if (ex.isNotEmpty()) {
            val e = ex.sorted()[ex.size / 2]
            r.line("Exposure (auto) median ${num(e / 1e6, 3)} ms = 1/${num(1e9 / e, 0)} s, range ${num(ex.min() / 1e6, 3)}-${num(ex.max() / 1e6, 3)} ms")
        }
        if (du.isNotEmpty()) r.line("Frame duration median ${num(du.sorted()[du.size / 2] / 1e6, 3)} ms")
        if (iso.isNotEmpty()) r.line("ISO median ${iso.sorted()[iso.size / 2]}")

        r.section("Verdict")
        r.line(when {
            stats == null -> "No frames: ${plan.fps}fps is not usable by a third-party app on this phone in this mode."
            stats.fps >= 0.9 * plan.fps && stats.longGaps <= stats.frames / 50 ->
                "${plan.fps}fps WORKS for a third-party app on this phone: delivered ${num(stats.fps, 1)} fps with ${stats.longGaps} long gaps over ${stats.frames} frames."
            else ->
                "Asked for ${plan.fps}fps, got ${num(stats.fps, 1)} fps with ${stats.longGaps} long gaps over ${stats.frames} frames — NOT a clean ${plan.fps}fps."
        })

        if (recorded && uri != null) {
            r.line()
            r.line("The recorded clip, read back from the Gallery:")
            r.line(ClipInspector.run(context, uri, "the trial clip").toString())
        }
        return r
    }

    private fun newGalleryVideo(plan: Plan): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, "swinglab_trial_${plan.fps}fps_${System.currentTimeMillis() / 1000}.mp4")
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/SwingLab")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        return context.contentResolver.insert(
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: throw IllegalStateException("could not create a Gallery entry")
    }

    private fun finishGalleryVideo(uri: Uri, keep: Boolean) {
        runCatching {
            if (keep) {
                context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            } else {
                context.contentResolver.delete(uri, null, null)
            }
        }
    }
}
