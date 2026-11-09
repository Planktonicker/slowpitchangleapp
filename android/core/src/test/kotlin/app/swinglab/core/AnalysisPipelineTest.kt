// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Port of the `app/Tests/PipelineTests.swift` cases that exercise this slice's
 * files — the CSV bridge back to the spike. The track-building, Vision-mapping,
 * scoreboard and storage cases there belong to the slices that own those types.
 */
class AnalysisPipelineTest {

    /** Port of `PipelineTests.straightTrack`. */
    private fun straightTrack(
        frames: Int,
        fps: Double = 240.0,
        x0: Double = 100.0,
        y0: Double = 800.0,
        vx: Double = 4000.0,
        vy: Double = -1200.0,
        diameter: Double = 24.3,
        startFrame: Int = 0,
    ): List<BallObservation> = (0 until frames).map { i ->
        val t = (startFrame + i).toDouble() / fps
        val dt = i.toDouble() / fps
        BallObservation(frame = startFrame + i, t = t,
                        x = x0 + vx * dt,
                        y = y0 + vy * dt + 0.5 * 2450 * dt * dt,
                        diameterPx = diameter,
                        areaPx = PI * (diameter / 2) * (diameter / 2))
    }

    // CSV bridge

    @Test
    fun trackCSVRoundTrips() {
        val track = straightTrack(frames = 12)
        val csv = TrackCSV.serialize(track = track, fps = 240.0,
                                     meta = listOf("clip" to "tee_01.mov",
                                                   "contact_time" to "0.125000"))
        val parsed = TrackCSV.parse(csv)
        assertEquals(track.size, parsed.track.size)
        assertEquals(240.0, parsed.fps)
        assertEquals(0.125, parsed.contactTime)
        assertEquals("tee_01.mov", parsed.meta["clip"])
        for ((a, b) in parsed.track.zip(track)) {
            assertEquals(b.frame, a.frame)
            assertEquals(b.x, a.x, 0.01)
            assertEquals(b.y, a.y, 0.01)
            assertEquals(b.diameterPx, a.diameterPx, 0.01)
        }
    }

    @Test
    fun trackCSVHeaderMatchesReferenceFormat() {
        val csv = TrackCSV.serialize(track = straightTrack(frames = 3), fps = 240.0)
        val lines = csv.split("\n").filter { it.isNotEmpty() }
        assertTrue(lines.contains("# fps=240.0"))
        assertTrue(lines.contains("frame,t,x_px,y_px,diameter_px,area_px"),
                   "analyze_swing.py reads these exact column names")
    }
}
