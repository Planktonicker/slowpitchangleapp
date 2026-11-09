// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt
import kotlin.math.tan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Synthetic tests for [BatTracker]. There is no Python reference to pin it to —
 * `sla_common.py` never tracks the tape, it is handed the tape's velocity and
 * contact position — and the Swift has no tests of its own for it. Where the
 * tracker's output feeds a Python function (`bat_speed_mps`, `undercut_m`), the
 * tests close the loop through that function's fixture block instead.
 */
class BatTrackerTest {

    // MARK: - Synthetic frames

    private val background = Bgr(50, 50, 50)       // dark enough that the tape's luma clears the motion threshold
    private val tape = Bgr(120, 40, 255)           // fluorescent pink: H ≈ 169, S ≈ 215, V = 255
    private val ballYellow = Bgr(0, 230, 230)      // optic yellow: H = 30, the ball's window, not the bat's

    private data class Bgr(val b: Int, val g: Int, val r: Int)

    private class Canvas(val width: Int, val height: Int, fill: Bgr) {
        val bytes = ByteArray(width * height * 4)

        init { rect(0, 0, width, height, fill) }

        fun set(x: Int, y: Int, c: Bgr) {
            if (x !in 0 until width || y !in 0 until height) return
            val o = (y * width + x) * 4
            bytes[o] = c.b.toByte(); bytes[o + 1] = c.g.toByte(); bytes[o + 2] = c.r.toByte(); bytes[o + 3] = 255.toByte()
        }

        /** x1, y1 exclusive. */
        fun rect(x0: Int, y0: Int, x1: Int, y1: Int, c: Bgr) {
            for (y in y0 until y1) for (x in x0 until x1) set(x, y, c)
        }

        /** Every pixel whose centre is within [r] of (cx, cy): symmetric about the centre, so its centroid IS the centre. */
        fun disc(cx: Int, cy: Int, r: Int, c: Bgr) {
            for (dy in -r..r) for (dx in -r..r) if (dx * dx + dy * dy <= r * r) set(cx + dx, cy + dy, c)
        }

        fun image() = PixelImage(bytes.copyOf(), width, height)
    }

    private val settings = BatTracker.Settings()

    @Test
    fun theTestColoursAreWhatTheyClaim() {
        fun inBat(c: Bgr) = HSVConvert.inRange(c.b.toDouble(), c.g.toDouble(), c.r.toDouble(), settings.hsvLo, settings.hsvHi)
        assertTrue(inBat(tape))
        assertFalse(inBat(background))
        assertFalse(inBat(ballYellow))
        assertTrue(HSVConvert.inRange(0.0, 230.0, 230.0, SLA.hsvLoDefault, SLA.hsvHiDefault), "yellow is the ball's colour")
        // The motion gate must be able to see the tape move over this background.
        val luma = Canvas(2, 1, background).apply { set(1, 0, tape) }.image().lumaPlane()
        assertTrue(abs((luma[1].toInt() and 0xFF) - (luma[0].toInt() and 0xFF)) > SLA.motionDiffThreshold)
    }

    // MARK: - detectTape

    @Test
    fun theTapeIsTheCentroidOfThePinkBlob() {
        val c = Canvas(160, 120, background)
        c.rect(40, 50, 60, 58, tape)                    // 20 x 8, centre (49.5, 53.5)
        val p = assertNotNull(BatTracker.detectTape(c.image(), settings))
        assertEquals(49.5, p.x, 1e-9)
        assertEquals(53.5, p.y, 1e-9)
    }

    @Test
    fun aSearchWindowReportsFullFramePixels() {
        val c = Canvas(160, 120, background)
        c.rect(40, 50, 60, 58, tape)
        val p = assertNotNull(BatTracker.detectTape(c.image(), settings, roi = ROI(30, 40, 100, 80)))
        assertEquals(49.5, p.x, 1e-9)
        assertEquals(53.5, p.y, 1e-9)
        // A window that misses the tape finds nothing; one too thin to hold a blob is refused outright.
        assertNull(BatTracker.detectTape(c.image(), settings, roi = ROI(80, 0, 160, 120)))
        assertNull(BatTracker.detectTape(c.image(), settings, roi = ROI(40, 50, 42, 58)))
    }

