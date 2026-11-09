// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.tan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/** Port of `app/Tests/HitterScaleTests.swift`. */
class HitterScaleTest {

    // A typical iPhone wide lens on a 1080p240 buffer.
    private val fov = 68.0
    private val widthPx = 1920.0
    private val heightPx = 1080.0
    private val focal: Double get() = TiltRectifier.focalPx(widthPx = widthPx, fovDeg = fov)
    private val cx: Double get() = widthPx / 2
    private val cy: Double get() = heightPx / 2

    private val hitterHeightM = 1.75
    private val distanceM = 5.25

    private val expectedSpanPx: Double
        get() = focal * hitterHeightM * HitterScale.noseToAnkleStatureFraction / distanceM

    // A synthetic hitter

    private fun skeleton(
        spanPx: Double,
        kneeOffset: Double = 0.0,
        leanDx: Double = 0.0,
        includeAnkles: Boolean = true,
    ): Map<PoseJoint, Point> {
        val top = cy - spanPx / 2
        val footY = cy + spanPx / 2
        val shoulderY = top + 0.10 * spanPx
        val hipY = top + 0.45 * spanPx
        val kneeY = top + 0.72 * spanPx
        val joints = linkedMapOf(
            PoseJoint.nose to Point(cx, top),
            PoseJoint.leftShoulder to Point(cx - 70 + leanDx, shoulderY),
            PoseJoint.rightShoulder to Point(cx + 70 + leanDx, shoulderY),
            PoseJoint.leftHip to Point(cx - 20, hipY),
            PoseJoint.rightHip to Point(cx + 20, hipY),
            PoseJoint.leftKnee to Point(cx - 20 + kneeOffset, kneeY),
            PoseJoint.rightKnee to Point(cx + 20 + kneeOffset, kneeY),
        )
        if (includeAnkles) {
            joints[PoseJoint.leftAnkle] = Point(cx - 20, footY)
            joints[PoseJoint.rightAnkle] = Point(cx + 20, footY)
        }
        return joints
    }

    private fun acceptedSpan(joints: Map<PoseJoint, Point>, tiltDeg: Double = 0.0): Double {
        val verdict = HitterScale.evaluate(upright = joints, tiltDeg = tiltDeg, focalPx = focal, cx = cx, cy = cy)
        if (verdict !is HitterScale.Verdict.accepted) fail("expected an accepted sample, got $verdict")
        return verdict.spanPx
    }

    // The gate

    @Test
    fun standingTallIsAccepted() {
        val span = acceptedSpan(skeleton(spanPx = expectedSpanPx))
        assertEquals(expectedSpanPx, span, 1e-6)
    }

    @Test
    fun bentKneesAreRejected() {
        val joints = skeleton(spanPx = expectedSpanPx, kneeOffset = 0.16 * expectedSpanPx)   // ~120° at the knee
        assertEquals(
            HitterScale.Verdict.rejected(HitterScale.Rejection.knees),
            HitterScale.evaluate(upright = joints, tiltDeg = 0.0, focalPx = focal, cx = cx, cy = cy),
        )
    }

    @Test
    fun leaningIsRejected() {
        // 25° of spine lean: shoulders pushed forward of the hips.
        val joints = skeleton(spanPx = expectedSpanPx, leanDx = tan(25 * PI / 180) * 0.35 * expectedSpanPx)
        assertEquals(
            HitterScale.Verdict.rejected(HitterScale.Rejection.leaning),
            HitterScale.evaluate(upright = joints, tiltDeg = 0.0, focalPx = focal, cx = cx, cy = cy),
        )
    }

    @Test
    fun missingAnklesAreOutOfFrame() {
        val joints = skeleton(spanPx = expectedSpanPx, includeAnkles = false)
        assertEquals(
            HitterScale.Verdict.rejected(HitterScale.Rejection.outOfFrame),
            HitterScale.evaluate(upright = joints, tiltDeg = 0.0, focalPx = focal, cx = cx, cy = cy),
        )
    }

    // Optics

    @Test
    fun distanceRoundTrips() {
        val d = assertNotNull(HitterScale.distanceM(spanPx = expectedSpanPx, hitterHeightM = hitterHeightM, focalPx = focal))
        assertEquals(distanceM, d, 1e-6)
    }

