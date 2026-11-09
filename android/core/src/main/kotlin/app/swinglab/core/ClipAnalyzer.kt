// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Port of `ClipAnalyzer.swift` `enum ClipAnalysisError`; the reasoning lives
 * there. Case names are the Swift's, so `.readerFailed(why)` reads
 * `ClipAnalysisError.readerFailed(why)`. [errorDescription] is the text the
 * diagnostics report's `result FAILED —` line carries.
 */
@Suppress("ClassName")
sealed class ClipAnalysisError : Exception() {
    data object noVideoTrack : ClipAnalysisError()
    data class readerFailed(val why: String) : ClipAnalysisError()
    data object noBallTrack : ClipAnalysisError()
    data object noBallAtSeed : ClipAnalysisError()

    val errorDescription: String
        get() = when (this) {
            noVideoTrack ->
                "That clip has no video track."
            is readerFailed ->
                "Could not read the clip: $why"
            noBallAtSeed ->
                "No ball was detected where you tapped. That is a DETECTION problem, not a tracking one — the colour or size gates are excluding it there. Try a frame where the ball is against the sky or the trees rather than the grass, or widen the ball colour range in Settings."
            noBallTrack ->
                "No ball flight found in this clip. Check that the ball is optic yellow and in frame, or widen the colour range in Settings."
        }

    /** Swift's `error.localizedDescription` for a `LocalizedError`. */
    override val message: String get() = errorDescription
}

/**
 * Port of the pure parts of `ClipAnalyzer.swift` `enum ClipAnalyzer`: the
 * diagnostics it writes into the trace. The reasoning lives there. The decode
 * passes and `analyze` belong to the app layer; the frame-rate estimator is in
 * FrameTiming.kt.
 */
object ClipAnalyzer {

    /** Port of `ClipAnalyzer.explainUnjoined(chains:)`; the reasoning lives there. */
    fun explainUnjoined(chains: List<List<BallObservation>>): List<String> {
        val fastScored = chains.mapNotNull { tr ->
            val f = tr.firstOrNull() ?: return@mapNotNull null
            val l = tr.lastOrNull() ?: return@mapNotNull null
            if (!(l.t > f.t)) return@mapNotNull null
            val s = sqrt((l.x - f.x) * (l.x - f.x) + (l.y - f.y) * (l.y - f.y)) / (l.t - f.t)
            if (s >= 800) s to tr else null
        }
        // Swift's `sorted { $0.speed > $1.speed }`, written as that predicate.
        val fast = fastScored
            .sortedWith { p, q -> if (p.first > q.first) -1 else if (q.first > p.first) 1 else 0 }
            .take(6)
            .map { it.second }

        val out = mutableListOf<String>()
        for (a in fast) {
            for (b in fast) {
                val aLast = a.lastOrNull() ?: continue
                val bFirst = b.firstOrNull() ?: continue
                val aFirst = a.firstOrNull() ?: continue
                if (!(bFirst.t > aLast.t && bFirst.t - aLast.t < 0.4)) continue
                val gap = bFirst.t - aLast.t
                val head = "${formatFixed(aFirst.t, 2)}–${formatFixed(aLast.t, 2)}s → " +
                    "${formatFixed(bFirst.t, 2)}s  gap ${formatFixed(gap * 1000, 0)}ms: "
                out.add(head + stitchRefusal(a, b, gap))
                if (out.size >= 8) return out
            }
        }
        return out
    }

