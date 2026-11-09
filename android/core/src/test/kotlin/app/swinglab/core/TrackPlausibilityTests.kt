// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port of `app/Tests/TrackPlausibilityTests.swift`, in full; the reasoning lives there. */
class TrackPlausibilityTests {

    /** The Swift `(t, x, y, d)` tuple. */
    private data class P(val t: Double, val x: Double, val y: Double, val d: Double)

    private fun track(pts: List<P>): List<BallObservation> =
        pts.mapIndexed { i, p ->
            BallObservation(frame = i, t = p.t, x = p.x, y = p.y, diameterPx = p.d, areaPx = 80.0)
        }

    /** `XCTUnwrap`. */
    private fun <T : Any> unwrap(value: T?): T = assertNotNull(value)

    /** `live_49`, labelled as having NO swing in it. */
    private val driftingBlob: List<BallObservation>
        get() = track(listOf(
            P(2.229371, 500.16, 499.61, 9.52), P(2.233538, 499.40, 499.48, 9.05),
            P(2.237704, 498.96, 499.83, 9.32), P(2.241883, 498.24, 499.82, 9.36),
            P(2.266879, 493.42, 499.40, 10.26), P(2.275212, 492.38, 499.84, 10.75),
            P(2.279379, 491.61, 498.95, 9.69), P(2.291875, 490.37, 500.16, 8.71),
            P(2.300208, 489.01, 500.49, 10.00),
        ))

    /** `live_39`, verified as the ball by geometry. */
    private val realFlight: List<BallObservation>
        get() = track(listOf(
            P(1.4883, 740.2, 509.0, 11.1), P(1.5050, 797.6, 540.7, 16.0),
            P(1.5083, 818.1, 552.9, 19.1), P(1.5167, 855.9, 563.1, 8.9),
            P(1.5250, 895.0, 577.9, 10.7), P(1.5333, 928.8, 593.6, 11.9),
            P(1.5383, 947.3, 600.2, 12.9), P(1.5417, 962.6, 606.2, 16.7),
            P(1.5500, 998.6, 621.6, 9.5), P(1.5550, 1013.8, 631.0, 11.0),
            P(1.5583, 1027.2, 638.2, 8.3),
        ))

    @Test
    fun theGapBetweenARealFlightAndSceneryIsWide() {
        val slow = unwrap(TrackPlausibility.diametersPerFrame(track = driftingBlob, fps = 240.0))
        val fast = unwrap(TrackPlausibility.diametersPerFrame(track = realFlight, fps = 240.0))
        assertEquals(0.075, slow, 0.02)
        assertEquals(1.75, fast, 0.30)
        // The threshold has to sit clear of BOTH, or it is tuned to one clip.
        assertTrue(TrackPlausibility.minDiametersPerFrame > slow * 2)
        assertTrue(TrackPlausibility.minDiametersPerFrame < fast / 4)
    }

    @Test
    fun aDriftingBlobIsRejected() {
        val why = TrackPlausibility.rejection(track = driftingBlob, launchAngleDeg = 10.1,
            flags = emptyList(), fps = 240.0)
        assertNotNull(why, "the reading live_49 published must now be withheld")
        assertTrue(why.contains("own width per frame"), why)
    }

    @Test
    fun everyOtherGatePassesThatBlob() {
        assertNull(TrackPlausibility.rejection(track = driftingBlob, launchAngleDeg = 10.1,
            flags = emptyList(), fps = 0.0),
            "without fps there is no speed gate, and nothing else catches it")
    }

    @Test
    fun aRealFlightSurvives() {
        assertNull(TrackPlausibility.rejection(track = realFlight, launchAngleDeg = -0.3,
            flags = emptyList(), fps = 240.0, contactTime = 1.4525))
    }

    @Test
    fun aTrackThatStartsLongAfterContactIsRejected() {
        val why = TrackPlausibility.rejection(track = realFlight, launchAngleDeg = -0.3,
            flags = emptyList(), fps = 240.0, contactTime = realFlight[0].t - 0.7)
        assertNotNull(why)
        assertTrue(why.contains("after contact"), why)
    }

