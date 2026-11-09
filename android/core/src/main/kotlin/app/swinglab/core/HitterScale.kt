// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Port of `HitterScale.swift` `enum HitterScale` (camera distance from the
 * hitter's own nose-to-ankle span; app-only, no sla_common counterpart); the
 * reasoning lives there. The proportion it rests on is not validated.
 */
object HitterScale {

    /** Port of `HitterScale.noseToAnkleStatureFraction` (Drillis–Contini, unvalidated). */
    const val noseToAnkleStatureFraction = 0.87

    /** Port of `HitterScale.minKneeDeg`. */
    const val minKneeDeg = 160.0

    /** Port of `HitterScale.maxSpineLeanDeg`. */
    const val maxSpineLeanDeg = 12.0

    /** Port of `HitterScale.samplesNeeded`. */
    const val samplesNeeded = 5

    /** Port of `HitterScale.windowS` (a `TimeInterval`, seconds). */
    const val windowS: Double = 3.0

    /** Port of `HitterScale.heightCmRange`. */
    val heightCmRange: ClosedFloatingPointRange<Double> = 120.0..230.0

    /** Port of `HitterScale.Rejection`: why a sample was refused. */
    enum class Rejection { outOfFrame, knees, leaning }

    /**
     * Port of `HitterScale.Verdict`. The Swift enum cases keep their lower-case
     * names so call sites read `Verdict.accepted(spanPx)` / `Verdict.rejected(Rejection.knees)`.
     */
    sealed class Verdict {
        data class accepted(val spanPx: Double) : Verdict()
        data class rejected(val reason: Rejection) : Verdict()
    }

    // Coordinates

    /** Port of `HitterScale.uprightPixels(_:orientation:widthPx:heightPx:)`: scale first, then make upright; null in portrait. */
    fun uprightPixels(
        joints: Map<PoseJoint, Point>,
        orientation: ImagePropertyOrientation,
        widthPx: Double,
        heightPx: Double,
    ): Map<PoseJoint, Point>? {
        if (!(widthPx > 0) || !(heightPx > 0)) return null
        CameraPose.uprightBufferPoint(Point.zero, orientation, widthPx, heightPx) ?: return null
        val out = LinkedHashMap<PoseJoint, Point>(joints.size)
        for ((joint, p) in joints) {
            val px = Point(p.x * widthPx, p.y * heightPx)
            val upright = CameraPose.uprightBufferPoint(px, orientation, widthPx, heightPx) ?: return null
            out[joint] = upright
        }
        return out
    }

    // The gate

    /** Port of `HitterScale.evaluate(upright:tiltDeg:focalPx:cx:cy:)`: every joint rectified before any angle or length. */
    fun evaluate(
        upright: Map<PoseJoint, Point>,
        tiltDeg: Double,
        focalPx: Double,
        cx: Double,
        cy: Double,
    ): Verdict {
        val r = LinkedHashMap<PoseJoint, Point>(upright.size)
        for ((joint, p) in upright) {
            val t = TiltRectifier.rectify(x = p.x, y = p.y, tiltDeg = tiltDeg, focalPx = focalPx, cx = cx, cy = cy)
            r[joint] = Point(t.x, t.y)
        }

        val outOfFrame = Verdict.rejected(Rejection.outOfFrame)
        val nose = r[PoseJoint.nose] ?: return outOfFrame
        val leftHip = r[PoseJoint.leftHip] ?: return outOfFrame
        val rightHip = r[PoseJoint.rightHip] ?: return outOfFrame
        val leftShoulder = r[PoseJoint.leftShoulder] ?: return outOfFrame
        val rightShoulder = r[PoseJoint.rightShoulder] ?: return outOfFrame

        val ankles = listOfNotNull(r[PoseJoint.leftAnkle], r[PoseJoint.rightAnkle])
        if (ankles.isEmpty()) return outOfFrame

        val midHip = midpoint(leftHip, rightHip)
        val midShoulder = midpoint(leftShoulder, rightShoulder)
        if (!(nose.y < midShoulder.y && midShoulder.y < midHip.y)) return outOfFrame

        fun kneeAngle(hip: PoseJoint, knee: PoseJoint, ankle: PoseJoint): Double? {
            val h = r[hip] ?: return null
            val k = r[knee] ?: return null
            val a = r[ankle] ?: return null
            return BodyAnalyzer.sagittalAngleDeg(a = h, b = k, c = a)
        }
        val knees = listOfNotNull(
            kneeAngle(PoseJoint.leftHip, PoseJoint.leftKnee, PoseJoint.leftAnkle),
            kneeAngle(PoseJoint.rightHip, PoseJoint.rightKnee, PoseJoint.rightAnkle),
        )
        if (knees.isEmpty() || !knees.all { it.isFinite() }) return outOfFrame
        if (!knees.all { it >= minKneeDeg }) return Verdict.rejected(Rejection.knees)

        val lean = BodyAnalyzer.spineTiltDeg(hip = midHip, shoulder = midShoulder)
        if (!lean.isFinite()) return outOfFrame
        if (!(abs(lean) <= maxSpineLeanDeg)) return Verdict.rejected(Rejection.leaning)

        val ankleX = ankles.fold(0.0) { acc, p -> acc + p.x } / ankles.size.toDouble()
        val ankleY = ankles.fold(0.0) { acc, p -> acc + p.y } / ankles.size.toDouble()
        val span = hypot(nose.x - ankleX, nose.y - ankleY)
        if (!span.isFinite() || !(span > 1)) return outOfFrame
        return Verdict.accepted(spanPx = span)
    }

