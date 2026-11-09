// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of `app/Tests/CameraPoseTests.swift` `FrameTimingTests`, in full; the
 * reasoning lives there. Method names mirror the Swift `testXxx` names.
 */
class FrameTimingTests {

    private fun intervals(fps: Double, count: Int): MutableList<Double> =
        MutableList(count) { 1 / fps }

    /** `XCTUnwrap`. */
    private fun <T : Any> unwrap(value: T?): T = assertNotNull(value)

    @Test
    fun recoversARoundRate() {
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = intervals(fps = 240.0, count = 60)))
        assertEquals(240.0, t.fps, 1e-9)
        assertEquals(0.0, t.irregularFraction, 1e-9)
    }

    @Test
    fun recoversAnAwkwardRate() {
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = intervals(fps = 198.94, count = 60)))
        assertEquals(198.94, t.fps, 1e-6)
    }

    @Test
    fun aSingleDroppedFrameIsAGapNotBadTiming() {
        val ints = intervals(fps = 240.0, count = 60)
        ints[30] *= 2
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertEquals(240.0, t.fps, 1e-9)
        assertEquals(0.0, t.irregularFraction, 1e-9)
        assertEquals(1.0 / 61, t.droppedFraction, 1e-9)
    }

    @Test
    fun aContainerTooCoarseToExpressTheRateStillReadsAsSquare() {
        val tick = 1.0 / 600
        // Straight from the clip's `stts`: ticks, and how many frames had them.
        val histogram = listOf(
            3 to 233, 2 to 224, 5 to 69, 7 to 21, 10 to 20,
            8 to 15, 12 to 4, 15 to 3, 20 to 2, 17 to 1,
        )
        val ints = mutableListOf<Double>()
        for ((ticks, count) in histogram) {
            repeat(count) { ints.add(ticks.toDouble() * tick) }
        }
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertEquals(240.0, t.fps, 2.0, "the alternation averages back to 240")
        assertTrue(t.irregularFraction < 0.01, "quantisation is not variable frame rate")
        assertEquals(0.30, t.droppedFraction, 0.02)
    }

    @Test
    fun timestampRoundingCannotFlipTheBasePeriod() {
        // Cumulative PTS in ticks, alternating 2 and 3 — then differenced in
        // seconds, exactly as the decoder hands them over.
        val ints = mutableListOf<Double>()
        var ticks = 0
        var previous = 0.0
        for (i in 0 until 600) {
            ticks += if (i % 2 == 0) 2 else 3
            val seconds = ticks.toDouble() / 600
            ints.add(seconds - previous)
            previous = seconds
        }
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertEquals(240.0, t.fps, 1.0, "the alternation must average back to 240, not collapse to 300")
        assertTrue(t.irregularFraction < 0.01)
        assertEquals(0.0, t.droppedFraction, 0.01, "nothing was dropped — every frame is there")
    }

    @Test
    fun variableRateIsReportedAsIrregular() {
        val ints = intervals(fps = 240.0, count = 60)
        for (i in 0 until 60 step 2) ints[i] *= 1.6
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertTrue(t.irregularFraction > 0.4)
    }

    @Test
    fun assortedGapsAreAllReadAsDroppedFrames() {
        val ints = intervals(fps = 240.0, count = 60)
        for ((i, periods) in listOf(10 to 2.0, 20 to 4.0, 30 to 8.0, 40 to 3.0)) {
            ints[i] *= periods
        }
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertEquals(240.0, t.fps, 1e-9)
        assertEquals(0.0, t.irregularFraction, 1e-9)
        // 56 single periods + 2 + 4 + 8 + 3 = 73 expected, 60 arrived.
        assertEquals(13.0 / 73, t.droppedFraction, 1e-9)
    }

    @Test
    fun refusesTooFewIntervals() {
        assertNull(ClipAnalyzer.frameTiming(fromIntervals = listOf(1.0 / 240, 1.0 / 240)))
        assertNull(ClipAnalyzer.frameTiming(fromIntervals = emptyList()))
    }

    @Test
    fun ignoresNonPositiveAndNonFiniteIntervals() {
        val ints = intervals(fps = 240.0, count = 20)
        ints.addAll(listOf(0.0, -1.0 / 240, Double.NaN, Double.POSITIVE_INFINITY))
        val t = unwrap(ClipAnalyzer.frameTiming(fromIntervals = ints))
        assertEquals(240.0, t.fps, 1e-9)
        assertEquals(20, t.intervals)
    }
}
