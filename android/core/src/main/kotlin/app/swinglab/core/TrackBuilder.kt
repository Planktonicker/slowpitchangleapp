// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * Port of `TrackBuilder.swift` `enum TrackBuilder` (sla_common.build_tracks /
 * stitch_tracks / track_from_seed / track_straightness / select_outbound_track);
 * the reasoning lives there.
 */
object TrackBuilder {

    /** The unnamed `(vx, vy)` tuple, px/s, that the Swift velocity helpers return. */
    data class Velocity(val vx: Double, val vy: Double)

    /** Port of `TrackBuilder.buildTracks` (sla_common.build_tracks); the reasoning lives there. */
    fun buildTracks(
        perFrame: Map<Int, List<BallObservation>>,
        fps: Double,
        baseGatePx: Double = 40.0,
        maxCoastFrames: Int = 3,
        minLen: Int = 4,
    ): List<List<BallObservation>> {
        var active: MutableList<MutableList<BallObservation>> = mutableListOf()
        val done: MutableList<List<BallObservation>> = mutableListOf()

        for (f in perFrame.keys.sorted()) {
            val cands = perFrame[f] ?: emptyList()
            val claimed = BooleanArray(cands.size)

            val pairs: MutableList<BuildPair> = mutableListOf()
            for (ti in active.indices) {
                val obs = active[ti]
                val last = obs.lastOrNull() ?: continue
                val gap = f - last.frame
                if (gap <= 0 || gap > maxCoastFrames + 1) continue

                var vx = 0.0
                var vy = 0.0
                if (obs.size >= 2) {
                    val prev = obs[obs.size - 2]
                    val dt = last.t - prev.t
                    if (dt > 0) {
                        vx = (last.x - prev.x) / dt
                        vy = (last.y - prev.y) / dt
                    }
                }
                val predX = last.x + vx * gap.toDouble() / fps
                val predY = last.y + vy * gap.toDouble() / fps
                val speed = sqrt(vx * vx + vy * vy)
                val speedPxPerFrame = speed / fps
                val gate = swiftMax(baseGatePx, 2.5 * speedPxPerFrame) * gap.toDouble()
                val head = segmentVelocity(obs.takeLast(SLA.buildHeadingWindow))
                val headingSpeed = sqrt(head.vx * head.vx + head.vy * head.vy)
                val heading = headingSpeed / fps >= SLA.buildTurnMinStepPx
                val cosMax = cos(SLA.buildMaxTurnDeg * PI / 180)

                val inGate: MutableList<GatePair> = mutableListOf()
                for ((ci, c) in cands.withIndex()) {
                    val d = sqrt((c.x - predX) * (c.x - predX) +
                        (c.y - predY) * (c.y - predY))
                    if (d < gate) inGate.add(GatePair(d, ci))
                }
                inGate.sortWith { p, q ->
                    if (p.d != q.d) (if (p.d < q.d) -1 else 1) else p.ci.compareTo(q.ci)
                }

                if (heading && inGate.isNotEmpty()) {
                    val best = inGate.first()
                    val c0 = cands[best.ci]
                    val sx = c0.x - last.x
                    val sy = c0.y - last.y
                    val step = sqrt(sx * sx + sy * sy)
                    if (step > 1e-9 &&
                        (sx * head.vx + sy * head.vy) / (step * headingSpeed) < cosMax
                    ) {
                        continue
                    }
                }

                for (g in inGate) pairs.add(BuildPair(g.d, ti, g.ci))
            }
            pairs.sortWith { p, q ->
                if (p.d != q.d) {
                    if (p.d < q.d) -1 else 1
                } else if (p.ti != q.ti) {
                    p.ti.compareTo(q.ti)
                } else {
                    p.ci.compareTo(q.ci)
                }
            }
            val matchedTracks = HashSet<Int>()
            for (p in pairs) {
                if (matchedTracks.contains(p.ti) || claimed[p.ci]) continue
                active[p.ti].add(cands[p.ci])
                claimed[p.ci] = true
                matchedTracks.add(p.ti)
            }

            val still: MutableList<MutableList<BallObservation>> = mutableListOf()
            for (tr in active) {
                val last = tr.lastOrNull()
                if (last != null && f - last.frame > maxCoastFrames) {
                    if (tr.size >= minLen) done.add(tr)
                } else {
                    still.add(tr)
                }
            }
            active = still

            for ((i, c) in cands.withIndex()) {
                if (!claimed[i]) active.add(mutableListOf(c))
            }
        }

        for (tr in active) if (tr.size >= minLen) done.add(tr)
        return done
    }

