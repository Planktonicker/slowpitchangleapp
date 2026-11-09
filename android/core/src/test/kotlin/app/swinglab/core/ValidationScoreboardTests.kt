// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of the `// MARK: - Scoreboard` tests in `app/Tests/PipelineTests.swift`,
 * in full; the reasoning lives there. Method names mirror the Swift `testXxx`
 * names. The Kotlin-only tests at the end cover what the Swift left untested.
 */
class ValidationScoreboardTests {

    /** `SwingDTO()`'s defaults, for the fields the scoreboard reads. */
    private data class Swing(
        override val id: UUID = UUID.randomUUID(),
        override val setting: SwingSetting = SwingSetting.tee,
        override val clipFilename: String? = null,
        override val contactTime: Double = 0.0,
        override val launchAngleDeg: Double = 0.0,
        override val exitVeloMph: Double = 0.0,
        override val exitVeloMps: Double = 0.0,
        override val scaleBallMPerPx: Double = 0.0,
        override val scaleGravityMPerPx: Double? = null,
        override val scaleDisagreement: Double? = null,
        override val diameterDrift: Double = 0.0,
        override val trackedFrames: Int = 0,
        override val trackDurationS: Double = 0.0,
        override val fitRmsPx: Double = 0.0,
        override val flags: List<SwingFlag> = emptyList(),
        override val autoTriggered: Boolean = true,
        override val hangS: Double? = null,
        override val carryM: Double? = null,
        override val captureFlags: List<CaptureFlag> = emptyList(),
    ) : ScoreboardSwing

    private fun swing(
        setting: SwingSetting,
        frames: Int = 30,
        ev: Double = 70.0,
        la: Double = 20.0,
        disagreement: Double? = 0.02,
        auto: Boolean = true,
    ): Swing = Swing(
        setting = setting,
        trackedFrames = frames,
        exitVeloMph = ev,
        launchAngleDeg = la,
        scaleDisagreement = disagreement,
        autoTriggered = auto,
    )

    @Test
    fun scoreboardCountsUntrackedClipsAgainstG1() {
        val swings = listOf(swing(SwingSetting.tee), swing(SwingSetting.tee), swing(SwingSetting.tee, frames = 0))
        val board = ValidationScoreboard.build(from = swings)
        val row = board.g1.firstOrNull { it.setting == SwingSetting.tee }
        assertEquals(2, row?.tracked)
        assertEquals(3, row?.total, "a clip with no track is still a clip")
        assertEquals(false, row?.passes, "2/3 is below the 90% tee threshold")
    }

    @Test
    fun scoreboardG2ExcludesIndoorClips() {
        val swings = listOf(
            swing(SwingSetting.tee, disagreement = 0.02),
            swing(SwingSetting.tee, disagreement = 0.04),
            swing(SwingSetting.cage, disagreement = 0.50),   // must not drag the median
        )
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(2, board.g2Count)
        assertEquals(3.0, assertNotNull(board.g2MedianPct), 1e-9)
        assertEquals(true, board.g2Passes)
    }

    @Test
    fun scoreboardG4NeedsThreeIdenticalIntentSwings() {
        var board = ValidationScoreboard.build(from = listOf(swing(SwingSetting.teeid), swing(SwingSetting.teeid)))
        assertNull(board.g4EvSd)

        board = ValidationScoreboard.build(from = listOf(
            swing(SwingSetting.teeid, ev = 70.0, la = 20.0),
            swing(SwingSetting.teeid, ev = 71.0, la = 21.0),
            swing(SwingSetting.teeid, ev = 69.0, la = 19.0),
        ))
        assertEquals(1.0, assertNotNull(board.g4EvSd), 1e-9)
        assertEquals(1.0, assertNotNull(board.g4LaSd), 1e-9)
        assertEquals(true, board.g4EvPasses)
    }

    @Test
    fun verdictIsFullStopWhenOutdoorTeeFails() {
        val swings = List(10) { swing(SwingSetting.tee, frames = 0) } +   // nothing tracked
            listOf(swing(SwingSetting.teeid, ev = 70.0), swing(SwingSetting.teeid, ev = 71.0), swing(SwingSetting.teeid, ev = 69.0))
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(ValidationScoreboard.Verdict.noGo, board.verdict)
        assertTrue(board.verdictExplanation.contains("full stop"))
    }

