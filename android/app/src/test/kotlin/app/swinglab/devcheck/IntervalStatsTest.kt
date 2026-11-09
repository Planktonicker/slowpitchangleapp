// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class IntervalStatsTest {

    /**
     * The S21+'s own pattern: a 240fps high-speed session reported almost every
     * frame's capture result twice, about a microsecond apart. Read naively that
     * is 295 fps; it must read 240, and say how many were duplicates.
     */
    @Test
    fun aFrameReportedTwiceIsOneFrame() {
        val period = 4167L
        val ts = ArrayList<Long>()
        for (i in 0 until 640) {
            val t = 1_000_000L + i * period
            ts.add(t)
            if (i % 50 != 0) ts.add(t + 1)          // most, not all, come twice
        }
        val s = assertNotNull(IntervalStats.of(ts))
        assertEquals(640, s.frames)
        assertEquals(ts.size - 640, s.duplicates)
        assertEquals(240.0, s.fps, 0.1)
        assertEquals(0, s.longGaps)
    }

    /** A real dropped frame is still a gap, and decode order does not matter. */
    @Test
    fun aDroppedFrameIsAGapAndOrderIsIrrelevant() {
        val ts = (0 until 100).filter { it != 50 }.map { it * 4167L }.shuffled(java.util.Random(7))
        val s = assertNotNull(IntervalStats.of(ts))
        assertEquals(0, s.duplicates)
        assertEquals(1, s.longGaps)
        assertTrue(s.maxUs > 8000)
        assertEquals(240.0, s.fps, 0.1)
    }
}