    /** The Swift `(d, ci)` tuple of `buildTracks`. */
    private data class GatePair(val d: Double, val ci: Int)

    /** The Swift `(d, ti, ci)` tuple of `buildTracks`. */
    private data class BuildPair(val d: Double, val ti: Int, val ci: Int)

    /** Port of `TrackBuilder.Direction`; the reasoning lives there. */
    enum class Direction(val raw: String) {
        auto("auto"),
        left("left"),
        right("right");

        companion object {
            fun fromRaw(raw: String): Direction? = entries.firstOrNull { it.raw == raw }
        }
    }

    /** Port of `TrackBuilder.segmentVelocity` (sla_common._segment_velocity); the reasoning lives there. */
    private fun segmentVelocity(seg: List<BallObservation>): Velocity {
        val n = seg.size
        if (n < 2) return Velocity(0.0, 0.0)
        var acc = 0.0
        for (o in seg) acc += o.t
        val meanT = acc / n.toDouble()
        acc = 0.0
        for (o in seg) acc += (o.t - meanT) * (o.t - meanT)
        val varT = acc
        // `guard varT > 1e-12`: written negated so a NaN takes the early exit, as in the Swift.
        if (!(varT > 1e-12)) return Velocity(0.0, 0.0)
        var ax = 0.0
        var ay = 0.0
        for (o in seg) {
            ax += (o.t - meanT) * o.x
            ay += (o.t - meanT) * o.y
        }
        return Velocity(ax / varT, ay / varT)
    }

    /** Port of `TrackBuilder.endVelocity` (sla_common._track_end_velocity); the reasoning lives there. */
    fun endVelocity(tr: List<BallObservation>): Velocity =
        segmentVelocity(tr.takeLast(SLA.stitchVelocityWindow))

    /** Port of `TrackBuilder.startVelocity` (sla_common._track_start_velocity); the reasoning lives there. */
    fun startVelocity(tr: List<BallObservation>): Velocity =
        segmentVelocity(tr.take(SLA.stitchVelocityWindow))

    /** Port of `TrackBuilder.endVelocityForDiagnostics`; the reasoning lives there. */
    fun endVelocityForDiagnostics(tr: List<BallObservation>): Velocity = endVelocity(tr)

    /** Port of `TrackBuilder.startVelocityForDiagnostics`; the reasoning lives there. */
    fun startVelocityForDiagnostics(tr: List<BallObservation>): Velocity = startVelocity(tr)

    /** Port of `TrackBuilder.stitchError` (sla_common._stitch_error); the reasoning lives there. */
    fun stitchError(a: List<BallObservation>, b: List<BallObservation>): Double? {
        val aLast = a.lastOrNull() ?: return null
        val bFirst = b.firstOrNull() ?: return null
        val gap = bFirst.t - aLast.t
        if (!(gap > 0 && gap <= SLA.stitchMaxGapS)) return null
        val va = endVelocity(a)
        val vb = startVelocity(b)
        val speedA = sqrt(va.vx * va.vx + va.vy * va.vy)
        val speedB = sqrt(vb.vx * vb.vx + vb.vy * vb.vy)
        if (!(speedA > 1e-9 && speedB > 1e-9)) return null
        val diameters = (a.map { it.diameterPx } + b.map { it.diameterPx }).sorted()
        val medianD = diameters[diameters.size / 2]
        if (!(medianD > 1e-9)) return null
        val gPx = SLA.g * medianD / SLA.ballDiameterM

        val jx = vb.vx - va.vx
        val jy = vb.vy - va.vy
        val jump = sqrt(jx * jx + jy * jy)
        if (!(jump <= SLA.stitchAccelK * gPx * gap + SLA.stitchVelocityNoisePxS)) return null

        val hopX = bFirst.x - aLast.x
        val hopY = bFirst.y - aLast.y
        val hop = sqrt(hopX * hopX + hopY * hopY)
        if (hop > 4.0) {
            val coshop = (va.vx * hopX + va.vy * hopY) / (speedA * hop)
            if (!(coshop >= cos(SLA.stitchMaxAngleDeg * PI / 180))) return null
        }

        val predX = aLast.x + va.vx * gap
        val predY = aLast.y + va.vy * gap + 0.5 * gPx * gap * gap
        val tol = SLA.stitchBaseTolPx + SLA.stitchTolPxPerS * speedA * gap
        val dx = bFirst.x - predX
        val dy = bFirst.y - predY
        val err = sqrt(dx * dx + dy * dy)
        return if (err <= tol) err else null
    }

