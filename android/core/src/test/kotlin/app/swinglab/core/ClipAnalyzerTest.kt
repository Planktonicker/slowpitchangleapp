// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Kotlin-only: the Swift has no tests for `ClipAnalyzer.summarise` or
 * `explainUnjoined`. Both write words into the detection trace that a person
 * reads to find out why the ball was not chosen, so each reason is pinned to
 * the exact text the Swift writes for it.
 */
class ClipAnalyzerTest {

    /** A straight chain: [n] frames from ([x0], [y0]) at ([vx], [vy]) px/s, 240 fps from [t0]. */
    private fun chain(
        n: Int, t0: Double, x0: Double, y0: Double, vx: Double, vy: Double,
        d: Double = 10.0, frame0: Int = 0,
    ): List<BallObservation> = List(n) { i ->
        val dt = i / 240.0
        BallObservation(frame = frame0 + i, t = t0 + dt, x = x0 + vx * dt, y = y0 + vy * dt,
            diameterPx = d, areaPx = 80.0)
    }

    // summarise

    @Test
    fun everyPassedOverTrackSaysWhichGateItFailed() {
        val chosen = chain(12, t0 = 1.00, x0 = 100.0, y0 = 500.0, vx = 2400.0, vy = -300.0, frame0 = 240)
        val short = chain(3, t0 = 0.20, x0 = 50.0, y0 = 50.0, vx = 900.0, vy = 0.0, frame0 = 48)
        val shortAtContact = chain(3, t0 = 1.01, x0 = 60.0, y0 = 60.0, vx = 900.0, vy = 0.0, frame0 = 242)
        val slowerAtContact = chain(6, t0 = 1.02, x0 = 70.0, y0 = 70.0, vx = 800.0, vy = 0.0, frame0 = 245)
        val frozen = List(10) { i -> BallObservation(frame = 10 + i, t = 0.5, x = 10.0 * i, y = 0.0, diameterPx = 9.0, areaPx = 60.0) }
        val wanders = listOf(0.0 to 0.0, 6.0 to 3.0, 1.0 to 6.0, 7.0 to 2.0, 2.0 to 5.0, 5.0 to 1.0, 0.0 to 4.0, 6.0 to 6.0, 1.0 to 1.0)
            .mapIndexed { i, (x, y) -> BallObservation(frame = 100 + i, t = 0.4 + i / 240.0, x = x, y = y, diameterPx = 9.0, areaPx = 60.0) }
        val leftward = chain(10, t0 = 0.10, x0 = 900.0, y0 = 300.0, vx = -1200.0, vy = 0.0, frame0 = 24)

        val summaries = ClipAnalyzer.summarise(
            tracks = listOf(short, shortAtContact, slowerAtContact, frozen, wanders, leftward, chosen),
            selected = chosen, direction = TrackBuilder.Direction.right, contactTime = 1.0,
        )
        val byStart = summaries.associateBy { it.startT }
        assertEquals("", byStart.getValue(chosen[0].t).rejectedBecause)
        assertTrue(byStart.getValue(chosen[0].t).selected)
        assertEquals("only 3 frames, needs 8", byStart.getValue(short[0].t).rejectedBecause)
        assertEquals("only 3 frames, needs 4 even at contact", byStart.getValue(shortAtContact[0].t).rejectedBecause)
        assertEquals("slower than the chosen track", byStart.getValue(slowerAtContact[0].t).rejectedBecause)
        assertEquals("no elapsed time", byStart.getValue(0.5).rejectedBecause)
        val straight = TrackBuilder.straightness(wanders)
        assertTrue(straight < SLA.trackStraightnessMin)
        assertEquals("wanders — straightness ${formatFixed(straight, 2)}, needs 0.55", byStart.getValue(wanders[0].t).rejectedBecause)
        assertEquals("travels the wrong way for a hit", byStart.getValue(leftward[0].t).rejectedBecause)

        // Selected first, then fastest first.
        assertTrue(summaries[0].selected)
        val rest = summaries.drop(1).map { it.speedPxS }
        assertEquals(rest.sortedDescending(), rest)
        // A track with no positive step reads 0, not nothing.
        assertEquals(0.0, byStart.getValue(0.5).speedPxS)
    }

    @Test
    fun withoutADirectionTheWrongWayIsNotAReason() {
        val chosen = chain(12, t0 = 1.0, x0 = 100.0, y0 = 500.0, vx = 2400.0, vy = 0.0)
        val leftward = chain(10, t0 = 0.1, x0 = 900.0, y0 = 300.0, vx = -1200.0, vy = 0.0, frame0 = 24)
        val summaries = ClipAnalyzer.summarise(listOf(leftward, chosen), selected = chosen,
            direction = TrackBuilder.Direction.auto, contactTime = null)
        assertEquals("slower than the chosen track", summaries.single { !it.selected }.rejectedBecause)
    }

