// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Port of `SwingAnalyzer.swift` `enum SwingAnalyzer` (sla_common.analyze_track); the reasoning lives there. */
object SwingAnalyzer {

    /** Port of `SwingAnalyzer.analyze` (sla_common.analyze_track); the reasoning lives there. */
    fun analyze(
        track: List<BallObservation>,
        contactTime: Double? = null,
        velocityWindowS: Double = SLA.velocityWindowS,
        gravityWindowS: Double = SLA.gravityWindowS,
        rollDeg: Double = 0.0,
    ): SwingMetrics {
        require(track.isNotEmpty()) { "analyze: empty track" }

        val flags = mutableListOf<SwingFlag>()
        val n = track.size
        var t0 = contactTime ?: track[0].t
        if (contactTime != null && track[0].t - t0 > SLA.contactMaxBackExtrapolationS) {
            flags.add(SwingFlag.contactTimeRejected)
            t0 = track[0].t
        }
        val ts = track.map { it.t - t0 }
        val xs = track.map { it.x }
        val ys = track.map { it.y }
        val ds = track.map { it.diameterPx }
        val duration = ts[n - 1] - ts[0]

        if (n < SLA.minTrackFrames) flags.add(SwingFlag.shortTrack)

        // --- velocity fit (short window from t0) ---
        var velSel: List<Int>
        if (duration > velocityWindowS) {
            val cutoff = ts[0] + velocityWindowS
            velSel = (0 until n).filter { ts[it] <= cutoff }
        } else {
            velSel = (0 until n).toList()
        }
        if (velSel.size < 3) velSel = (0 until n).toList()

        val tSel = velSel.map { ts[it] }
        val fitX = Geometry.fitQuadratic(ts = tSel, vs = velSel.map { xs[it] })
        val fitY = Geometry.fitQuadratic(ts = tSel, vs = velSel.map { ys[it] })
        val fitRms = sqrt(fitX.rms * fitX.rms + fitY.rms * fitY.rms)
        if (fitRms > SLA.residualTolPx) flags.add(SwingFlag.highResidual)

        var vx = fitX.b
        var vy = fitY.b     // down-positive

        if (rollDeg != 0.0) {
            val r = rollDeg * PI / 180
            val cosR = cos(r)
            val sinR = sin(r)
            val rx = vx * cosR - vy * sinR
            val ry = vx * sinR + vy * cosR
            vx = rx
            vy = ry
        }

        // --- diameter scale + depth drift ---
        val q = maxOf(2, n / 4)
        val dFirst = Geometry.median(ds.subList(0, minOf(q, n)))
        val dLast = Geometry.median(ds.subList(maxOf(0, n - q), n))
        val diameterDrift = if (dFirst > 0) (dLast - dFirst) / dFirst else 0.0
        if (abs(diameterDrift) > SLA.diameterDriftTol) flags.add(SwingFlag.depthMotion)
        val scaleBall = if (dFirst > 0) SLA.ballDiameterM / dFirst else Double.NaN

        // --- gravity fit (longer window, drag-aware) ---
        val gravCutoff = ts[0] + gravityWindowS
        val gravSel = (0 until n).filter { ts[it] <= gravCutoff }
        var scaleGravity: Double? = null
        if (duration >= SLA.minGravityTrackS && gravSel.size >= 6) {
            val tg = gravSel.map { ts[it] }
            val fitYG = Geometry.fitQuadratic(ts = tg, vs = gravSel.map { ys[it] })
            val fitXG = Geometry.fitQuadratic(ts = tg, vs = gravSel.map { xs[it] })
            val ay = 2.0 * fitYG.a                      // px/s^2, down-positive
            val tm = (tg[0] + tg[tg.size - 1]) / 2.0
            val vxMid = 2.0 * fitXG.a * tm + fitXG.b
            val vyMid = 2.0 * fitYG.a * tm + fitYG.b
            scaleGravity = Geometry.solveGravityScale(
                ayPx = ay,
                vxPxMid = vxMid,
                vyPxMid = vyMid,
                scaleHint = scaleBall,
            )
        }
        if (scaleGravity == null) flags.add(SwingFlag.noGravityCheck)

        var disagreement: Double? = null
        if (scaleGravity != null && scaleBall > 0) {
            val d = abs(scaleGravity - scaleBall) / scaleBall
            disagreement = d
            if (d > SLA.scaleDisagreeTol) flags.add(SwingFlag.scaleDisagree)
        }

        // --- metrics (launch angle up-positive regardless of hit direction) ---
        val la = atan2(-vy, abs(vx)) * 180 / PI
        val speedMps = sqrt(vx * vx + vy * vy) * scaleBall

        return SwingMetrics(
            launchAngleDeg = la,
            exitVeloMph = speedMps * SLA.mphPerMps,
            exitVeloMps = speedMps,
            scaleBallMPerPx = scaleBall,
            scaleGravityMPerPx = scaleGravity,
            scaleDisagreement = disagreement,
            diameterDrift = diameterDrift,
            nFrames = n,
            trackDurationS = duration,
            fitRmsPx = fitRms,
            t0 = t0,
            vxPxS = vx,
            vyPxS = vy,
            x0Px = fitX.c,
            y0Px = fitY.c,
            flags = flags.toList(),
        )
    }
}
