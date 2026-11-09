// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Kotlin-only checks for the analysis slice, where the Swift has no test of its
 * own: places the port could quietly answer differently from the Swift —
 * a tie-break, printf rounding, `Double(_:)` strictness, Swift's `max()`.
 */
class AnalysisKotlinTest {

    private data class Swing(
        override val sessionID: UUID?,
        override val capturedAt: Instant,
        override val setting: SwingSetting = SwingSetting.tee,
        override val launchAngleDeg: Double = 20.0,
        override val exitVeloMph: Double = 70.0,
        override val highConfidence: Boolean = true,
    ) : SessionSwing

    private val t0: Instant = Instant.parse("2026-11-09T10:00:00Z")
    private fun at(s: Long): Instant = t0.plusSeconds(s)

    // Session

    @Test
    fun aTiedRoundIsNamedForTheLowerRawValue() {
        val id = UUID.randomUUID()
        // Two field-live (live + fly fold to live) against two tee: a tie, and
        // the Swift's comparator hands it to "live" < "tee".
        val swings = listOf(
            Swing(id, at(0), SwingSetting.tee), Swing(id, at(1), SwingSetting.fly),
            Swing(id, at(2), SwingSetting.teeid), Swing(id, at(3), SwingSetting.live),
        )
        assertEquals(SessionMode.live, Session.derived(id = id, from = swings)?.mode)

        val tossVsTee = listOf(Swing(id, at(0), SwingSetting.toss), Swing(id, at(1), SwingSetting.tee))
        assertEquals(SessionMode.tee, Session.derived(id = id, from = tossVsTee)?.mode)

        val mostlyToss = tossVsTee + Swing(id, at(2), SwingSetting.toss)
        assertEquals(SessionMode.toss, Session.derived(id = id, from = mostlyToss)?.mode)
    }

    @Test
    fun aRoundSpansItsSwingsAndVanishesWithThem() {
        val a = UUID.randomUUID()
        val b = UUID.randomUUID()
        val swings = listOf(
            Swing(a, at(30)), Swing(a, at(10)), Swing(null, at(5)),
            Swing(b, at(100)), Swing(a, at(20)),
        )
        val round = assertNotNull(Session.derived(id = a, from = swings))
        assertEquals(at(10), round.startedAt)
        assertEquals(at(30), round.endedAt)
        assertFalse(round.isOpen)
        assertEquals(20.0, round.duration, 1e-9)
        assertNull(Session.derived(id = UUID.randomUUID(), from = swings))

        assertEquals(listOf(b, a), Session.allDerived(from = swings).map { it.id }, "newest first")
    }

    @Test
    fun theSummarySplitsConfidentFromFlagged() {
        val id = UUID.randomUUID()
        val swings = listOf(
            Swing(id, at(3), launchAngleDeg = 30.0, exitVeloMph = 80.0),
            Swing(id, at(1), launchAngleDeg = 12.0, exitVeloMph = 61.0),
            Swing(id, at(2), launchAngleDeg = 18.0, exitVeloMph = 99.0, highConfidence = false),
            Swing(id, at(4), launchAngleDeg = 22.0, exitVeloMph = 75.0),
            Swing(id, at(5), launchAngleDeg = 5.0, exitVeloMph = 55.0),
            Swing(UUID.randomUUID(), at(0), exitVeloMph = 120.0),
        )
        val s = SessionSummary.build(session = Session(id = id), swings = swings)
        assertEquals(listOf(at(1), at(3), at(4), at(5)), s.confident.map { it.capturedAt })
        assertEquals(listOf(at(2)), s.flagged.map { it.capturedAt })
        assertEquals(5, s.total)
        assertEquals(80.0, s.bestExitVeloMph, "a flagged swing is never the best")
        assertEquals(17.0, s.medianLaunchAngleDeg, "even count averages the middle two")
        assertEquals(2, s.inLaunchWindow)
        assertFalse(s.isEmpty)

        val empty = SessionSummary.build(session = Session(), swings = swings)
        assertTrue(empty.isEmpty)
        assertNull(empty.bestExitVeloMph)
        assertNull(empty.medianLaunchAngleDeg)
    }