    private fun midpoint(a: Point, b: Point): Point = Point((a.x + b.x) / 2, (a.y + b.y) / 2)

    // Optics

    /** Port of `HitterScale.pxPerM(spanPx:hitterHeightM:)`. */
    fun pxPerM(spanPx: Double, hitterHeightM: Double): Double {
        val reference = hitterHeightM * noseToAnkleStatureFraction
        if (!(reference > 0)) return 0.0
        return spanPx / reference
    }

    /** Port of `HitterScale.distanceM(spanPx:hitterHeightM:focalPx:)`: `d = focal × H_span / span_px`. */
    fun distanceM(spanPx: Double, hitterHeightM: Double, focalPx: Double): Double? {
        if (!(spanPx > 1) || !(focalPx > 0) || !(hitterHeightM > 0)) return null
        val scale = pxPerM(spanPx = spanPx, hitterHeightM = hitterHeightM)
        if (!(scale > 0)) return null
        val d = focalPx / scale
        if (!d.isFinite()) return null
        return d
    }

    /** Port of `HitterScale.median(_:)`: median, not mean, so one wild frame cannot carry the answer. */
    fun median(v: List<Double>): Double? {
        if (v.isEmpty()) return null
        val s = v.sorted()
        val mid = s.size / 2
        if (s.size % 2 == 1) return s[mid]
        return (s[mid - 1] + s[mid]) / 2
    }

    // Sampling

    /** Port of `HitterScale.Sample`: one accepted span and when it was taken. */
    data class Sample(val t: Double, val spanPx: Double)

    /**
     * Port of `HitterScale.Sampler`, a rolling window of accepted samples.
     *
     * The Swift is a value type. This is a class, so two references share one
     * window; [samples] is replaced on every change rather than mutated in
     * place, so a list read out of it never changes underneath its reader, and
     * equality is by contents as the Swift's `Equatable` is.
     */
    class Sampler {
        var samples: List<Sample> = emptyList()
            private set

        fun add(spanPx: Double, at: Double) {
            val t = at
            samples = (samples + Sample(t = t, spanPx = spanPx)).filterNot { t - it.t > windowS }
        }

        fun count(at: Double): Int = live(at).size

        /** Port of `Sampler.medianIfReady(at:)`: null until the window holds enough samples. */
        fun medianIfReady(at: Double): Double? {
            val spans = live(at)
            if (spans.size < samplesNeeded) return null
            return median(spans)
        }

        fun reset() {
            samples = emptyList()
        }

        private fun live(t: Double): List<Double> =
            samples.filter { t - it.t <= windowS }.map { it.spanPx }

        override fun equals(other: Any?): Boolean = other is Sampler && other.samples == samples
        override fun hashCode(): Int = samples.hashCode()
        override fun toString(): String = "Sampler(samples=$samples)"
    }
}
