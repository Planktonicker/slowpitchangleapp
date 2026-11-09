// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Port of the "Track building" section of `app/Tests/PipelineTests.swift`
 * (the four `testBuildTracks…` / `testSelectOutboundTrack…` cases). Its own
 * file so the rest of `PipelineTests` can be ported alongside without a clash.
 */
class PipelineTrackTests {

    private fun straightTrack(
        frames: Int,
        fps: Double = 240.0,
        x0: Double = 100.0,
        y0: Double = 800.0,
        vx: Double = 4000.0,
        vy: Double = -1200.0,
        diameter: Double = 24.3,
        startFrame: Int = 0,
    ): List<BallObservation> =
        (0 until frames).map { i ->
            val t = (startFrame + i).toDouble() / fps
            val dt = i.toDouble() / fps
            BallObservation(frame = startFrame + i, t = t,
                x = x0 + vx * dt,
                y = y0 + vy * dt + 0.5 * 2450 * dt * dt,
                diameterPx = diameter,
                areaPx = PI * (diameter / 2) * (diameter / 2))
        }

    private fun perFrame(tracks: List<List<BallObservation>>): MutableMap<Int, List<BallObservation>> {
        val out = HashMap<Int, List<BallObservation>>()
        for (track in tracks) {
            for (o in track) out[o.frame] = (out[o.frame] ?: emptyList()) + o
        }
        return out
    }

    @Test
    fun buildTracksLinksAFastBall() {
        val truth = straightTrack(frames = 30)
        val tracks = TrackBuilder.buildTracks(perFrame = perFrame(listOf(truth)), fps = 240.0)
        assertEquals(1, tracks.size)
        assertEquals(30, tracks.firstOrNull()?.size)
    }

    @Test
    fun buildTracksCoastsThroughAMissedFrame() {
        val frames = perFrame(listOf(straightTrack(frames = 30)))
        // The batter's body hides the ball for two frames.
        frames.remove(10)
        frames.remove(11)
        val tracks = TrackBuilder.buildTracks(perFrame = frames, fps = 240.0)
        assertEquals(1, tracks.size, "a two-frame gap should not split the track")
        assertEquals(28, tracks.firstOrNull()?.size)
    }

    @Test
    fun buildTracksRejectsStationaryClutter() {
        // A fixed bright speck — a reflection off the net, say.
        val clutter = (0 until 30).map { i ->
            BallObservation(frame = i, t = i.toDouble() / 240,
                x = 600.0, y = 300.0, diameterPx = 12.0, areaPx = 113.0)
        }
        val tracks = TrackBuilder.buildTracks(
            perFrame = perFrame(listOf(straightTrack(frames = 30), clutter)), fps = 240.0)
        val chosen = TrackBuilder.selectOutboundTrack(tracks)
        assertNotNull(chosen)
        // The hit ball moves; the speck does not, so it must lose.
        val dt = chosen.last().t - chosen.first().t
        val speed = abs(chosen.last().x - chosen.first().x) / dt
        assertTrue(speed > 1000)
    }

    @Test
    fun selectOutboundTrackPrefersTheHitOverThePitch() {
        // Inbound pitch: slower, travelling the other way.
        val pitch = straightTrack(frames = 20, x0 = 1800.0, vx = -1200.0, vy = 200.0)
        val hit = straightTrack(frames = 30, x0 = 200.0, vx = 4200.0, vy = -1300.0)
        val tracks = TrackBuilder.buildTracks(perFrame = perFrame(listOf(pitch, hit)), fps = 240.0)
        val chosen = assertNotNull(
            TrackBuilder.selectOutboundTrack(tracks, direction = TrackBuilder.Direction.right),
            "no track selected")
        assertTrue(chosen.last().x > chosen.first().x, "should have picked the outbound hit")
    }
}