    /** `live_48`, also labelled as having no swing. */
    private val preContactFragment: List<BallObservation>
        get() = track(listOf(
            P(1.541800, 1123.52, 185.64, 8.89), P(1.554300, 1151.18, 198.91, 13.50),
            P(1.566800, 1213.96, 191.23, 9.87), P(1.579304, 1308.63, 156.13, 8.83),
        ))

    @Test
    fun aPathThatEndsBeforeContactIsRejected() {
        val why = TrackPlausibility.rejection(track = preContactFragment,
            launchAngleDeg = 22.1, flags = listOf(SwingFlag.shortTrack),
            fps = 240.0, contactTime = 1.581249, exitVeloMph = 198.2)
        assertNotNull(why)
        assertTrue(why.contains("before contact"), why)
    }

    @Test
    fun theEarlierGatesDoNotCatchIt() {
        val perFrame = unwrap(
            TrackPlausibility.diametersPerFrame(track = preContactFragment, fps = 240.0))
        assertTrue(perFrame > TrackPlausibility.minDiametersPerFrame,
            "2.14 diameters a frame is a ball-like speed")
        val start = preContactFragment[0].t - 1.581249
        assertTrue(start < TrackPlausibility.maxStartAfterContactS,
            "it begins inside the contact window")
    }

    @Test
    fun aShortTrackThatSpeedsUpIsRejected() {
        assertTrue(preContactFragment.size < TrackPlausibility.residualMeaninglessBelow)
        val growth = TrackPlausibility.speedGrowth(track = preContactFragment)
        assertEquals(3.29, growth ?: 0.0, 0.15)
        // Contact deliberately omitted, to isolate the growth gate.
        val why = TrackPlausibility.rejection(track = preContactFragment,
            launchAngleDeg = 22.1, flags = listOf(SwingFlag.shortTrack), fps = 240.0)
        assertTrue(why?.contains("sped up") == true, why ?: "nil")
    }

    @Test
    fun aVerifiedFourPointFlightSurvivesTheGrowthGate() {
        val real = track(listOf(
            P(1.4667, 848.8, 497.6, 10.0), P(1.4717, 879.3, 496.7, 11.8),
            P(1.4800, 933.2, 498.2, 12.6), P(1.4833, 960.8, 498.2, 8.6),
        ))
        val growth = TrackPlausibility.speedGrowth(track = real)
        assertEquals(1.37, growth ?: 0.0, 0.15)
        assertTrue((growth ?: 99.0) < TrackPlausibility.maxShortTrackSpeedGrowth)
        assertNull(TrackPlausibility.rejection(track = real, launchAngleDeg = -0.3,
            flags = listOf(SwingFlag.shortTrack), fps = 240.0,
            contactTime = 1.4525, exitVeloMph = 62.0))
    }

    @Test
    fun anImpossibleExitVelocityIsRejected() {
        val why = TrackPlausibility.rejection(track = realFlight, launchAngleDeg = 22.1,
            flags = emptyList(), fps = 240.0, exitVeloMph = 198.2)
        assertTrue(why?.contains("mph") == true, why ?: "nil")
    }

    @Test
    fun contactGatesAreSkippedWhenTheTriggerIsKnownToBeWrong() {
        // A real flight, half a second after a trigger that fired early.
        val contact = realFlight[0].t - 0.5
        assertNotNull(TrackPlausibility.rejection(track = realFlight, launchAngleDeg = -0.3,
            flags = emptyList(), fps = 240.0, contactTime = contact),
            "without the flag, lateness rejects it")
        assertNull(TrackPlausibility.rejection(track = realFlight, launchAngleDeg = -0.3,
            flags = listOf(SwingFlag.contactTimeRejected), fps = 240.0, contactTime = contact),
            "with the flag, the contact time is disowned and must not be judged against")
    }

    @Test
    fun thePreContactGateStillCatchesLive48() {
        val why = TrackPlausibility.rejection(track = preContactFragment,
            launchAngleDeg = 22.1, flags = listOf(SwingFlag.shortTrack, SwingFlag.depthMotion),
            fps = 240.0, contactTime = 1.581249)
        assertNotNull(why)
    }

    @Test
    fun latenessIsSkippedWhenContactIsUnknown() {
        assertNull(TrackPlausibility.rejection(track = realFlight, launchAngleDeg = -0.3,
            flags = emptyList(), fps = 240.0, contactTime = null))
    }
}