    @Test
    fun bestExitVeloSkipsALateNaNAsSwiftMaxDoes() {
        val id = UUID.randomUUID()
        val swings = listOf(Swing(id, at(0), exitVeloMph = 70.0), Swing(id, at(1), exitVeloMph = Double.NaN))
        assertEquals(70.0, SessionSummary.build(session = Session(id = id), swings = swings).bestExitVeloMph)
    }

    @Test
    fun sessionModeFoldsEverySetting() {
        assertEquals(
            listOf(SessionMode.tee, SessionMode.tee, SessionMode.toss, SessionMode.live,
                   SessionMode.live, SessionMode.live, SessionMode.live),
            SwingSetting.entries.map { SessionMode(setting = it) })
        for (m in SessionMode.entries) assertEquals(m, SessionMode(setting = m.swingSetting))
    }

    // SwingRead

    @Test
    fun contactNeedsSmashOrUndercut() {
        assertNull(SwingRead.contact(smash = null, quality = SmashQuality.unknown,
                                     contactQuality = ContactQuality.unknown, undercutMm = null,
                                     launchAngleDeg = 20.0))
    }

    @Test
    fun contactAppendsTheNumbersAsPrintfWouldWriteThem() {
        val c = assertNotNull(SwingRead.contact(
            smash = 1.345, quality = SmashQuality.flush, contactQuality = ContactQuality.underCarry,
            undercutMm = 18.5, launchAngleDeg = 20.0))
        assertEquals("Flush, and under the ball — the one that carries.", c.headline)
        // %.0f of 18.5 is "18" and %.2f of 1.345 is "1.34": printf rounds the
        // exact binary value half-to-even, where String.format would say 19 and 1.35.
        assertTrue(c.why.endsWith(" Barrel centre passed 18 mm below the ball centre. Smash factor 1.34."), c.why)
        assertNull(c.tryThis)

        val over = assertNotNull(SwingRead.contact(
            smash = null, quality = SmashQuality.unknown, contactQuality = ContactQuality.topped,
            undercutMm = -9.0, launchAngleDeg = -5.0))
        assertEquals("Over the ball.", over.headline)
        assertTrue(over.why.endsWith(" Barrel centre passed 9 mm above the ball centre."), over.why)

        assertNull(SwingRead.contact(smash = null, quality = SmashQuality.unknown,
                                     contactQuality = ContactQuality.implausible, undercutMm = 80.0,
                                     launchAngleDeg = 20.0))
    }

    @Test
    fun flushThroughTheMiddleAdvisesOnlyOutsideTheWindow() {
        fun tryThis(la: Double) = SwingRead.contact(
            smash = 1.4, quality = SmashQuality.flush, contactQuality = ContactQuality.centered,
            undercutMm = 2.0, launchAngleDeg = la)?.tryThis
        assertNull(tryThis(15.0))
        assertNotNull(tryThis(3.0))
    }

    @Test
    fun bodyNotesRoundHalfAwayFromZero() {
        val notes = SwingRead.body(BodyMetrics(strideM = 0.405, headDriftM = 0.153, weightShiftM = null,
                                               frontKneeDeg = 166.5, spineTiltDeg = null))
        assertEquals(
            listOf("Head moved 15 cm", "Front leg straight at contact — 167°", "Stride 41 cm"),
            notes.map { it.title })
        assertEquals(listOf(true, true, false), notes.map { it.isConvention })
        assertTrue(SwingRead.body(BodyMetrics()).isEmpty(), "a missing number produces no sentence")
    }

    @Test
    fun exportCaptionKeepsPrintfSigns() {
        assertEquals("-0°   70.0 mph", SwingRead.exportCaption(launchAngleDeg = -0.3, exitVeloMph = 70.0, smash = null))
        assertEquals("+20°   96.6 km/h   smash 1.38",
                     SwingRead.exportCaption(launchAngleDeg = 20.5, exitVeloMph = 60.0, smash = 1.375,
                                             unit = SpeedUnit.kmh))
    }

