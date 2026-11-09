// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.media.MediaCodecList
import android.media.MediaRecorder
import android.os.Build
import android.util.Size
import kotlin.math.atan

/**
 * Everything the camera says about itself, without opening it.
 *
 * The question this exists to answer is whether an app that is not Samsung's
 * own camera can record 240fps on this phone at all. Samsung has a history of
 * keeping high frame rates for its own app, and what the phone ADVERTISES here
 * is necessary but not sufficient — [HighSpeedTrial] checks whether it
 * delivers. Also reported because later decisions hang on them: the lens's
 * real field of view (every pixel figure in the 3-4 m analysis scales with
 * it), the shortest exposure (whether a shutter cap is possible) and whether
 * the encoder can keep up.
 */
object CameraProbe {

    fun run(context: Context): Report {
        val r = Report()
        r.line("SwingLab device check — camera capabilities")
        r.line("Device: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}), board ${Build.BOARD}, hardware ${Build.HARDWARE}")
        r.line("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), build ${Build.DISPLAY}")
        if (Build.VERSION.SDK_INT >= 31) r.line("SoC: ${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")

        val mgr = context.getSystemService(CameraManager::class.java)
        val ids = try { mgr.cameraIdList.toList() } catch (e: Exception) {
            r.line("Could not list cameras: $e"); return r
        }
        r.line("Camera ids: ${ids.joinToString()}")

        val seen = mutableSetOf<String>()
        var best: Pair<Int, String> = 0 to NO_HIGH_SPEED
        fun probe(id: String, note: String) {
            if (!seen.add(id)) return
            try {
                val found = describe(r, mgr, id, note)
                if (found != null && found.first > best.first) best = found
            } catch (e: Exception) {
                r.section("Camera $id $note"); r.line("Could not read: $e")
            }
        }
        for (id in ids) {
            probe(id, "")
            // Logical multi-camera: the lenses behind it may only be reachable
            // as physical ids, and one of them may be where the high-speed
            // modes live.
            val c = try { mgr.getCameraCharacteristics(id) } catch (e: Exception) { null }
            if (c != null) {
                for (p in c.physicalCameraIds) probe(p, "(physical, behind $id)")
            }
        }

        encoders(r)
        r.section("Verdict")
        r.line(best.second)
        return r
    }

    private const val NO_HIGH_SPEED =
        "No back camera advertises constrained high-speed video: a third-party app cannot record 120/240fps on this phone."