    /** Port of `TrackBuilder.stitchTracks` (sla_common.stitch_tracks); the reasoning lives there. */
    fun stitchTracks(tracks: List<List<BallObservation>>): List<List<BallObservation>> {
        // The Swift sort predicate as a comparator. Both sorts are stable, so
        // tracks that compare equal keep their input order in both.
        val chains: MutableList<List<BallObservation>> = tracks.sortedWith { p, q ->
            val a = p.firstOrNull()
            val b = q.firstOrNull()
            if (a == null || b == null) {
                q.size.compareTo(p.size)
            } else if (a.t != b.t) {
                if (a.t < b.t) -1 else 1
            } else if (a.x != b.x) {
                if (a.x < b.x) -1 else 1
            } else if (a.y != b.y) {
                if (a.y < b.y) -1 else 1
            } else {
                0
            }
        }.toMutableList()
        while (true) {
            var bestErr = Double.POSITIVE_INFINITY
            var bestI = -1
            var bestJ = -1
            for (i in chains.indices) {
                var candJ = -1
                var candT = Double.POSITIVE_INFINITY
                var candErr = Double.POSITIVE_INFINITY
                for (j in chains.indices) {
                    if (i == j) continue
                    val err = stitchError(chains[i], chains[j]) ?: continue
                    val bt = chains[j].firstOrNull()?.t ?: continue
                    if (bt < candT || (bt == candT && err < candErr)) {
                        candT = bt; candErr = err; candJ = j
                    }
                }
                if (candJ < 0) continue
                if (candErr < bestErr ||
                    (candErr == bestErr && (i < bestI || (i == bestI && candJ < bestJ)))
                ) {
                    bestErr = candErr
                    bestI = i
                    bestJ = candJ
                }
            }
            if (bestI < 0) return chains
            chains[bestI] = chains[bestI] + chains[bestJ]
            chains.removeAt(bestJ)
        }
    }

    // Seeded tracking

    /** Port of `TrackBuilder.seedObservation` (sla_common._seed_observation); the reasoning lives there. */
    fun seedObservation(
        perFrame: Map<Int, List<BallObservation>>,
        t: Double,
        x: Double,
        y: Double,
        radiusPx: Double = SLA.seedSearchRadiusPx,
    ): BallObservation? {
        if (perFrame.isEmpty()) return null
        val frames = perFrame.keys.sorted()
        val times = frames.associateWith { perFrame[it]?.firstOrNull()?.t ?: 0.0 }
        val ordered = frames.sortedWith { fa, fb ->
            val da = abs((times[fa] ?: 0.0) - t)
            val db = abs((times[fb] ?: 0.0) - t)
            if (da != db) (if (da < db) -1 else 1) else fa.compareTo(fb)
        }
        for (f in ordered.take(12)) {
            var best: BallObservation? = null
            var bestD = radiusPx
            for (c in perFrame[f] ?: emptyList()) {
                val d = sqrt((c.x - x) * (c.x - x) + (c.y - y) * (c.y - y))
                if (d < bestD) { best = c; bestD = d }
            }
            if (best != null) return best
        }
        return null
    }