    /**
     * The area window is inclusive at both ends. The blob's area is read off
     * the same mask stage first, because the morphology trims the corners of a
     * drawn rectangle and the window applies to what is left.
     */
    @Test
    fun theAreaWindowIsInclusiveAtBothEnds() {
        val c = Canvas(160, 120, background)
        c.rect(40, 50, 60, 58, tape)
        val img = c.image()
        val mask = BallDetector.maskAfterMorphology(img, ROI(0, 0, 160, 120), settings.hsvLo, settings.hsvHi)
        val area = ConnectedComponents.label(mask, 160, 120).single().count.toDouble()
        assertTrue(area >= settings.minBlobArea && area <= settings.maxBlobArea)

        fun found(min: Double, max: Double) =
            BatTracker.detectTape(img, settings.deepCopy().apply { minBlobArea = min; maxBlobArea = max }) != null
        assertTrue(found(area, area))
        assertFalse(found(area + 1, 20000.0), "smaller than the floor")
        assertFalse(found(30.0, area - 1), "larger than the ceiling")
    }

    @Test
    fun aSpeckIsNotTape() {
        val c = Canvas(160, 120, background)
        c.rect(40, 50, 44, 54, tape)                    // 4 x 4: under 30 px before the opening even trims it
        assertNull(BatTracker.detectTape(c.image(), settings))
    }

    @Test
    fun theLargestTapeBlobWins() {
        val c = Canvas(200, 120, background)
        c.rect(20, 20, 32, 28, tape)                    // 12 x 8
        c.rect(100, 60, 130, 70, tape)                  // 30 x 10, centre (114.5, 64.5)
        val p = assertNotNull(BatTracker.detectTape(c.image(), settings))
        assertEquals(114.5, p.x, 1e-9)
        assertEquals(64.5, p.y, 1e-9)
    }

    @Test
    fun aBallColouredBlobIsNotTape() {
        val c = Canvas(160, 120, background)
        c.rect(40, 50, 60, 58, ballYellow)
        assertNull(BatTracker.detectTape(c.image(), settings))
    }

    /**
     * A pink jersey on the bench is bigger than the tape and does not move. On
     * colour alone it wins; behind the motion gate it is not there at all.
     */
    @Test
    fun aStationaryPinkObjectIsNotTape() {
        val c = Canvas(200, 120, background)
        c.rect(120, 30, 170, 90, tape)                  // the jersey, 50 x 60
        c.disc(40, 60, 5, tape)                         // the tape, moving
        val img = c.image()

        val ungated = assertNotNull(BatTracker.detectTape(img, settings))
        assertEquals(144.5, ungated.x, 1e-9, "without the gate the jersey is the answer")

        val motion = BooleanArray(200 * 120)
        for (y in 50..70) for (x in 30..50) motion[y * 200 + x] = true
        val gated = assertNotNull(BatTracker.detectTape(img, settings, motion = motion))
        assertEquals(40.0, gated.x, 1e-9)
        assertEquals(60.0, gated.y, 1e-9)

        assertNull(BatTracker.detectTape(img, settings, motion = BooleanArray(200 * 120)),
                   "nothing moved, so nothing is tape")
    }

    // MARK: - analyze

    /** Tape positions along x = cx + vx τ + ½ ax τ², likewise y, τ = t − contact, at 240fps over the window. */
    private fun quadraticPath(
        contact: Double,
        cx: Double, vx: Double, ax: Double,
        cy: Double, vy: Double, ay: Double,
        frames: IntRange = -14..1,
    ): List<BatTracker.TapeObservation> = frames.map { k ->
        val tau = k / 240.0
        BatTracker.TapeObservation(t = contact + tau,
                                   x = cx + vx * tau + 0.5 * ax * tau * tau,
                                   y = cy + vy * tau + 0.5 * ay * tau * tau)
    }