    /**
     * Prints one camera and returns how good its high-speed offer is (higher
     * is better) with the sentence to say about it, or null for no offer.
     *
     * Ranked rather than "last one wins". The first version kept a single
     * verdict that each back camera overwrote in turn, so on the S21+ the
     * telephoto or ultra-wide, probed last, reported "no 240fps" for a phone
     * whose main camera then recorded a clean 240fps.
     */
    private fun describe(r: Report, mgr: CameraManager, id: String, note: String): Pair<Int, String>? {
        val c = mgr.getCameraCharacteristics(id)
        val facing = when (c.get(CameraCharacteristics.LENS_FACING)) {
            CameraMetadata.LENS_FACING_BACK -> "back"
            CameraMetadata.LENS_FACING_FRONT -> "front"
            CameraMetadata.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }
        r.section("Camera $id $note — $facing")
        val level = when (c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
            else -> "?"
        }
        r.line("Hardware level: $level")
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val highSpeed = CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO in caps
        r.line("Capabilities: ${caps.joinToString { capName(it) }}")

        // Optics: the field of view every pixel figure scales with.
        val focals = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val sensor = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixels = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        if (focals != null && sensor != null) {
            for (f in focals) {
                // Horizontal FOV across the FULL sensor width. A 16:9 video
                // crops the sensor top and bottom, not the sides, so this is
                // the video's horizontal FOV too — unless stabilisation crops
                // further, which is normally off at high frame rates.
                val hfov = Math.toDegrees(2 * atan(sensor.width / (2.0 * f)))
                val vfov = Math.toDegrees(2 * atan(sensor.height / (2.0 * f)))
                r.line("Focal length ${num(f)} mm on a ${num(sensor.width)} x ${num(sensor.height)} mm sensor: " +
                    "horizontal FOV ${num(hfov, 1)} deg (full-sensor vertical ${num(vfov, 1)} deg)")
            }
        }
        r.line("Pixel array $pixels, active area $active, sensor orientation ${c.get(CameraCharacteristics.SENSOR_ORIENTATION)} deg")

        // Exposure: whether a short shutter can be set at all.
        c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)?.let {
            r.line("Exposure time range: ${num(it.lower / 1e6, 4)} ms (1/${num(1e9 / it.lower, 0)} s) to ${num(it.upper / 1e6, 1)} ms")
        }
        c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.let { r.line("ISO range: ${it.lower}-${it.upper}") }
        val manualSensor = CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR in caps
        r.line("Manual exposure (MANUAL_SENSOR): ${if (manualSensor) "yes" else "no"}")
        r.line("Timestamp source: ${when (c.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)) {
            CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "REALTIME (comparable with the audio clock)"
            else -> "UNKNOWN (only differences between frames mean anything)"
        }}")
        r.line("AE target fps ranges (normal sessions): " +
            (c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.joinToString() ?: "none"))

        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: run {
            r.line("No stream configuration map."); return null
        }
        // The fastest a NORMAL session can run at 1080p.
        val fhd = Size(1920, 1080)
        for ((label, d) in listOf(
            "YUV" to runCatching { map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, fhd) }.getOrNull(),
            "video encoder" to runCatching { map.getOutputMinFrameDuration(MediaRecorder::class.java, fhd) }.getOrNull(),
        )) {
            if (d != null && d > 0) r.line("Normal session, 1920x1080 $label: min frame duration ${num(d / 1e6, 3)} ms = max ${num(1e9 / d, 1)} fps")
        }

        r.line("CONSTRAINED HIGH-SPEED VIDEO: ${if (highSpeed) "ADVERTISED" else "not advertised"}")
        var offer: Pair<Int, String>? = null
        if (highSpeed) {
            val sizes = map.highSpeedVideoSizes.sortedByDescending { it.width * it.height }
            if (sizes.isEmpty()) r.line("  (advertised, but no sizes listed)")
            var best240fhd = false
            for (s in sizes) {
                val ranges = map.getHighSpeedVideoFpsRangesFor(s)
                r.line("  ${s.width}x${s.height}: ${ranges.joinToString()}")
                if (s.width >= 1920 && s.height >= 1080 && ranges.any { it.upper >= 240 }) best240fhd = true
            }
            if (facing == "back") {
                offer = if (best240fhd)
                    3 to "Camera $id ADVERTISES 1920x1080 at 240fps to third-party apps. Now run the 3-second trial: advertised is not the same as delivered."
                else if (sizes.any { s -> map.getHighSpeedVideoFpsRangesFor(s).any { it.upper >= 240 } })
                    2 to "Camera $id advertises 240fps, but not at 1920x1080 — see the sizes above. Run the trial."
                else
                    1 to "Camera $id advertises high-speed video, but not 240fps — see the ranges above."
            }
        }
        return offer
    }

    private fun encoders(r: Report) {
        r.section("Video encoders at 1920x1080")
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { it.isEncoder }
        for (mime in listOf("video/avc", "video/hevc")) {
            for (info in list.filter { mime in it.supportedTypes }) {
                val v = runCatching { info.getCapabilitiesForType(mime).videoCapabilities }.getOrNull() ?: continue
                val hw = if (info.isHardwareAccelerated) "hardware" else "software"
                val ok240 = runCatching { v.areSizeAndRateSupported(1920, 1080, 240.0) }.getOrDefault(false)
                val rates = runCatching { v.getSupportedFrameRatesFor(1920, 1080) }.getOrNull()
                val achievable = runCatching { v.getAchievableFrameRatesFor(1920, 1080) }.getOrNull()
                r.line("$mime ${info.name} ($hw): 240fps declared ${if (ok240) "yes" else "no"}; " +
                    "supported fps $rates; measured-achievable ${achievable ?: "not published"}")
            }
        }
    }

    private fun capName(c: Int): String = when (c) {
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE -> "BACKWARD_COMPATIBLE"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR -> "MANUAL_SENSOR"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING -> "MANUAL_POST_PROCESSING"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW -> "RAW"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS -> "READ_SENSOR_SETTINGS"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE -> "BURST_CAPTURE"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT -> "DEPTH_OUTPUT"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO -> "CONSTRAINED_HIGH_SPEED_VIDEO"
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA -> "LOGICAL_MULTI_CAMERA"
        else -> "cap$c"
    }
}