    /** Port of `TrackBuilder.follow` (sla_common._follow); the reasoning lives there. */
    private fun follow(
        perFrame: Map<Int, List<BallObservation>>,
        start: BallObservation,
        fps: Double,
        forward: Boolean,
    ): List<BallObservation> {
        val chain = mutableListOf(start)
        val sorted = perFrame.keys.sorted()
        val frames = if (forward) sorted else sorted.reversed()
        val step = if (forward) 1 else -1

        for (f in frames) {
            val last = chain.lastOrNull() ?: break
            if ((f - last.frame) * step <= 0) continue
            val gap = abs(f - last.frame)
            if (gap > SLA.seedMaxCoastFrames) break

            var vx = 0.0
            var vy = 0.0
            if (chain.size >= 2) {
                val prev = chain[chain.size - 2]
                val dt = last.t - prev.t
                if (dt != 0.0) { vx = (last.x - prev.x) / dt; vy = (last.y - prev.y) / dt }
            }
            val dtPred = (gap * step).toDouble() / fps
            val predX = last.x + vx * dtPred
            val predY = last.y + vy * dtPred
            val speedPxFr = sqrt(vx * vx + vy * vy) / fps
            val gate = if (chain.size >= 2) {
                swiftMax(SLA.seedGatePredictedPx, SLA.seedGateSpeedMult * speedPxFr) * gap.toDouble()
            } else {
                SLA.seedGateBasePx * gap.toDouble()
            }
            val speedNow = sqrt(vx * vx + vy * vy)

            var best: BallObservation? = null
            var bestD = gate
            for (c in perFrame[f] ?: emptyList()) {
                val d = sqrt((c.x - predX) * (c.x - predX) + (c.y - predY) * (c.y - predY))
                if (d >= bestD) continue
                if (speedNow > 1e-9) {
                    val cvx = (c.x - last.x) / dtPred
                    val cvy = (c.y - last.y) / dtPred
                    val speedC = sqrt(cvx * cvx + cvy * cvy)
                    if (speedC <= 1e-9) continue
                    val ratio = speedC / speedNow
                    if (ratio < 1.0 / SLA.seedSpeedRatioMax || ratio > SLA.seedSpeedRatioMax) continue
                    val cosang = (vx * cvx + vy * cvy) / (speedNow * speedC)
                    if (cosang < cos(SLA.seedMaxTurnDeg * PI / 180)) continue
                }
                best = c; bestD = d
            }
            if (best != null) chain.add(best)
        }
        return chain
    }

    /** Port of `TrackBuilder.pruneToBallistic` (sla_common._prune_to_ballistic); the reasoning lives there. */
    fun pruneToBallistic(track: List<BallObservation>, passes: Int = 2): List<BallObservation> {
        var out = track
        repeat(passes) {
            if (out.size < 5) return out
            val first = out.first()
            val rel = out.map { it.t - first.t }
            val n = out.size.toDouble()
            val meanT = rel.fold(0.0) { acc, v -> acc + v } / n
            val varT = rel.fold(0.0) { acc, v -> acc + (v - meanT) * (v - meanT) }
            if (!(varT > 1e-12)) return out
            var num = 0.0
            for ((i, o) in out.withIndex()) num += (rel[i] - meanT) * o.x
            val vx = num / varT
            val x0 = out.fold(0.0) { acc, o -> acc + o.x } / n - vx * meanT
            val fit = Geometry.fitQuadratic(ts = rel, vs = out.map { it.y })
            val res = ArrayList<Double>(out.size)
            for ((i, o) in out.withIndex()) {
                val px = x0 + vx * rel[i]
                val py = fit.a * rel[i] * rel[i] + fit.b * rel[i] + fit.c
                res.add(sqrt((o.x - px) * (o.x - px) + (o.y - py) * (o.y - py)))
            }
            val median = res.sorted()[res.size / 2]
            val diameters = out.map { it.diameterPx }.sorted()
            val cap = swiftMax(SLA.seedOutlierMinPx, diameters[diameters.size / 2])
            val limit = swiftMax(SLA.seedOutlierMinPx, swiftMin(SLA.seedOutlierSigma * median, cap))
            val kept = out.zip(res).filter { it.second <= limit }.map { it.first }
            if (kept.size == out.size || kept.size < 5) {
                return if (kept.size < 5) out else kept
            }
            out = kept
        }
        return out
    }

