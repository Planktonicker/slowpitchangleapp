// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build

/**
 * What a video file really holds, measured from its own frame timestamps.
 *
 * The trap this exists for: a slow-motion recording can be stored as a
 * slowed-down file. A Samsung community report describes a 5-second S21 clip at
 * 240fps saved as a 40-second, 30fps video with no visible sign of the capture
 * rate. Measured from that file's timestamps, a ball crosses the frame eight
 * times slower than it did, and every exit velocity is eight times too low.
 * Android can record the true rate in a `com.android.capture.fps` metadata
 * tag, which a file may or may not carry — so both are read, and the verdict
 * says which of the three cases this file is.
 */
object ClipInspector {

    /** Frames read for the interval statistics: about 2.5 s at 240fps. */
    private const val MAX_SAMPLES = 600

    fun run(context: Context, uri: Uri, title: String = "Clip inspection"): Report {
        val r = Report()
        r.line("SwingLab device check — $title")
        r.line("Device: ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}")
        r.line("File: $uri")

        var captureFps: Double? = null
        var durationMs: Long? = null
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(context, uri)
            fun m(key: Int) = runCatching { mmr.extractMetadata(key) }.getOrNull()
            durationMs = m(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            captureFps = m(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()
            r.section("Container metadata")
            r.line("Duration: ${durationMs?.let { num(it / 1000.0, 3) + " s" } ?: "?"}")
            r.line("Size: ${m(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)}x${m(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)}, rotation ${m(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)}")
            r.line("Frame count: ${m(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)}")
            r.line("Capture frame rate tag (com.android.capture.fps): ${captureFps?.let { num(it, 2) } ?: "ABSENT"}")
            r.line("Date: ${m(MediaMetadataRetriever.METADATA_KEY_DATE)}, MIME ${m(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)}")
            r.line("Has audio: ${m(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)}")
        } catch (e: Exception) {
            r.line("Metadata could not be read: $e")
        } finally {
            runCatching { mmr.release() }
        }

        var stats: IntervalStats? = null
        val ex = MediaExtractor()
        try {
            ex.setDataSource(context, uri, null)
            r.section("Tracks")
            var video = -1
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: "?"
                r.line("Track $i: $mime ${describeFormat(f)}")
                if (video < 0 && mime.startsWith("video/")) video = i
            }
            if (video >= 0) {
                ex.selectTrack(video)
                val times = ArrayList<Long>()
                while (times.size < MAX_SAMPLES) {
                    val t = ex.sampleTime
                    if (t < 0) break
                    times.add(t)
                    if (!ex.advance()) break
                }
                stats = IntervalStats.of(times)
                r.section("Frame timestamps (first ${times.size} frames)")
                stats?.describe(r, "From the file's own timestamps") ?: r.line("Too few frames to measure.")
            } else {
                r.line("No video track.")
            }
        } catch (e: Exception) {
            r.line("Could not read the samples: $e")
        } finally {
            runCatching { ex.release() }
        }

        r.section("Verdict")
        r.line(verdict(stats?.fps, captureFps))
        return r
    }

    /**
     * The three cases, said plainly. Timestamps are the evidence; the tag is
     * only believed when the timestamps are slow enough to need explaining.
     */
    private fun verdict(timestampFps: Double?, captureFps: Double?): String {
        if (timestampFps == null) return "Could not measure the frame rate from this file."
        val ts = num(timestampFps, 1)
        return when {
            timestampFps >= 200 ->
                "TRUE HIGH-SPEED FILE: the timestamps run at $ts fps. Usable as it is — the time between frames in the file is the real time between them."
            captureFps != null && captureFps >= 2 * timestampFps ->
                "SLOWED-DOWN FILE WITH THE TRUE RATE RECORDED: timestamps run at $ts fps but the capture tag says ${num(captureFps, 0)} fps. " +
                    "Usable only if the app rescales time by ${num(captureFps / timestampFps, 2)}x — measured as-is, speeds would read ${num(captureFps / timestampFps, 1)}x too low."
            timestampFps < 100 ->
                "SLOWED-DOWN OR NORMAL-SPEED FILE, NO CAPTURE RATE RECORDED: timestamps run at $ts fps and there is no capture tag. " +
                    "If this was filmed as slow motion, the true rate is lost from the file: exit velocity would be wrong by the slow-motion factor unless the rate is entered by hand."
            else ->
                "Timestamps run at $ts fps (capture tag ${captureFps?.let { num(it, 0) } ?: "absent"}). Not a 240fps file."
        }
    }

    private fun describeFormat(f: MediaFormat): String {
        val parts = mutableListOf<String>()
        fun intOrNull(k: String) = if (f.containsKey(k)) runCatching { f.getInteger(k) }.getOrNull() else null
        fun numberOrNull(k: String): String? {
            if (!f.containsKey(k)) return null
            return runCatching { f.getInteger(k).toString() }.getOrNull()
                ?: runCatching { num(f.getFloat(k), 3) }.getOrNull()
        }
        intOrNull(MediaFormat.KEY_WIDTH)?.let { w -> parts.add("${w}x${intOrNull(MediaFormat.KEY_HEIGHT)}") }
        numberOrNull(MediaFormat.KEY_FRAME_RATE)?.let { parts.add("declared frame-rate $it") }
        numberOrNull("capture-rate")?.let { parts.add("capture-rate $it") }
        if (f.containsKey(MediaFormat.KEY_DURATION)) parts.add("duration ${num(f.getLong(MediaFormat.KEY_DURATION) / 1e6, 3)} s")
        intOrNull(MediaFormat.KEY_SAMPLE_RATE)?.let { parts.add("sample rate $it Hz") }
        intOrNull(MediaFormat.KEY_CHANNEL_COUNT)?.let { parts.add("$it ch") }
        intOrNull("rotation-degrees")?.let { parts.add("rotation $it") }
        return parts.joinToString(", ")
    }
}
