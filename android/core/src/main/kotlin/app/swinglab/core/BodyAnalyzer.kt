// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Port of `BodyAnalyzer.swift` (sla_common.sagittal_angle_deg / spine_tilt_deg /
 * planar_distance_m / stride_length_m / head_drift_plausible, plus the app-side
 * swing-level selection); the reasoning lives there.
 */
object BodyAnalyzer {

    // Pinned geometry

    /** Port of `BodyAnalyzer.sagittalAngleDeg` (sla_common.sagittal_angle_deg); NaN when degenerate. */
    fun sagittalAngleDeg(a: Point, b: Point, c: Point): Double {
        val v1x = a.x - b.x; val v1y = a.y - b.y
        val v2x = c.x - b.x; val v2y = c.y - b.y
        val n1 = sqrt(v1x * v1x + v1y * v1y)
        val n2 = sqrt(v2x * v2x + v2y * v2y)
        if (!(n1 >= 1e-9) || !(n2 >= 1e-9)) return Double.NaN
        val cosine = (v1x * v2x + v1y * v2y) / (n1 * n2)
        return acos(swiftMax(-1.0, swiftMin(1.0, cosine))) * 180 / PI
    }

    /** Port of `BodyAnalyzer.spineTiltDeg` (sla_common.spine_tilt_deg); signed, NaN when degenerate. */
    fun spineTiltDeg(hip: Point, shoulder: Point): Double {
        val dx = shoulder.x - hip.x
        val dy = shoulder.y - hip.y
        if (!(abs(dx) >= 1e-9 || abs(dy) >= 1e-9)) return Double.NaN
        return atan2(dx, -dy) * 180 / PI
    }

    /** Port of `BodyAnalyzer.planarDistanceM` (sla_common.planar_distance_m). */
    fun planarDistanceM(p: Point, q: Point, scaleMPerPx: Double): Double {
        val dx = q.x - p.x; val dy = q.y - p.y
        return sqrt(dx * dx + dy * dy) * scaleMPerPx
    }

    /** Port of `BodyAnalyzer.strideLengthM` (sla_common.stride_length_m): horizontal, unsigned. */
    fun strideLengthM(loadX: Double, contactX: Double, scaleMPerPx: Double): Double =
        abs(contactX - loadX) * scaleMPerPx

    /** Port of `BodyAnalyzer.headDriftPlausible` (sla_common.head_drift_plausible). */
    fun headDriftPlausible(driftM: Double?): Boolean {
        if (driftM == null) return false
        return driftM <= SLA.headDriftImplausibleM
    }

    // Swing-level measurement

    /** Port of `BodyAnalyzer.loadLeadS`: seconds before contact treated as the loaded position. */
    const val loadLeadS = 0.25