    @Test
    fun theWinnerSurvivesTheTruncationAndLongTracksAreThinned() {
        val slowWinner = chain(70, t0 = 2.0, x0 = 0.0, y0 = 0.0, vx = 300.0, vy = 0.0, frame0 = 480)
        val crowd = List(25) { k -> chain(9, t0 = 0.01 * k, x0 = 0.0, y0 = 10.0 * k, vx = 1000.0 + 10 * k, vy = 0.0, frame0 = 1000 + 20 * k) }
        val summaries = ClipAnalyzer.summarise(crowd + listOf(slowWinner), selected = slowWinner,
            direction = TrackBuilder.Direction.auto, contactTime = null)
        assertEquals(DetectionTrace.trackSummaryLimit, summaries.size)
        assertTrue(summaries[0].selected, "the slowest track is kept because it won")
        assertEquals(70, summaries[0].frames)
        // 70 / 32 = stride 2: every other point, from the first.
        assertEquals(35, summaries[0].points.size)
        assertEquals(slowWinner[2].x, summaries[0].points[1].x)
        // The fastest of the crowd lead the rest.
        assertEquals(crowd[24][0].t, summaries[1].startT)
        // A short track keeps every point.
        assertEquals(9, summaries[1].points.size)
    }

    @Test
    fun noSelectionMeansEveryTrackHasAReason() {
        val tracks = listOf(chain(12, t0 = 1.0, x0 = 0.0, y0 = 0.0, vx = 2000.0, vy = 0.0), emptyList())
        val summaries = ClipAnalyzer.summarise(tracks, selected = null,
            direction = TrackBuilder.Direction.auto, contactTime = null)
        assertEquals(1, summaries.size, "an empty track is skipped")
        assertEquals("slower than the chosen track", summaries[0].rejectedBecause)
    }

    // explainUnjoined

    private val a = chain(11, t0 = 1.0, x0 = 100.0, y0 = 500.0, vx = 2400.0, vy = 0.0)
    private val aLastT = a.last().t

    private fun after(gap: Double, dx: Double, dy: Double, vx: Double = 2400.0, vy: Double = 0.0, d: Double = 10.0) =
        chain(11, t0 = aLastT + gap, x0 = a.last().x + dx, y0 = a.last().y + dy, vx = vx, vy = vy, d = d, frame0 = 100)

    private fun explain(b: List<BallObservation>, first: List<BallObservation> = a): String =
        ClipAnalyzer.explainUnjoined(listOf(first, b)).single()

    @Test
    fun aGapPastTheStitchLimitIsNamed() {
        assertEquals("1.00–1.04s → 1.24s  gap 200ms: gap over the 100ms stitch limit",
            explain(after(gap = 0.2, dx = 480.0, dy = 0.0)))
    }

    @Test
    fun aVelocityJumpIsNamed() {
        assertEquals("1.00–1.04s → 1.09s  gap 50ms: velocity jumps 2000 px/s — gravity allows 552",
            explain(after(gap = 0.05, dx = 120.0, dy = 0.0, vy = 2000.0)))
    }

    @Test
    fun aSidewaysHopIsNamed() {
        assertEquals("1.00–1.04s → 1.09s  gap 50ms: the two sit 90° apart, not along the flight",
            explain(after(gap = 0.05, dx = 0.0, dy = 120.0)))
    }

    @Test
    fun aMissedPredictionIsNamed() {
        assertEquals("1.00–1.04s → 1.09s  gap 50ms: lands 180px from the prediction (tolerance 72)",
            explain(after(gap = 0.05, dx = 300.0, dy = 0.0)))
    }

    @Test
    fun aJoinablePairIsCalledOut() {
        assertEquals("1.00–1.04s → 1.09s  gap 50ms: JOINABLE at 1px — yet not joined; report this",
            explain(after(gap = 0.05, dx = 120.0, dy = 0.0)))
    }

    @Test
    fun degenerateEndpointsAreNamed() {
        // Fast overall, but its last six points stand still — at the origin,
        // so the fitted velocity there is exactly zero rather than rounding.
        val stalls = chain(10, t0 = 1.0, x0 = -90.0, y0 = 0.0, vx = 2400.0, vy = 0.0) +
            List(6) { i -> BallObservation(frame = 10 + i, t = 1.0 + (10 + i) / 240.0, x = 0.0, y = 0.0, diameterPx = 10.0, areaPx = 80.0) }
        val next = chain(11, t0 = stalls.last().t + 0.05, x0 = 300.0, y0 = 500.0, vx = 2400.0, vy = 0.0, frame0 = 100)
        assertTrue(explain(next, first = stalls).endsWith(": an endpoint has no measurable velocity"))

        assertTrue(explain(after(gap = 0.05, dx = 120.0, dy = 0.0, d = 0.0),
            first = a.map { it.copy(diameterPx = 0.0) }).endsWith(": no measurable ball size"))
    }

    @Test
    fun onlyTheFastFewAreExplainedAndAtMostEightLines() {
        val slow = listOf(
            chain(11, t0 = 1.0, x0 = 0.0, y0 = 0.0, vx = 500.0, vy = 0.0),
            chain(11, t0 = 1.1, x0 = 60.0, y0 = 0.0, vx = 500.0, vy = 0.0, frame0 = 100),
        )
        assertEquals(emptyList(), ClipAnalyzer.explainUnjoined(slow), "clutter not joining clutter is not news")

        val many = List(8) { k -> chain(4, t0 = 1.0 + 0.02 * k, x0 = 0.0, y0 = 40.0 * k, vx = 1000.0 + 100 * k, vy = 0.0, frame0 = 10 * k) }
        val lines = ClipAnalyzer.explainUnjoined(many)
        assertEquals(8, lines.size)
        // The two slowest were never among the six considered.
        assertTrue(lines.none { it.startsWith("1.00–") || it.startsWith("1.02–") })
    }
}