    // TrackCSV

    @Test
    fun aFractionalFrameRateIsWrittenAsSwiftDescribesIt() {
        fun fpsLine(fps: Double) = TrackCSV.serialize(track = emptyList(), fps = fps).lines().first()
        assertEquals("# fps=239.76", fpsLine(239.76))
        assertEquals("# fps=0.00015", fpsLine(0.00015))
        assertEquals("# fps=1.5e-05", fpsLine(0.000015))
        assertEquals("# fps=1e-05", fpsLine(0.00001))
        assertEquals("# fps=nan", fpsLine(Double.NaN))
        assertEquals("# fps=inf", fpsLine(Double.POSITIVE_INFINITY))
    }

    @Test
    fun parseIsAsStrictAsSwiftsNumberInitialisers() {
        val text = """
            # fps = 240
            frame,t,x_px,y_px,diameter_px
            0,0.0,1,2,10
             1,0.1,1,2,10
            2,0.2 ,1,2,10
            3,0.3,1,2,10d
            ٤,0.4,1,2,10
            5,+.5,0x1p3,-2e1,10
            6,0.6,1,2
        """.trimIndent()
        val parsed = TrackCSV.parse(text)
        assertEquals(240.0, parsed.fps)
        assertEquals(listOf(0, 5), parsed.track.map { it.frame })
        val five = parsed.track[1]
        assertEquals(0.5, five.t)
        assertEquals(8.0, five.x)
        assertEquals(-20.0, five.y)
        assertEquals(Math.PI * 25, five.areaPx, 1e-12, "no area column: the area of the circle")
    }

    // DetectionTrace and orientation

    @Test
    fun detectionTraceCopiesAreIndependent() {
        val a = DetectionTrace(searchedX0 = 0, searchedY0 = 0, searchedX1 = 10)
        assertFalse(a.hasSearchRegion)
        val b = a.copy()
        b.searchedY1 = 10
        b.candidates = b.candidates + BallObservation(0, 0.0, 1.0, 2.0, 3.0, 4.0)
        assertTrue(b.hasSearchRegion)
        assertFalse(a.hasSearchRegion)
        assertTrue(a.candidates.isEmpty())
    }

    @Test
    fun imageOrientationAndQuarterTurnsAgree() {
        for (q in -4..7) {
            val o = VideoOrientation.imageOrientation(quarterTurns = q)
            assertEquals(((q % 4) + 4) % 4, VideoOrientation.quarterTurns(from = o), "q $q")
        }
        assertEquals(ImagePropertyOrientation.up, ImagePropertyOrientation.fromRaw(1))
        assertEquals(3, VideoOrientation.quarterTurns(from = ImagePropertyOrientation.leftMirrored))
    }

    /** rotate(pose:) moves every joint exactly as point() moves a single pixel, and a confidence does not rotate. */
    @Test
    fun rotatePoseMovesEachJointLikePointAndKeepsConfidence() {
        val obs = PoseObservation(frame = 7, t = 0.029, joints = mapOf(
            PoseJoint.nose to PosePoint(x = 1003.11, y = 361.21, confidence = 0.91),
            PoseJoint.leftAnkle to PosePoint(x = 988.0, y = 1010.5, confidence = 0.12),
        ))
        assertEquals(listOf(obs), VideoOrientation.rotate(pose = listOf(obs), width = 1920, height = 1080, quarterTurns = 0))
        for (q in 1..3) {
            val r = VideoOrientation.rotate(pose = listOf(obs), width = 1920, height = 1080, quarterTurns = q).single()
            assertEquals(obs.frame, r.frame)
            assertEquals(obs.t, r.t)
            assertEquals(obs.joints.keys, r.joints.keys)
            for ((j, pt) in obs.joints) {
                val want = VideoOrientation.point(x = pt.x, y = pt.y, width = 1920, height = 1080, quarterTurns = q)
                assertEquals(PosePoint(want.x, want.y, pt.confidence), r.joints[j], "q $q $j")
            }
        }
    }
}