    @Test
    fun verdictDemotesCageWithoutBlockingOutdoor() {
        val swings = List(10) { swing(SwingSetting.tee) } +
            listOf(swing(SwingSetting.teeid, ev = 70.0), swing(SwingSetting.teeid, ev = 71.0), swing(SwingSetting.teeid, ev = 69.0)) +
            List(10) { swing(SwingSetting.cage, frames = 0) }
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(ValidationScoreboard.Verdict.goOutdoorOnly, board.verdict)
    }

    @Test
    fun throughNetFailureDoesNotBlock() {
        val swings = List(10) { swing(SwingSetting.tee) } +
            listOf(swing(SwingSetting.teeid, ev = 70.0), swing(SwingSetting.teeid, ev = 71.0), swing(SwingSetting.teeid, ev = 69.0)) +
            List(3) { swing(SwingSetting.net, frames = 0) }
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(ValidationScoreboard.Verdict.go, board.verdict, "through-the-net is an expected failure, not a gate")
        assertNull(board.g1.firstOrNull { it.setting == SwingSetting.net }?.passes)
    }

    @Test
    fun g5CountsManualTriggersAsMisses() {
        val swings = List(10) { i -> swing(SwingSetting.tee, auto = i < 8) }
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(8, board.g5AutoTriggered)
        assertEquals(false, board.g5Passes, "80% is under the 90% G5 bar")
    }

    // Kotlin-only — branches of ValidationScoreboard.swift no Swift test reaches.

    /** The reason the comment in `build` gives: ten clean live swings and five imports must still read 100%. */
    @Test
    fun g5IgnoresImportedClips() {
        val live = List(10) { swing(SwingSetting.tee, auto = true) }
        val imported = List(5) {
            swing(SwingSetting.tee, auto = false).copy(captureFlags = listOf(CaptureFlag.importedClip))
        }
        val board = ValidationScoreboard.build(from = live + imported)
        assertEquals(10, board.g5Total)
        assertEquals(10, board.g5AutoTriggered)
        assertEquals(true, board.g5Passes)
    }

    @Test
    fun g3RowsOnlyForSwingsWithGroundTruth() {
        val withHang = swing(SwingSetting.fly).copy(
            exitVeloMps = 30.0, launchAngleDeg = 30.0, hangS = 3.0, clipFilename = "fly_01.mov")
        val withCarryOnly = swing(SwingSetting.fly).copy(exitVeloMps = 30.0, launchAngleDeg = 30.0, carryM = 60.0)
        val board = ValidationScoreboard.build(from = listOf(withHang, withCarryOnly, swing(SwingSetting.fly)))
        assertEquals(2, board.g3.size, "a swing with neither hang nor carry has nothing to check")

        val hangRow = board.g3[0]
        assertEquals(withHang.id, hangRow.id)
        assertEquals("fly_01.mov", hangRow.label)
        val flight = FlightModel.simulate(evMps = 30.0, laDeg = 30.0, contactHeightM = 0.9)
        assertEquals((flight.hangS - 3.0) / 3.0 * 100, assertNotNull(hangRow.hangErrorPct), 1e-9)
        assertNull(hangRow.carryErrorPct)
        assertNull(hangRow.carryPasses)

        val carryRow = board.g3[1]
        assertEquals("swing", carryRow.label, "an unnamed clip is labelled 'swing'")
        assertNull(carryRow.hangErrorPct)
        assertEquals((flight.carryM - 60.0) / 60.0 * 100, assertNotNull(carryRow.carryErrorPct), 1e-9)
    }

    @Test
    fun accuracyFailureIsNoGoWithoutBeingAFullStop() {
        val swings = List(10) { swing(SwingSetting.tee, disagreement = 0.20) } +
            listOf(swing(SwingSetting.teeid, ev = 70.0), swing(SwingSetting.teeid, ev = 71.0), swing(SwingSetting.teeid, ev = 69.0))
        val board = ValidationScoreboard.build(from = swings)
        assertEquals(false, board.g2Passes)
        assertEquals(ValidationScoreboard.Verdict.noGo, board.verdict)
        assertTrue(board.verdictExplanation.startsWith("Trackability holds"))
    }

    @Test
    fun verdictWaitsForEveryDecidingGate() {
        assertEquals(ValidationScoreboard.Verdict.notEnoughData, ValidationScoreboard.build(from = emptyList()).verdict)
        // Tee passes, but there are no identical-intent swings for G4.
        val board = ValidationScoreboard.build(from = List(10) { swing(SwingSetting.tee) })
        assertEquals(ValidationScoreboard.Verdict.notEnoughData, board.verdict)
        assertEquals("Not enough data yet", board.verdict.raw)
    }
}