    /** Port of `ClipAnalyzer.stitchRefusal`; the reasoning lives there. */
    private fun stitchRefusal(a: List<BallObservation>, b: List<BallObservation>, gap: Double): String {
        if (gap > SLA.stitchMaxGapS) {
            return "gap over the ${formatFixed(SLA.stitchMaxGapS * 1000, 0)}ms stitch limit"
        }
        val aLast = a.lastOrNull()
        val bFirst = b.firstOrNull()
        if (aLast == null || bFirst == null) return "empty track"
        val va = TrackBuilder.endVelocityForDiagnostics(a)
        val vb = TrackBuilder.startVelocityForDiagnostics(b)
        val speedA = sqrt(va.vx * va.vx + va.vy * va.vy)
        val speedB = sqrt(vb.vx * vb.vx + vb.vy * vb.vy)
        if (!(speedA > 1e-9 && speedB > 1e-9)) return "an endpoint has no measurable velocity"
        val diameters = (a.map { it.diameterPx } + b.map { it.diameterPx }).sorted()
        val medianD = diameters[diameters.size / 2]
        if (!(medianD > 1e-9)) return "no measurable ball size"
        val gPx = SLA.g * medianD / SLA.ballDiameterM

        val jx = vb.vx - va.vx
        val jy = vb.vy - va.vy
        val jump = sqrt(jx * jx + jy * jy)
        val jumpLimit = SLA.stitchAccelK * gPx * gap + SLA.stitchVelocityNoisePxS
        if (jump > jumpLimit) {
            return "velocity jumps ${formatFixed(jump, 0)} px/s — gravity allows ${formatFixed(jumpLimit, 0)}"
        }
        val hopX = bFirst.x - aLast.x
        val hopY = bFirst.y - aLast.y
        val hop = sqrt(hopX * hopX + hopY * hopY)
        if (hop > 4.0) {
            val coshop = (va.vx * hopX + va.vy * hopY) / (speedA * hop)
            val hopAngle = acos(swiftMax(-1.0, swiftMin(1.0, coshop))) * 180 / PI
            if (hopAngle > SLA.stitchMaxAngleDeg) {
                return "the two sit ${formatFixed(hopAngle, 0)}° apart, not along the flight"
            }
        }
        val predX = aLast.x + va.vx * gap
        val predY = aLast.y + va.vy * gap + 0.5 * gPx * gap * gap
        val tol = SLA.stitchBaseTolPx + SLA.stitchTolPxPerS * speedA * gap
        val dx = bFirst.x - predX
        val dy = bFirst.y - predY
        val err = sqrt(dx * dx + dy * dy)
        if (err > tol) {
            return "lands ${formatFixed(err, 0)}px from the prediction (tolerance ${formatFixed(tol, 0)})"
        }
        return "JOINABLE at ${formatFixed(err, 0)}px — yet not joined; report this"
    }

    /** Port of `ClipAnalyzer.summarise(tracks:selected:direction:contactTime:)`; the reasoning lives there. */
    fun summarise(
        tracks: List<List<BallObservation>>,
        selected: List<BallObservation>?,
        direction: TrackBuilder.Direction,
        contactTime: Double?,
    ): List<DetectionTrace.TrackSummary> {
        val out = mutableListOf<DetectionTrace.TrackSummary>()
        for (tr in tracks) {
            val first = tr.firstOrNull() ?: continue
            val last = tr.lastOrNull() ?: continue
            val dt = last.t - first.t
            val dx = last.x - first.x
            val speed = TrackBuilder.medianStepSpeed(tr) ?: 0.0
            val straight = TrackBuilder.straightness(tr)
            val nearContact = contactTime?.let {
                first.t >= it - SLA.selectContactTolS && first.t <= it + SLA.selectContactLateS
            } ?: false
            val minLen = if (nearContact) SLA.nearContactMinFrames else SLA.minTrackFrames
            val isSelected = selected?.let {
                it.firstOrNull()?.frame == first.frame &&
                    it.lastOrNull()?.frame == last.frame && it.size == tr.size
            } ?: false

            var reason = ""
            if (!isSelected) {
                reason = if (tr.size < minLen) {
                    "only ${tr.size} frames, needs $minLen" + (if (nearContact) " even at contact" else "")
                } else if (dt <= 0) {
                    "no elapsed time"
                } else if (straight < SLA.trackStraightnessMin) {
                    "wanders — straightness ${formatFixed(straight, 2)}, needs ${formatFixed(SLA.trackStraightnessMin, 2)}"
                } else if (direction != TrackBuilder.Direction.auto &&
                    (dx > 0) != (direction == TrackBuilder.Direction.right)) {
                    "travels the wrong way for a hit"
                } else {
                    "slower than the chosen track"
                }
            }

            val stride = max(1, tr.size / DetectionTrace.trackPointLimit)
            val pts = if (stride == 1) tr else tr.filterIndexed { i, _ -> i % stride == 0 }
            out.add(DetectionTrace.TrackSummary(
                frames = tr.size, startT = first.t, endT = last.t,
                speedPxS = speed, straightness = straight,
                selected = isSelected, rejectedBecause = reason,
                points = pts.map { DetectionTrace.TrackSummary.Point(x = it.x, y = it.y) },
            ))
        }
        // Swift's `sort` with its two-key predicate, written as that predicate.
        fun before(p: DetectionTrace.TrackSummary, q: DetectionTrace.TrackSummary): Boolean =
            if (p.selected != q.selected) p.selected else p.speedPxS > q.speedPxS
        out.sortWith { p, q -> if (before(p, q)) -1 else if (before(q, p)) 1 else 0 }
        return out.take(DetectionTrace.trackSummaryLimit)
    }
}