    @Test
    fun tiltIsUndoneBeforeTheSpanIsMeasured() {
        val tilt = 12.0
        val tilted = LinkedHashMap<PoseJoint, Point>()
        for ((joint, p) in skeleton(spanPx = expectedSpanPx)) {
            val r = TiltRectifier.rectify(x = p.x, y = p.y, tiltDeg = -tilt, focalPx = focal, cx = cx, cy = cy)
            tilted[joint] = Point(r.x, r.y)
        }

        val rawSpan = acceptedSpan(tilted, tiltDeg = 0.0)
        val rawDistance = assertNotNull(HitterScale.distanceM(spanPx = rawSpan, hitterHeightM = hitterHeightM, focalPx = focal))
        assertTrue(abs(rawDistance - distanceM) / distanceM > 0.03,
            "an uncorrected 12° tilt must miss by more than the test's own tolerance")

        val corrected = acceptedSpan(tilted, tiltDeg = tilt)
        val d = assertNotNull(HitterScale.distanceM(spanPx = corrected, hitterHeightM = hitterHeightM, focalPx = focal))
        assertEquals(distanceM, d, distanceM * 0.005)
    }

    // Orientation

    private fun normalized(joints: Map<PoseJoint, Point>): Map<PoseJoint, Point> =
        joints.mapValues { (_, p) -> Point(p.x / widthPx, p.y / heightPx) }

    @Test
    fun bothLandscapesGiveTheSameSpan() {
        val upright = skeleton(spanPx = expectedSpanPx)
        val up = assertNotNull(HitterScale.uprightPixels(normalized(upright), orientation = ImagePropertyOrientation.up,
            widthPx = widthPx, heightPx = heightPx))
        val flipped = normalized(upright).mapValues { (_, p) -> Point(1 - p.x, 1 - p.y) }
        val down = assertNotNull(HitterScale.uprightPixels(flipped, orientation = ImagePropertyOrientation.down,
            widthPx = widthPx, heightPx = heightPx))
        val upSpan = acceptedSpan(up)
        val downSpan = acceptedSpan(down)
        assertEquals(expectedSpanPx, upSpan, 1e-6)
        assertEquals(upSpan, downSpan, 1e-6)
    }

    @Test
    fun portraitHasNoReading() {
        val joints = normalized(skeleton(spanPx = expectedSpanPx))
        assertNull(HitterScale.uprightPixels(joints, orientation = ImagePropertyOrientation.right,
            widthPx = widthPx, heightPx = heightPx))
        assertNull(HitterScale.uprightPixels(joints, orientation = ImagePropertyOrientation.left,
            widthPx = widthPx, heightPx = heightPx))
    }

    // Sampling

    @Test
    fun samplerHoldsOutUntilItHasEnough() {
        val sampler = HitterScale.Sampler()
        for (i in 0 until 4) sampler.add(spanPx = 400 + i.toDouble(), at = i.toDouble() * 0.1)
        assertEquals(4, sampler.count(at = 0.3))
        assertNull(sampler.medianIfReady(at = 0.3))

        sampler.add(spanPx = 402.0, at = 0.4)
        val median = assertNotNull(sampler.medianIfReady(at = 0.4))
        assertEquals(402.0, median, 1e-9)
    }

    @Test
    fun medianIgnoresOneWildSample() {
        val sampler = HitterScale.Sampler()
        for (span in listOf(410.0, 412.0, 411.0, 9000.0, 413.0)) {
            sampler.add(spanPx = span, at = 0.0)
        }
        val median = assertNotNull(sampler.medianIfReady(at = 0.0))
        assertEquals(412.0, median, 1e-9)
    }

    @Test
    fun samplesOlderThanTheWindowArePruned() {
        val sampler = HitterScale.Sampler()
        for (i in 0 until 5) sampler.add(spanPx = 410.0, at = i.toDouble() * 0.1)
        assertNotNull(sampler.medianIfReady(at = 0.4))
        // Four seconds later, every one of them has aged out.
        sampler.add(spanPx = 410.0, at = 4.4)
        assertEquals(1, sampler.count(at = 4.4))
        assertNull(sampler.medianIfReady(at = 4.4))
    }

    @Test
    fun resetEmptiesTheWindow() {
        val sampler = HitterScale.Sampler()
        for (i in 0 until 5) sampler.add(spanPx = 410.0, at = i.toDouble() * 0.1)
        sampler.reset()
        assertEquals(0, sampler.count(at = 0.5))
        assertNull(sampler.medianIfReady(at = 0.5))
    }

    // Kotlin-only: the Swift Sampler is Equatable by value, which the wizard's
    // state comparison relies on; a Kotlin class would otherwise compare by
    // identity.

    @Test
    fun samplersWithTheSameSamplesAreEqual() {
        val a = HitterScale.Sampler()
        val b = HitterScale.Sampler()
        a.add(spanPx = 410.0, at = 0.1)
        b.add(spanPx = 410.0, at = 0.1)
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        b.add(spanPx = 411.0, at = 0.2)
        assertTrue(a != b)
    }
}
