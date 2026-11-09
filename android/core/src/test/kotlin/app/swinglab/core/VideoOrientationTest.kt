// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Port of `VideoOrientationTests` in `app/Tests/PipelineTests.swift`, case by case. */
class VideoOrientationTest {

    @Test
    fun quarterTurnsFromTransform() {
        assertEquals(0, VideoOrientation.quarterTurns(AffineTransform.identity))
        assertEquals(1, VideoOrientation.quarterTurns(AffineTransform(rotationAngle = PI / 2)))
        assertEquals(2, VideoOrientation.quarterTurns(AffineTransform(rotationAngle = PI)))
        assertEquals(3, VideoOrientation.quarterTurns(AffineTransform(rotationAngle = -PI / 2)))
        // The other way round the circle is the same quarter turn.
        assertEquals(3, VideoOrientation.quarterTurns(AffineTransform(rotationAngle = 3 * PI / 2)))
    }

    @Test
    fun displaySizeSwapsOnAQuarterTurn() {
        assertEquals(1920, VideoOrientation.displaySize(width = 1920, height = 1080, quarterTurns = 0).width)
        assertEquals(1080, VideoOrientation.displaySize(width = 1920, height = 1080, quarterTurns = 1).width)
        assertEquals(1920, VideoOrientation.displaySize(width = 1920, height = 1080, quarterTurns = 2).width)
        assertEquals(1080, VideoOrientation.displaySize(width = 1920, height = 1080, quarterTurns = 3).width)
    }

    /** The real numbers from tee_06.mov: the ball's first and last tracked points. */
    @Test
    fun theDropThatReadAsARise() {
        val w = 1920
        val h = 1080
        val first = VideoOrientation.point(x = 1003.11, y = 761.21, width = w, height = h, quarterTurns = 2)
        val last = VideoOrientation.point(x = 1028.78, y = 328.40, width = w, height = h, quarterTurns = 2)

        // In the buffer y DECREASES over the fall, which reads as rising.
        assertTrue(328.40 < 761.21)
        // Rotated into the displayed frame it increases, which is falling.
        assertTrue(last.y > first.y, "a dropped ball must move down the screen")

        // And the angle flips sign, which is the whole point.
        val rawAngle = atan2(-(328.40 - 761.21), abs(1028.78 - 1003.11)) * 180 / PI
        val upAngle = atan2(-(last.y - first.y), abs(last.x - first.x)) * 180 / PI
        assertTrue(rawAngle > 80, "the buffer says it went up")
        assertTrue(upAngle < -80, "the screen says it fell")
    }

    @Test
    fun rotationLeavesDiametersAlone() {
        val track = listOf(BallObservation(frame = 0, t = 0.0, x = 100.0, y = 200.0, diameterPx = 33.5, areaPx = 880.0))
        for (q in 0..3) {
            val r = VideoOrientation.rotate(track = track, width = 1920, height = 1080, quarterTurns = q)
            assertEquals(33.5, r[0].diameterPx, "quarter turns $q")
            assertEquals(880.0, r[0].areaPx, "quarter turns $q")
        }
    }

    @Test
    fun fourTurnsIsIdentity() {
        var p = Point(137.0, 991.0)
        var w = 1920
        var h = 1080
        repeat(4) {
            p = VideoOrientation.point(x = p.x, y = p.y, width = w, height = h, quarterTurns = 1)
            val d = VideoOrientation.displaySize(width = w, height = h, quarterTurns = 1)
            w = d.width; h = d.height
        }
        assertEquals(137.0, p.x, 1e-9)
        assertEquals(991.0, p.y, 1e-9)
    }
}
