// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of the `app/Tests/PipelineTests.swift` cases on `LevelSensor`'s maths
 * (method names and tolerances are the Swift's), then the Kotlin-only half: the
 * adapter from Android's sensor convention.
 *
 * The adapter tests are written from the PHYSICS of each pose, never from the
 * code. Every reading below is "which way is UP, in the phone's own axes", times
 * the 9.81 a phone at rest reads — because that is what `TYPE_GRAVITY` and
 * `TYPE_ACCELEROMETER` report: the force holding the phone up. Axes: x to the
 * right and y to the top edge with the phone upright in portrait, z out of the
 * screen towards whoever is looking at it. The rear lens looks along -z.
 */
class LevelSensorTest {

    // MARK: - Ported from PipelineTests.swift

    /** Port of `PipelineTests.testTiltIsPositiveWhenTheLensAimsDown`. */
    @Test
    fun tiltIsPositiveWhenTheLensAimsDown() {
        // Flat on a table, screen up: the rear lens stares at the table.
        assertEquals(90.0, LevelSensor.tiltDown(gravityZ = -1.0), 1e-9)
        // Face down: the lens stares at the sky.
        assertEquals(-90.0, LevelSensor.tiltDown(gravityZ = 1.0), 1e-9)
        // Upright in portrait on a level tripod: the lens is horizontal.
        assertEquals(0.0, LevelSensor.tiltDown(gravityZ = 0.0), 1e-9)
        // Out-of-range input from a noisy sample must clamp, not produce NaN.
        assertEquals(90.0, LevelSensor.tiltDown(gravityZ = -1.0001), 1e-9)
        assertFalse(LevelSensor.tiltDown(gravityZ = 1.0001).isNaN())
    }

    /** Port of `PipelineTests.testRollIsMeasuredFromTheNearestQuarterTurn`. */
    @Test
    fun rollIsMeasuredFromTheNearestQuarterTurn() {
        // Square in every orientation reads zero, including upside-down.
        for (square in listOf(-180.0, -90.0, 0.0, 90.0, 180.0)) {
            assertEquals(0.0, LevelSensor.rollOffSquare(portraitDeg = square), 1e-9, "$square° is square")
        }
        // The same 2° error, in each of the four, with the same sign.
        for (square in listOf(-90.0, 0.0, 90.0, 180.0)) {
            assertEquals(2.0, LevelSensor.rollOffSquare(portraitDeg = square + 2), 1e-9, "2° off $square°")
            assertEquals(-2.0, LevelSensor.rollOffSquare(portraitDeg = square - 2), 1e-9, "−2° off $square°")
        }
        // Wrapping: −179 is 1° the other side of upside-down, not 181° off.
        assertEquals(1.0, LevelSensor.rollOffSquare(portraitDeg = -179.0), 1e-9)
        // Kotlin-only: the exact tie at ±45° folds the way Swift's
        // half-away-from-zero `rounded()` folds it. Kotlin's half-even `round`
        // would leave both where they are, and the bound below cannot tell.
        assertEquals(-45.0, LevelSensor.rollOffSquare(portraitDeg = 45.0))
        assertEquals(45.0, LevelSensor.rollOffSquare(portraitDeg = -45.0))
        // Never reports more than half a quarter turn, whatever it is handed.
        // (The Swift's `stride(from: -180, through: 180, by: 0.5)`.)
        for (i in 0..720) {
            val deg = -180.0 + i * 0.5
            assertTrue(abs(LevelSensor.rollOffSquare(portraitDeg = deg)) <= 45 + 1e-9, "$deg° folded past 45°")
        }
    }

    /** Port of `PipelineTests.testAimingUpLiftsTheBallBackUpTheFrame`. */
    @Test
    fun aimingUpLiftsTheBallBackUpTheFrame() {
        val f = TiltRectifier.focalPx(widthPx = 1920.0, fovDeg = 60.0)
        val up = LevelSensor.tiltDown(gravityZ = sin(10 * PI / 180))
        assertTrue(up < 0, "aiming up must read negative")

        val r = TiltRectifier.rectify(x = 960.0, y = 300.0, tiltDeg = up,
                                      focalPx = f, cx = 960.0, cy = 540.0)
        assertTrue(r.y < 300, "rectified ball should sit higher in frame")
        assertEquals(960.0, r.x, 1e-9, "on-axis x must not move")
        assertTrue(r.magnification > 1,
                   "aiming up magnifies above the axis, so the ball reads bigger")

        // The angle-addition identity the homography reduces to on-axis:
        // a point at angle a below the tilted axis is at a + tilt below level.
        val alpha = atan((300.0 - 540) / f)
        val expected = 540 + f * tan(alpha + up * PI / 180)
        assertEquals(expected, r.y, 1e-6)

        // A ball dead centre in a camera aimed up 10 degrees is really 10
        // degrees above the horizon.
        val axis = TiltRectifier.rectify(x = 960.0, y = 540.0, tiltDeg = up,
                                         focalPx = f, cx = 960.0, cy = 540.0)
        assertEquals(540 - f * tan(10 * PI / 180), axis.y, 1e-6)
    }

    // MARK: - Android's sensor convention

    /** What a phone at rest reads, m/s². Any positive value would do; see [aMisScaledAccelerometerReadsTheSameAngles]. */
    private val g0 = 9.81

    private fun rad(deg: Double) = deg * PI / 180

    private fun gravity(x: Double, y: Double, z: Double): LevelSensor.Gravity =
        assertNotNull(LevelSensor.gravityFromAndroid(x, y, z), "($x, $y, $z) has a direction")

    private fun tilt(x: Double, y: Double, z: Double): Double =
        LevelSensor.tiltDown(gravity(x, y, z).z)

    private fun roll(x: Double, y: Double, z: Double): Double =
        LevelSensor.rollOffSquare(LevelSensor.portraitRollDeg(gravity(x, y, z)))

    /**
     * The reading for a phone in landscape on a tripod, from the camera's pose.
     *
     * Camera axes: r to the right of the picture, u up the picture, f out of the
     * rear lens. A level camera has world-up = (r 0, u 1, f 0). Aim the lens
     * down by `lensDownDeg` (= a) and up acquires a component AGAINST the lens:
     * (0, cos a, −sin a). Turn the camera clockwise by `clockwiseDeg` (= c), as
     * seen from behind it — from the screen — and the picture's right side
     * drops, so up leans towards −r: (−cos a sin c, cos a cos c, −sin a).
     *
     * Then into the phone's axes. Screen-side z is −f in every pose. With the
     * TOP EDGE ON THE LEFT, the phone's +x (its right edge in portrait) points
     * up the picture and +y points left: x = u, y = −r. With the TOP EDGE ON
     * THE RIGHT it is the other way round: x = −u, y = r.
     */
    private fun landscapeReading(topEdgeLeft: Boolean, lensDownDeg: Double, clockwiseDeg: Double): Triple<Double, Double, Double> {
        val a = rad(lensDownDeg)
        val c = rad(clockwiseDeg)
        val upR = -cos(a) * sin(c)
        val upU = cos(a) * cos(c)
        val upF = -sin(a)
        val s = if (topEdgeLeft) 1.0 else -1.0
        return Triple(g0 * s * upU, g0 * -s * upR, g0 * -upF)
    }

    @Test
    fun aPhoneFaceUpHasItsLensOnTheTable() {
        // Up comes straight out of the screen: +z.
        val g = gravity(0.0, 0.0, g0)
        // CoreMotion's documented value for the same pose, which is the
        // convention the Swift maths was written against.
        assertEquals(-1.0, g.z, 1e-12)
        assertEquals(90.0, tilt(0.0, 0.0, g0), 1e-9, "lens straight down at the table")
        // Roll is undefined here — gravity has no component in the screen
        // plane — but it must still be a number, not NaN.
        assertFalse(roll(0.0, 0.0, g0).isNaN())
    }

    @Test
    fun aPhoneFaceDownHasItsLensOnTheSky() {
        // Up goes into the screen: −z.
        assertEquals(-90.0, tilt(0.0, 0.0, -g0), 1e-9, "lens straight up at the sky")
    }

    @Test
    fun portraitUprightIsLevel() {
        // Standing on its bottom edge, screen towards you: up is the top edge, +y.
        assertEquals(0.0, tilt(0.0, g0, 0.0), 1e-9)
        assertEquals(0.0, LevelSensor.portraitRollDeg(gravity(0.0, g0, 0.0)), 1e-9)
        assertEquals(0.0, roll(0.0, g0, 0.0), 1e-9)
        // Upside-down portrait is square too.
        assertEquals(0.0, roll(0.0, -g0, 0.0), 1e-9)
    }

    @Test
    fun landscapeEitherWayIsSquare() {
        // Top edge on the left (a quarter turn anticlockwise as you look at the
        // screen): the phone's right edge, +x, now faces the sky.
        assertEquals(0.0, tilt(g0, 0.0, 0.0), 1e-9)
        assertEquals(-90.0, LevelSensor.portraitRollDeg(gravity(g0, 0.0, 0.0)), 1e-9)
        assertEquals(0.0, roll(g0, 0.0, 0.0), 1e-9)
        // Top edge on the right (a quarter turn clockwise): its left edge, −x,
        // faces the sky.
        assertEquals(0.0, tilt(-g0, 0.0, 0.0), 1e-9)
        assertEquals(90.0, LevelSensor.portraitRollDeg(gravity(-g0, 0.0, 0.0)), 1e-9)
        assertEquals(0.0, roll(-g0, 0.0, 0.0), 1e-9)
    }

    /**
     * The filming pose: landscape, lens aimed 10° down at contact height. Tip
     * the lens down and the screen tips back to face the sky a little, so up
     * gains +z: sin 10° of it.
     */
    @Test
    fun theFilmingPoseReadsTenDegreesDown() {
        val z = g0 * sin(rad(10.0))
        val xy = g0 * cos(rad(10.0))
        // Top edge on the left: up is mostly +x.
        assertEquals(10.0, tilt(xy, 0.0, z), 1e-9)
        assertEquals(0.0, roll(xy, 0.0, z), 1e-9)
        // Top edge on the right: up is mostly −x.
        assertEquals(10.0, tilt(-xy, 0.0, z), 1e-9)
        assertEquals(0.0, roll(-xy, 0.0, z), 1e-9)
        // The same lens aimed 10° UP leans the screen forward, towards the
        // ground: up goes into the screen, −z, and the tilt is negative.
        assertEquals(-10.0, tilt(xy, 0.0, -z), 1e-9)
        assertEquals(-10.0, tilt(-xy, 0.0, -z), 1e-9)
        // The pose helper the remaining tests use agrees with these by hand.
        assertTripleEquals(Triple(xy, 0.0, z), landscapeReading(topEdgeLeft = true, lensDownDeg = 10.0, clockwiseDeg = 0.0))
        assertTripleEquals(Triple(-xy, 0.0, z), landscapeReading(topEdgeLeft = false, lensDownDeg = 10.0, clockwiseDeg = 0.0))
    }

    /**
     * Roll is positive CLOCKWISE as you look at the screen — the sign the
     * analyzer's roll correction undoes, pinned end to end in
     * [aRolledLandscapePhoneGivesBackTheTrueLaunchAngle].
     */
    @Test
    fun turningThePhoneClockwiseReadsPositiveRoll() {
        val s2 = g0 * sin(rad(2.0))
        val c2 = g0 * cos(rad(2.0))
        // Portrait, turned 2° clockwise: the right edge (+x) dips, so up leans
        // away from +x.
        assertEquals(2.0, roll(-s2, c2, 0.0), 1e-9)
        assertEquals(-2.0, roll(s2, c2, 0.0), 1e-9, "anticlockwise")
        // Landscape, top edge on the left, turned 2° clockwise: the left end —
        // the top edge, +y — rises, so up leans towards +y.
        assertEquals(2.0, roll(c2, s2, 0.0), 1e-9)
        assertEquals(-2.0, roll(c2, -s2, 0.0), 1e-9, "anticlockwise")
        // Landscape, top edge on the right, turned 2° clockwise: the right end —
        // the top edge, +y — drops, so up leans away from +y.
        assertEquals(2.0, roll(-c2, -s2, 0.0), 1e-9)
        assertEquals(-2.0, roll(-c2, s2, 0.0), 1e-9, "anticlockwise")
        // The pose helper agrees with these by hand.
        assertTripleEquals(Triple(c2, s2, 0.0), landscapeReading(topEdgeLeft = true, lensDownDeg = 0.0, clockwiseDeg = 2.0))
        assertTripleEquals(Triple(-c2, -s2, 0.0), landscapeReading(topEdgeLeft = false, lensDownDeg = 0.0, clockwiseDeg = 2.0))
    }

    /**
     * Both at once, as a real tripod head sits: aimed down AND off square.
     * Tilt is the lens's angle below the horizon whatever the roll, and roll is
     * the angle of gravity across the screen whatever the tilt, so each reads
     * back exactly.
     */
    @Test
    fun tiltAndRollSeparateInTheFilmingPose() {
        for (topEdgeLeft in listOf(true, false)) {
            for (cw in listOf(-2.0, 2.0)) {
                val (x, y, z) = landscapeReading(topEdgeLeft, lensDownDeg = 10.0, clockwiseDeg = cw)
                val which = if (topEdgeLeft) "top edge left" else "top edge right"
                assertEquals(10.0, tilt(x, y, z), 1e-9, "$which, $cw° clockwise: tilt")
                assertEquals(cw, roll(x, y, z), 1e-9, "$which, $cw° clockwise: roll")
            }
        }
    }

    /**
     * The tilt correction, fed from an Android reading. A ball dead centre in a
     * camera aimed 10° down is really 10° BELOW the horizon, so rectifying must
     * move it down the frame by f·tan 10°. With the adapter's sign backwards it
     * would move up by the same amount — doubling the error instead of removing
     * it, with nothing on screen to show it.
     */
    @Test
    fun aimingDownPushesTheBallBackDownTheFrame() {
        val (x, y, z) = landscapeReading(topEdgeLeft = true, lensDownDeg = 10.0, clockwiseDeg = 0.0)
        val down = tilt(x, y, z)
        val f = TiltRectifier.focalPx(widthPx = 1920.0, fovDeg = 60.0)

        val axis = TiltRectifier.rectify(x = 960.0, y = 540.0, tiltDeg = down,
                                         focalPx = f, cx = 960.0, cy = 540.0)
        assertEquals(540 + f * tan(rad(10.0)), axis.y, 1e-6)

        val r = TiltRectifier.rectify(x = 960.0, y = 300.0, tiltDeg = down,
                                      focalPx = f, cx = 960.0, cy = 540.0)
        assertTrue(r.y > 300, "rectified ball should sit lower in frame")
        val alpha = atan((300.0 - 540) / f)
        assertEquals(540 + f * tan(alpha + rad(10.0)), r.y, 1e-6)
    }

    /**
     * The roll correction, fed from an Android reading, end to end.
     *
     * A camera turned clockwise by c sees the world turned ANTICLOCKWISE by c: a
     * world displacement (X right, Y up) lands in the picture at
     * (X cos c − Y sin c, X sin c + Y cos c), y up. So a ball launched at 20°
     * towards the right of the picture reads 22° from a phone turned 2°
     * clockwise, and one launched towards the left reads 18°. Handed the roll
     * the sensor measured for that pose, the analyzer must give back 20° both
     * ways; with the sign backwards it would give 24° and 16°.
     */
    @Test
    fun aRolledLandscapePhoneGivesBackTheTrueLaunchAngle() {
        for (topEdgeLeft in listOf(true, false)) {
            val (x, y, z) = landscapeReading(topEdgeLeft, lensDownDeg = 0.0, clockwiseDeg = 2.0)
            val sensorRoll = roll(x, y, z)
            for (towardsRight in listOf(true, false)) {
                val track = filmedTrack(launchDeg = 20.0, towardsRight = towardsRight, cameraClockwiseDeg = 2.0)
                val which = (if (topEdgeLeft) "top edge left" else "top edge right") +
                    (if (towardsRight) ", hit to the right" else ", hit to the left")

                val raw = SwingAnalyzer.analyze(track, contactTime = 0.0)
                assertEquals(if (towardsRight) 22.0 else 18.0, raw.launchAngleDeg, 1e-6,
                             "$which: the uncorrected picture is off by the roll")

                val corrected = SwingAnalyzer.analyze(track, contactTime = 0.0, rollDeg = sensorRoll)
                assertEquals(20.0, corrected.launchAngleDeg, 1e-6, "$which: corrected")
            }
        }
    }

    /** A ball launched at [launchDeg], as a camera turned [cameraClockwiseDeg] clockwise films it. */
    private fun filmedTrack(launchDeg: Double, towardsRight: Boolean, cameraClockwiseDeg: Double): List<BallObservation> {
        val speed = 6000.0          // px/s
        val gravityPx = 2450.0      // px/s², world down
        val dir = if (towardsRight) 1.0 else -1.0
        val c = rad(cameraClockwiseDeg)
        return (0 until 24).map { i ->
            val t = i / 240.0
            val wx = dir * speed * cos(rad(launchDeg)) * t
            val wy = speed * sin(rad(launchDeg)) * t - 0.5 * gravityPx * t * t
            val px = wx * cos(c) - wy * sin(c)
            val pyUp = wx * sin(c) + wy * cos(c)
            BallObservation(frame = i, t = t, x = 960 + px, y = 540 - pyUp,
                            diameterPx = 24.0, areaPx = PI * 144)
        }
    }

    @Test
    fun aMisScaledAccelerometerReadsTheSameAngles() {
        // A raw accelerometer a couple of percent off reads 9.6 at rest, not
        // 9.81. The direction is what the maths needs, so the angles must not
        // move.
        val (x, y, z) = landscapeReading(topEdgeLeft = true, lensDownDeg = 10.0, clockwiseDeg = 2.0)
        val k = 9.6 / g0
        assertEquals(10.0, tilt(x * k, y * k, z * k), 1e-9)
        assertEquals(2.0, roll(x * k, y * k, z * k), 1e-9)
        val g = gravity(x * k, y * k, z * k)
        assertEquals(1.0, g.x * g.x + g.y * g.y + g.z * g.z, 1e-12, "a unit vector, as CoreMotion's is")
    }

    @Test
    fun aReadingWithNoDirectionIsNoReading() {
        // "No reading" must never come back looking like "level".
        assertNull(LevelSensor.gravityFromAndroid(0.0, 0.0, 0.0))
        assertNull(LevelSensor.gravityFromAndroid(Double.NaN, g0, 0.0))
        assertNull(LevelSensor.gravityFromAndroid(0.0, Double.POSITIVE_INFINITY, 0.0))
    }

    private fun assertTripleEquals(expected: Triple<Double, Double, Double>, actual: Triple<Double, Double, Double>) {
        assertEquals(expected.first, actual.first, 1e-12, "x")
        assertEquals(expected.second, actual.second, 1e-12, "y")
        assertEquals(expected.third, actual.third, 1e-12, "z")
    }
}