    /** Port of `TrackBuilder.trackFromSeed` (sla_common.track_from_seed); the reasoning lives there. */
    fun trackFromSeed(
        perFrame: Map<Int, List<BallObservation>>,
        fps: Double,
        t: Double,
        x: Double,
        y: Double,
        frameWidthPx: Double = 1920.0,
    ): List<BallObservation>? {
        val seed = seedObservation(
            perFrame = perFrame, t = t, x = x, y = y,
            radiusPx = SLA.seedSearchRadius(frameWidthPx = frameWidthPx),
        ) ?: return null
        val back = follow(perFrame = perFrame, start = seed, fps = fps, forward = false)
        val fwd = follow(perFrame = perFrame, start = seed, fps = fps, forward = true)
        val track = back.drop(1).reversed() + fwd
        return pruneToBallistic(track)
    }

    /** Port of `TrackBuilder.straightness` (sla_common.track_straightness); the reasoning lives there. */
    fun straightness(track: List<BallObservation>): Double {
        if (track.size < 2) return 0.0
        var walked = 0.0
        for ((a, b) in track.zipWithNext()) {
            walked += sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
        }
        if (!(walked > 1e-9)) return 0.0
        val first = track.first()
        val last = track.last()
        val dx = last.x - first.x
        val dy = last.y - first.y
        return sqrt(dx * dx + dy * dy) / walked
    }

    /** Port of `TrackBuilder.medianStepSpeed` (sla_common.median_step_speed); the reasoning lives there. */
    fun medianStepSpeed(track: List<BallObservation>): Double? {
        val steps = ArrayList<Double>(maxOf(0, track.size - 1))
        for ((a, b) in track.zipWithNext()) {
            val dt = b.t - a.t
            if (!(dt > 0)) continue
            val dx = b.x - a.x
            val dy = b.y - a.y
            steps.add(sqrt(dx * dx + dy * dy) / dt)
        }
        if (steps.isEmpty()) return null
        steps.sort()
        return steps[steps.size / 2]
    }

    /** The Swift `Scored` struct local to `selectOutboundTrack`. */
    private data class Scored(
        val score: Double,
        val straightness: Double,
        val vx: Double,
        val index: Int,
        val track: List<BallObservation>,
        val nearContact: Boolean,
    )

    /** Port of `TrackBuilder.selectOutboundTrack` (sla_common.select_outbound_track); the reasoning lives there. */
    fun selectOutboundTrack(
        tracks: List<List<BallObservation>>,
        direction: Direction = Direction.auto,
        minLen: Int = SLA.minTrackFrames,
        contactTime: Double? = null,
    ): List<BallObservation>? {
        var scored: List<Scored> = buildList {
            for ((i, tr) in tracks.withIndex()) {
                val first = tr.firstOrNull() ?: continue
                val last = tr.lastOrNull() ?: continue
                val near = contactTime?.let {
                    first.t >= it - SLA.selectContactTolS && first.t <= it + SLA.selectContactLateS
                } ?: false
                if (tr.size < (if (near) SLA.nearContactMinFrames else minLen)) continue
                val dt = last.t - first.t
                if (!(dt > 0)) continue
                val vx = (last.x - first.x) / dt
                val speed = medianStepSpeed(tr) ?: continue
                add(Scored(score = speed, straightness = straightness(tr),
                    vx = vx, index = i, track = tr, nearContact = near))
            }
        }
        if (scored.isEmpty()) return null

        val straight = scored.filter { it.straightness >= SLA.trackStraightnessMin }
        scored = if (straight.isEmpty()) scored else straight

        if (contactTime != null) {
            val near = scored.filter { it.nearContact }
            if (near.isNotEmpty()) {
                val full = near.filter { it.track.size >= minLen }
                scored = if (full.isEmpty()) near else full
            } else {
                val after = scored.filter {
                    (it.track.firstOrNull()?.t ?: 0.0) >= contactTime - SLA.selectContactTolS
                }
                if (after.isNotEmpty()) scored = after
            }
        }

        scored = scored.sortedWith { p, q ->
            if (p.score != q.score) (if (p.score > q.score) -1 else 1) else p.index.compareTo(q.index)
        }

        if (direction == Direction.auto) return scored[0].track
        val wantPositive = (direction == Direction.right)
        for (s in scored) {
            if ((s.vx > 0) == wantPositive) return s.track
        }
        return null
    }
}