    /** Port of `BodyAnalyzer.analyze(track:contactTime:scaleMPerPx:ballDirectionX:)`; the reasoning lives there. */
    fun analyze(
        track: List<PoseObservation>,
        contactTime: Double,
        scaleMPerPx: Double?,
        ballDirectionX: Double,
    ): BodyMetrics {
        val out = BodyMetrics()
        out.frames = track.size
        if (track.isEmpty()) return out

        // The Swift sorts with `<`; this comparator is that predicate, so ties
        // (and -0.0 against 0.0) keep their order exactly as the stable Swift
        // sort leaves them, where Double.compareTo would split the zeros.
        val sorted = track.sortedWith { p, q -> if (p.t < q.t) -1 else if (q.t < p.t) 1 else 0 }
        val contact = nearest(sorted, contactTime) ?: return out
        val load = nearest(sorted, contactTime - loadLeadS) ?: return out

        val window = sorted.filter { it.t >= load.t - 0.001 && it.t <= contact.t + 0.001 }
        val usable = window.filter { it.midpoint(PoseJoint.leftHip, PoseJoint.rightHip) != null }
        out.coverage = if (window.isEmpty()) 0.0 else usable.size.toDouble() / window.size.toDouble()

        // --- angles (no scale needed) ---
        val front = frontLeg(ballDirectionX, contact)
        val hip = contact.point(front.hip)
        val knee = contact.point(front.knee)
        val ankle = contact.point(front.ankle)
        if (hip != null && knee != null && ankle != null) {
            val angle = sagittalAngleDeg(a = hip, b = knee, c = ankle)
            if (angle.isFinite()) out.frontKneeDeg = angle
        }
        val hipMid = contact.midpoint(PoseJoint.leftHip, PoseJoint.rightHip)
        val shoulderMid = contact.midpoint(PoseJoint.leftShoulder, PoseJoint.rightShoulder)
        if (hipMid != null && shoulderMid != null) {
            val tilt = spineTiltDeg(hip = hipMid, shoulder = shoulderMid)
            if (tilt.isFinite()) out.spineTiltDeg = abs(tilt)
        }

        // --- distances (scale needed) ---
        val scale = scaleMPerPx ?: return out
        if (!(scale > 0) || !scale.isFinite()) return out

        val a0 = load.point(front.ankle)
        val a1 = contact.point(front.ankle)
        if (a0 != null && a1 != null) {
            out.strideM = strideLengthM(loadX = a0.x, contactX = a1.x, scaleMPerPx = scale)
        }
        val heads = headPair(load, contact)
        if (heads != null) {
            val drift = planarDistanceM(heads.first, heads.second, scaleMPerPx = scale)
            if (headDriftPlausible(drift)) out.headDriftM = drift
        }
        val p0 = load.midpoint(PoseJoint.leftHip, PoseJoint.rightHip)
        val p1 = contact.midpoint(PoseJoint.leftHip, PoseJoint.rightHip)
        if (p0 != null && p1 != null) {
            out.weightShiftM = planarDistanceM(p0, p1, scaleMPerPx = scale)
        }
        return out
    }

    /** Port of `BodyAnalyzer.headPair`: nose at both ends, else neck at both ends, never mixed. */
    private fun headPair(a: PoseObservation, b: PoseObservation): Pair<Point, Point>? {
        val n0 = a.point(PoseJoint.nose)
        val n1 = b.point(PoseJoint.nose)
        if (n0 != null && n1 != null) return Pair(n0, n1)
        val k0 = a.point(PoseJoint.neck)
        val k1 = b.point(PoseJoint.neck)
        if (k0 != null && k1 != null) return Pair(k0, k1)
        return null
    }

    /**
     * Port of `BodyAnalyzer.nearest`. Written as Swift's `min(by:)` runs —
     * first of equals wins, and a NaN distance never replaces the incumbent —
     * rather than `minByOrNull`, whose `compareTo` ranks NaN above everything.
     */
    private fun nearest(sorted: List<PoseObservation>, t: Double): PoseObservation? {
        if (sorted.isEmpty()) return null
        var result = sorted[0]
        for (i in 1 until sorted.size) {
            val e = sorted[i]
            if (abs(e.t - t) < abs(result.t - t)) result = e
        }
        return result
    }

    /** The `(hip:, knee:, ankle:)` tuple `frontLeg` returns. */
    private data class Leg(val hip: PoseJoint, val knee: PoseJoint, val ankle: PoseJoint)

    /** Port of `BodyAnalyzer.frontLeg`: the ball's direction picks the lead leg; the reasoning lives there. */
    private fun frontLeg(ballDirectionX: Double, contact: PoseObservation): Leg {
        val left = Leg(PoseJoint.leftHip, PoseJoint.leftKnee, PoseJoint.leftAnkle)
        val right = Leg(PoseJoint.rightHip, PoseJoint.rightKnee, PoseJoint.rightAnkle)

        var direction = ballDirectionX
        if (abs(direction) < 1e-9) {
            val la = contact.point(PoseJoint.leftAnkle) ?: return left
            val ra = contact.point(PoseJoint.rightAnkle) ?: return left
            direction = la.x - ra.x
        }
        val la = contact.point(PoseJoint.leftAnkle) ?: return left
        val ra = contact.point(PoseJoint.rightAnkle) ?: return left
        return if ((la.x - ra.x) * direction > 0) left else right
    }
}
