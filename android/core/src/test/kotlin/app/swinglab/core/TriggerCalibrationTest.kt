// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Kotlin-only: the Swift has no tests for `TriggerCalibration` (its clock was
 * `CACurrentMediaTime`, which a test cannot drive). The arithmetic is pinned by
 * FoundationParityTest's trigger_calibration and listen_only_threshold blocks;
 * these check that the state machine hands that arithmetic the right two
 * numbers, using the injected clock.
 */
class TriggerCalibrationTest {

    private var now = 100.0
    private fun calibration() = TriggerCalibration(clock = { now })

    private fun result(c: TriggerCalibration): TriggerCalibration.Result {
        val p = c.phase
        if (p !is TriggerCalibration.Phase.done) fail("expected done, got $p")
        return p.result
    }

    /** Listen for the full background window at a steady level with one peak in it. */
    private fun listen(c: TriggerCalibration, peakDb: Double) {
        c.startBackground()
        c.ingest(10.0)
        now += 1; c.ingest(peakDb)
        now += 1; c.ingest(12.0)
        assertTrue(c.phase is TriggerCalibration.Phase.background)
        now += TriggerCalibration.backgroundListenS
        c.ingest(11.0)
        assertEquals(TriggerCalibration.Phase.hits(recorded = 0), c.phase)
    }

    /** One hit: a burst of rising levels, banked once the burst window has passed. */
    private fun hit(c: TriggerCalibration, peakDb: Double) {
        c.ingest(peakDb - 4)
        now += 0.01; c.ingest(peakDb)
        now += 0.01; c.ingest(peakDb - 8)
        now += 0.3; c.tick()
    }

    @Test
    fun listenOnlyGivesTheBackgroundThresholdAndNoVerdict() {
        val c = calibration()
        listen(c, peakDb = 30.1)
        c.finishEarly()
        assertTrue(c.isDone)
        val r = result(c)
        assertEquals(30.1, r.backgroundPeakDb)
        assertEquals(SLA.thresholdFromBackground(backgroundPeakDb = 30.1), r.thresholdDb)
        assertNull(r.quietestHitDb)
        assertNull(r.loudestHitDb)
        assertNull(r.separationDb)
        assertNull(r.verdict)
        assertEquals(0, r.hitCount)
    }

    @Test
    fun threeHitsUseTheQuietestAgainstTheBackgroundPeak() {
        val c = calibration()
        listen(c, peakDb = 20.0)
        hit(c, 45.0)
        assertEquals(TriggerCalibration.Phase.hits(recorded = 1), c.phase)
        hit(c, 38.0)
        hit(c, 50.0)
        val r = result(c)
        val expected = SLA.suggestTriggerDb(backgroundPeakDb = 20.0, quietestHitDb = 38.0)
        assertEquals(38.0, r.quietestHitDb)
        assertEquals(50.0, r.loudestHitDb)
        assertEquals(expected.thresholdDb, r.thresholdDb)
        assertEquals(expected.separationDb, r.separationDb)
        assertEquals(expected.verdict, r.verdict)
        assertEquals(3, r.hitCount)
    }

    @Test
    fun aScuffBelowTheMarginIsNotAHit() {
        val c = calibration()
        listen(c, peakDb = 20.0)
        c.ingest(20.0 + TriggerCalibration.minHitOverBackgroundDb - 0.5)
        now += 1; c.tick()
        assertEquals(TriggerCalibration.Phase.hits(recorded = 0), c.phase)
        c.finishEarly()
        assertEquals(0, result(c).hitCount)
    }

    @Test
    fun finishEarlyBanksABurstStillInProgress() {
        val c = calibration()
        listen(c, peakDb = 20.0)
        c.ingest(40.0)
        c.finishEarly()
        val r = result(c)
        assertEquals(1, r.hitCount)
        assertEquals(40.0, r.quietestHitDb)
    }

    @Test
    fun cancelReturnsToIdleAndIgnoresLevels() {
        val c = calibration()
        listen(c, peakDb = 20.0)
        c.cancel()
        assertEquals(TriggerCalibration.Phase.idle, c.phase)
        c.ingest(60.0)
        now += 1; c.tick()
        assertEquals(TriggerCalibration.Phase.idle, c.phase)
        assertFalse(c.isDone)
        assertEquals(60.0, c.currentDb, "the meter still follows the level")
    }
}