    @Test
    fun fewerThanThreeSightingsIsNoPath() {
        val path = quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, -1200.0, 0.0, frames = -2..0)
        assertNull(BatTracker.analyze(path.take(2), contactTime = 1.0))
        assertNotNull(BatTracker.analyze(path, contactTime = 1.0))
    }

    /**
     * A curved barrel path, handed over out of order, recovers its velocity and
     * position AT CONTACT — the derivative and value of the fit at τ = 0 — not
     * at the first or last sighting.
     */
    @Test
    fun aQuadraticPathRecoversItsVelocityAndPositionAtContact() {
        val contact = 2.5
        val path = quadraticPath(contact, cx = 600.0, vx = 7000.0, ax = -40000.0,
                                 cy = 500.0, vy = -1200.0, ay = 90000.0)
        val shuffled = path.reversed().chunked(3).flatMap { it.reversed() }
        val m = assertNotNull(BatTracker.analyze(shuffled, contactTime = contact))

        assertEquals(path.size, m.nFrames)
        assertClose(m.vxPxS, 7000.0, "vx", abs = 1e-6)
        assertClose(m.vyPxS, -1200.0, "vy", abs = 1e-6)
        assertClose(m.contactXPx, 600.0, "contact x", abs = 1e-9)
        assertClose(m.contactYPx, 500.0, "contact y", abs = 1e-9)
        assertTrue(m.fitRmsPx < 1e-9, "an exact quadratic leaves no residual: ${m.fitRmsPx}")
        assertEquals(atan2(1200.0, 7000.0) * 180 / PI, m.attackAngleDeg, 1e-9)
        // Drawn oldest first, whatever order the sightings arrived in.
        assertEquals(path.map { Point(it.x, it.y) }, m.pathPx)
    }

    /** Up-positive, and the same number whichever way the hitter faces. */
    @Test
    fun theAttackAngleIsUpPositiveWhicheverWayTheHitterFaces() {
        val rise = 7000.0 * tan(10 * PI / 180)          // image y grows DOWN, so rising is negative vy
        val rightHanded = assertNotNull(BatTracker.analyze(quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, -rise, 0.0), 1.0))
        val leftHanded = assertNotNull(BatTracker.analyze(quadraticPath(1.0, 600.0, -7000.0, 0.0, 500.0, -rise, 0.0), 1.0))
        val chopping = assertNotNull(BatTracker.analyze(quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, rise, 0.0), 1.0))
        assertEquals(10.0, rightHanded.attackAngleDeg, 1e-6)
        assertEquals(10.0, leftHanded.attackAngleDeg, 1e-6)
        assertEquals(-10.0, chopping.attackAngleDeg, 1e-6)
    }

    /**
     * A tape that never moves is not a bat — but it is the PRESENCE GATE that
     * says so, not `analyze`'s zero-velocity guard. Round-off in the normal
     * equations leaves the fitted velocity at ~1e-10 px/s rather than zero, so
     * the guard passes and the "attack angle" is the direction of round-off
     * (73° on the still path in [theTapeVelocityGivesThePythonsBatSpeed]). That
     * is the Swift's arithmetic exactly, and it is why ClipAnalyzer's speed
     * floor is load-bearing rather than a nicety.
     */
    @Test
    fun aTapeThatNeverMovesIsWithheldByThePresenceGateNotTheFit() {
        val still = (0 until 10).map { BatTracker.TapeObservation(t = it / 240.0, x = 300.0, y = 200.0) }
        val m = assertNotNull(BatTracker.analyze(still, contactTime = 0.03))
        assertTrue(abs(m.vxPxS) < 1e-6 && abs(m.vyPxS) < 1e-6, "round-off, not motion: ${m.vxPxS}, ${m.vyPxS}")
        assertFalse(BatTracker.isSwingingBat(m, 1.0 / 240, settings))

        // The guard itself fires only where the arithmetic is exact: sightings on
        // two distinct timestamps fall back to a straight-line fit, whose slope
        // through identical positions is exactly zero.
        val twoTimes = listOf(0.0, 0.0, 1 / 240.0).map { BatTracker.TapeObservation(t = it, x = 300.0, y = 200.0) }
        assertNull(BatTracker.analyze(twoTimes, contactTime = 0.0))
    }

    @Test
    fun confidenceNeedsSixFramesAndATightFit() {
        val five = assertNotNull(BatTracker.analyze(quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, -1200.0, 0.0, frames = -4..0), 1.0))
        assertTrue(five.isLowConfidence, "five frames")
        val six = assertNotNull(BatTracker.analyze(quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, -1200.0, 0.0, frames = -5..0), 1.0))
        assertFalse(six.isLowConfidence, "six clean frames")

        // ±10 px of jitter on alternate frames: no quadratic can follow it.
        val jittered = quadraticPath(1.0, 600.0, 7000.0, 0.0, 500.0, -1200.0, 0.0)
            .mapIndexed { i, o -> o.copy(y = o.y + if (i % 2 == 0) 10.0 else -10.0) }
        val noisy = assertNotNull(BatTracker.analyze(jittered, 1.0))
        assertTrue(noisy.fitRmsPx > 6.0, "rms ${noisy.fitRmsPx}")
        assertTrue(noisy.isLowConfidence)
    }

    /**
     * The tape's velocity at contact is what `sla_common.bat_speed_mps` is
     * handed. A barrel path built to have each fixture case's velocity must come
     * back through the tracker with the Python's bat speed. The untracked case
     * (zero velocity) is a tape that never moved: whatever round-off the fit
     * leaves, the presence gate must withhold it, as that case's
     * `smash_factor: null` does — and the tracked cases, 20-29 m/s swings, must
     * pass it.
     */
    @Test
    fun theTapeVelocityGivesThePythonsBatSpeed() {
        for (c in Fixtures.block("bat_metrics")) {
            val name = c.s("name")
            val vx = c.d("vx_px_s")
            val vy = c.d("vy_px_s")
            val scale = c.d("scale_m_per_px")
            val tracked = c.dOrNull("smash_factor") != null
            // Zero velocity at contact on a curving path is not a still tape, so
            // the untracked case gets the still tape it describes.
            val path = if (vx == 0.0 && vy == 0.0) {
                quadraticPath(3.0, 640.0, 0.0, 0.0, 360.0, 0.0, 0.0)
            } else {
                quadraticPath(3.0, 640.0, vx, -30000.0, 360.0, vy, 60000.0)
            }
            val m = BatTracker.analyze(path, contactTime = 3.0)
            if (m == null) {
                assertFalse(tracked, "$name: a tracked swing must give a path")
                continue
            }
            val bs = SLA.batSpeedMps(m.vxPxS, m.vyPxS, scale)
            assertClose(bs, c.d("bat_speed_mps"), "$name bat speed", abs = 1e-9, rel = 1e-9)
            assertEquals(tracked, BatTracker.isSwingingBat(m, scale, settings), "$name presence")
        }
    }

    /**
     * The tape's position at contact is the `bat_y0_px` that
     * `sla_common.undercut_m` is handed. Only the number is compared: the
     * `boundary_neg6mm` case sits 1e-17 m from a band edge on purpose, which is
     * the parity test's business with the exact input, not a fit's.
     */
    @Test
    fun theTapePositionGivesThePythonsUndercut() {
        for (c in Fixtures.block("contact_offset")) {
            val path = quadraticPath(3.0, 640.0, 6500.0, -30000.0, c.d("bat_y0_px"), -900.0, 60000.0)
            val m = assertNotNull(BatTracker.analyze(path, contactTime = 3.0), c.s("name"))
            val u = SLA.undercutM(c.d("ball_y0_px"), m.contactYPx, c.d("scale_m_per_px"))
            assertClose(u, c.d("undercut_m"), "${c.s("name")} undercut", abs = 1e-12)
        }
    }

    // MARK: - The window and the presence gate (ClipAnalyzer's, lifted out)

    @Test
    fun noContactNoWindow() {
        assertNull(BatTracker.window(null, settings))
    }

    /** 60 ms before contact to 5 ms after: frames −14…+1 at 240fps, sixteen sightings at most. */
    @Test
    fun theWindowRunsFromSixtyMillisecondsBeforeContactToFiveAfter() {
        val contact = 50 / 240.0
        val w = assertNotNull(BatTracker.window(contact, settings))
        assertEquals(contact - 0.06, w.start)
        assertEquals(contact + 0.005, w.endInclusive)
        val inWindow = (0 until 120).filter { (it / 240.0) in w }.map { it - 50 }
        assertEquals((-14..1).toList(), inWindow)
    }

    @Test
    fun aTapeSlowerThanASwingIsNotABat() {
        fun candidate(vx: Double) = BatMetrics(attackAngleDeg = 0.0, nFrames = 16, fitRmsPx = 0.5,
                                               pathPx = emptyList(), vxPxS = vx, vyPxS = 0.0,
                                               contactXPx = 0.0, contactYPx = 0.0)
        // 1/16 m per px is exact in binary, so 128 px/s is exactly the 8 m/s floor.
        assertTrue(BatTracker.isSwingingBat(candidate(128.0), 0.0625, settings), "the floor itself passes")
        assertFalse(BatTracker.isSwingingBat(candidate(127.0), 0.0625, settings))
        // A 13 m/s barrel — the slowest adult slow-pitch swing — passes; a cooler lid does not.
        assertTrue(BatTracker.isSwingingBat(candidate(13.0 * 240), 1.0 / 240, settings))
        assertFalse(BatTracker.isSwingingBat(candidate(0.5 * 240), 1.0 / 240, settings))
        assertFalse(BatTracker.isSwingingBat(candidate(13.0 * 240), Double.NaN, settings), "no scale, no bat")
    }

    // MARK: - End to end

    /**
     * A taped barrel through contact, filmed at 240fps past a pink jersey on the
     * bench, run the way `ClipAnalyzer.swift` runs it: luma difference against
     * the previous frame, tape looked for only inside the window and only when
     * there is a previous frame, then the fit. Positions are drawn to the
     * nearest pixel, so the answer is close, not exact.
     */
    @Test
    fun aTapedBarrelGivesBackItsAttackAngleAndSpeed() {
        val w = 640
        val h = 280
        val contactFrame = 40
        val contact = contactFrame / 240.0
        val vx = 6000.0                                  // 25 px a frame: clear of its own last position
        val vy = -vx * tan(8 * PI / 180)                 // rising 8° at contact
        val ay = 10000.0                                 // and curving up into it
        fun at(t: Double): Pair<Double, Double> {
            val tau = t - contact
            return (450 + vx * tau) to (150 + vy * tau + 0.5 * ay * tau * tau)
        }

        val window = assertNotNull(BatTracker.window(contact, settings))
        val sightings = mutableListOf<BatTracker.TapeObservation>()
        var previous: MotionMask.Luma? = null
        var sawJerseyUngated = false
        for (i in 20..45) {
            val t = i / 240.0
            val c = Canvas(w, h, background)
            c.rect(560, 20, 620, 100, tape)              // the jersey: 60 x 80, never moves
            val (x, y) = at(t)
            c.disc(x.rounded().toInt(), y.rounded().toInt(), 5, tape)
            val img = c.image()
            val luma = MotionMask.Luma(img.lumaPlane(), w, h)
            val motion = MotionMask.mask(current = luma, previous = previous)
            previous = luma
            if (t in window && motion != null) {
                val p = assertNotNull(BatTracker.detectTape(img, settings, motion = motion), "frame $i")
                assertTrue(p.x < 560, "frame $i: the jersey was gated out")
                sightings.add(BatTracker.TapeObservation(t, p.x, p.y))
                if (!sawJerseyUngated) {
                    sawJerseyUngated = assertNotNull(BatTracker.detectTape(img, settings)).x > 560
                }
            }
        }
        assertTrue(sawJerseyUngated, "the jersey would have won on colour alone")
        assertEquals(16, sightings.size)

        val m = assertNotNull(BatTracker.analyze(sightings, contactTime = contact))
        assertFalse(m.isLowConfidence)
        assertEquals(8.0, m.attackAngleDeg, 0.5)
        val speed = SLA.batSpeedMps(m.vxPxS, m.vyPxS, 1.0 / 240)
        val trueSpeed = sqrt(vx * vx + vy * vy) / 240
        assertTrue(abs(speed - trueSpeed) / trueSpeed < 0.01, "speed $speed vs $trueSpeed")
        assertEquals(150.0, m.contactYPx, 1.0)
        assertTrue(BatTracker.isSwingingBat(m, 1.0 / 240, settings))
    }
}
