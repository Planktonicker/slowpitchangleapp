// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Links per-frame ball candidates into tracks and picks the hit ball.
///
/// Port of `build_tracks` / `select_outbound_track` in `sla_common.py`.
enum TrackBuilder {

    /// Greedy nearest-neighbour association with constant-velocity prediction.
    ///
    /// The association gate grows with track speed, so a 240fps line drive
    /// (30-40 px per frame) still links while random net/grass false
    /// positives do not. Tracks may coast through `maxCoastFrames` misses.
    static func buildTracks(perFrame: [Int: [BallObservation]],
                            fps: Double,
                            baseGatePx: Double = 40.0,
                            maxCoastFrames: Int = 3,
                            minLen: Int = 4) -> [[BallObservation]] {
        var active: [[BallObservation]] = []
        var done: [[BallObservation]] = []

        for f in perFrame.keys.sorted() {
            let cands = perFrame[f] ?? []
            var claimed = [Bool](repeating: false, count: cands.count)

            // Every (track, candidate) pair inside its gate, then assign the
            // CLOSEST pairs first — not the first track's best, then the
            // second track's best, and so on.
            //
            // Track order used to decide it. On a cluttered frame that lets a
            // stationary false positive — predicting its own last position and
            // carrying the full base gate — claim a ball passing within it,
            // purely because that clutter track happened to be seeded earlier.
            // Sorting by distance settles the confident pairs first and needs
            // no new threshold to do it. Ties break on track then candidate
            // index, so this is deterministic and matches `build_tracks` in
            // `spike/sla_common.py` exactly.
            var pairs: [(d: Double, ti: Int, ci: Int)] = []
            for ti in active.indices {
                let obs = active[ti]
                guard let last = obs.last else { continue }
                let gap = f - last.frame
                if gap <= 0 || gap > maxCoastFrames + 1 { continue }

                var vx = 0.0, vy = 0.0
                if obs.count >= 2 {
                    let prev = obs[obs.count - 2]
                    let dt = last.t - prev.t
                    if dt > 0 {
                        vx = (last.x - prev.x) / dt
                        vy = (last.y - prev.y) / dt
                    }
                }
                let predX = last.x + vx * Double(gap) / fps
                let predY = last.y + vy * Double(gap) / fps
                let speed = (vx * vx + vy * vy).squareRoot()
                let speedPxPerFrame = speed / fps
                let gate = max(baseGatePx, 2.5 * speedPxPerFrame) * Double(gap)
                // A moving track may not be extended by a candidate behind it.
                // This is what keeps the PITCH out of the HIT: at contact the
                // ball is in nearly the same PLACE on both sides of the
                // collision and only its DIRECTION reverses, so a
                // nearest-neighbour gate walked the incoming pitch straight
                // through contact and out the other way — one "track" running
                // left at 2,700 px/s for half its length and right at 6,300 for
                // the rest. `stitchTracks` already refuses that join, but
                // contact never handed it two fragments to refuse.
                //
                // See BUILD_MAX_TURN_DEG in `spike/sla_common.py`: 60 deg is
                // roughly a hundred times the turn any real flight makes in one
                // frame at 240fps, which is the point — this refuses reversals,
                // it does not enforce smoothness.
                let heading = speedPxPerFrame >= SLA.buildTurnMinStepPx
                let cosMax = cos(SLA.buildMaxTurnDeg * .pi / 180)

                var inGate: [(d: Double, ci: Int)] = []
                for (ci, c) in cands.enumerated() {
                    let d = ((c.x - predX) * (c.x - predX)
                             + (c.y - predY) * (c.y - predY)).squareRoot()
                    if d < gate { inGate.append((d, ci)) }
                }
                inGate.sort { $0.d != $1.d ? $0.d < $1.d : $0.ci < $1.ci }

                // A track that cannot be extended forwards COASTS — it does not
                // swerve onto the next candidate along. Rejecting the nearest
                // candidate and letting the runner-up through is worse than no
                // filter at all: on a lawn of jittering blobs it walks a track
                // from one clutter blob to the NEXT ONE 90 px away every frame,
                // manufacturing a perfectly straight 16,000 px/s track out of
                // stationary grass that then beats the real ball on speed.
                if heading, let best = inGate.first {
                    // Measured from the last OBSERVED point, not the
                    // prediction: the prediction is already downrange, so a
                    // candidate sitting on it would have no direction at all.
                    let c0 = cands[best.ci]
                    let sx = c0.x - last.x, sy = c0.y - last.y
                    let step = (sx * sx + sy * sy).squareRoot()
                    if step > 1e-9, (sx * vx + sy * vy) / (step * speed) < cosMax {
                        continue
                    }
                }

                for g in inGate { pairs.append((g.d, ti, g.ci)) }
            }
            pairs.sort {
                $0.d != $1.d ? $0.d < $1.d
                    : ($0.ti != $1.ti ? $0.ti < $1.ti : $0.ci < $1.ci)
            }
            var matchedTracks = Set<Int>()
            for p in pairs where !matchedTracks.contains(p.ti) && !claimed[p.ci] {
                active[p.ti].append(cands[p.ci])
                claimed[p.ci] = true
                matchedTracks.insert(p.ti)
            }

            // Retire tracks that coasted too long.
            var still: [[BallObservation]] = []
            for tr in active {
                if let last = tr.last, f - last.frame > maxCoastFrames {
                    if tr.count >= minLen { done.append(tr) }
                } else {
                    still.append(tr)
                }
            }
            active = still

            // Unclaimed candidates seed new tracks.
            for (i, c) in cands.enumerated() where !claimed[i] {
                active.append([c])
            }
        }

        for tr in active where tr.count >= minLen { done.append(tr) }
        return done
    }

    enum Direction: String, Codable, CaseIterable, Sendable {
        case auto, left, right
    }

    /// Pick the hit ball: the FASTEST coherent track going the right way.
    ///
    /// An inbound pitch also forms a track; it is slower and moves the other
    /// way. With `.auto` the fastest track's horizontal direction wins.
    /// Least-squares linear velocity over a run of points, px/s.
    ///
    /// A least-squares slope, not an endpoint difference — fragments are
    /// exactly where endpoint differences fail. A 5-frame burst with a few
    /// pixels of noise on each end reads hundreds of px/s of phantom velocity
    /// from two points, enough to swing the stitch gates at random; the same
    /// noise averaged over every point barely moves the slope. Mirrors
    /// `_segment_velocity` in `spike/sla_common.py`.
    private static func segmentVelocity(_ seg: [BallObservation]) -> (vx: Double, vy: Double) {
        let n = seg.count
        guard n >= 2 else { return (0, 0) }
        // Explicit left-to-right accumulation on both sides — see the note in
        // `_segment_velocity`: a newer CPython's compensated `sum()` would
        // otherwise drift from this naive reduce with nothing to catch it.
        var acc = 0.0
        for o in seg { acc += o.t }
        let meanT = acc / Double(n)
        acc = 0
        for o in seg { acc += (o.t - meanT) * (o.t - meanT) }
        let varT = acc
        guard varT > 1e-12 else { return (0, 0) }
        var ax = 0.0, ay = 0.0
        for o in seg {
            ax += (o.t - meanT) * o.x
            ay += (o.t - meanT) * o.y
        }
        return (ax / varT, ay / varT)
    }

    static func endVelocity(_ tr: [BallObservation]) -> (vx: Double, vy: Double) {
        segmentVelocity(Array(tr.suffix(SLA.stitchVelocityWindow)))
    }

    static func startVelocity(_ tr: [BallObservation]) -> (vx: Double, vy: Double) {
        segmentVelocity(Array(tr.prefix(SLA.stitchVelocityWindow)))
    }

    /// Diagnostic access to the same endpoint velocities the stitch gates use.
    static func endVelocityForDiagnostics(_ tr: [BallObservation]) -> (vx: Double, vy: Double) {
        endVelocity(tr)
    }

    static func startVelocityForDiagnostics(_ tr: [BallObservation]) -> (vx: Double, vy: Double) {
        startVelocity(tr)
    }

    /// Extrapolation error of joining `b` onto `a`, in px — or nil if the
    /// gates refuse the join. Mirrors `_stitch_error` in `spike/sla_common.py`:
    /// the error rather than a Bool, because the CHOICE between competing
    /// joins is made on fit quality, and a yes/no answer let processing order
    /// decide instead.
    static func stitchError(_ a: [BallObservation], _ b: [BallObservation]) -> Double? {
        guard let aLast = a.last, let bFirst = b.first else { return nil }
        let gap = bFirst.t - aLast.t
        guard gap > 0, gap <= SLA.stitchMaxGapS else { return nil }
        let va = endVelocity(a)
        let vb = startVelocity(b)
        let speedA = (va.vx * va.vx + va.vy * va.vy).squareRoot()
        let speedB = (vb.vx * vb.vx + vb.vy * vb.vy).squareRoot()
        guard speedA > 1e-9, speedB > 1e-9 else { return nil }
        // Gravity, in pixels, from the ball's own apparent size.
        let diameters = (a.map(\.diameterPx) + b.map(\.diameterPx)).sorted()
        let medianD = diameters[diameters.count / 2]
        guard medianD > 1e-9 else { return nil }
        let gPx = SLA.g * medianD / SLA.ballDiameterM

        // Velocity agreement, bounded by what gravity can do in `gap`.
        let jx = vb.vx - va.vx, jy = vb.vy - va.vy
        let jump = (jx * jx + jy * jy).squareRoot()
        guard jump <= SLA.stitchAccelK * gPx * gap + SLA.stitchVelocityNoisePxS else { return nil }

        // The hop must go the way the ball was going — without this the
        // position tolerance is direction-blind and a run of clutter bursts
        // manufactures a net velocity that never existed.
        let hopX = bFirst.x - aLast.x, hopY = bFirst.y - aLast.y
        let hop = (hopX * hopX + hopY * hopY).squareRoot()
        if hop > 4.0 {
            let coshop = (va.vx * hopX + va.vy * hopY) / (speedA * hop)
            guard coshop >= cos(SLA.stitchMaxAngleDeg * .pi / 180) else { return nil }
        }

        // Predict WITH gravity.
        let predX = aLast.x + va.vx * gap
        let predY = aLast.y + va.vy * gap + 0.5 * gPx * gap * gap
        let tol = SLA.stitchBaseTolPx + SLA.stitchTolPxPerS * speedA * gap
        let dx = bFirst.x - predX, dy = bFirst.y - predY
        let err = (dx * dx + dy * dy).squareRoot()
        return err <= tol ? err : nil
    }

    /// Join fragments of one flight, greedily, nearest-in-time first.
    ///
    /// This exists because a ball crossing a busy background drops out of
    /// detection for longer than the builder coasts, so each detected burst
    /// becomes its own short track — and on real footage every piece of the
    /// hit died on the minimum-length gate while a slow landing bounce won
    /// selection. The pieces individually carried everything needed to rejoin
    /// them: same line, same speed, a few frames apart.
    ///
    /// The gates are kinematic consistency, not proximity: direction and
    /// speed must agree across the join, which is what keeps the WRONG joins
    /// out — pitch-into-hit reverses at contact, flight-into-bounce reverses
    /// at the ground, and both correctly stay separate.
    ///
    /// Mirrors `stitch_tracks` in `spike/sla_common.py`, pinned by
    /// `ParityTests` — deterministic order on purpose.
    static func stitchTracks(_ tracks: [[BallObservation]]) -> [[BallObservation]] {
        // Globally greedy on join error — repeatedly make the best-fitting
        // join ANYWHERE until none fits. A per-fragment sweep answered "which
        // chain should this fragment join?" but let processing order settle
        // the symmetric question — which of two competing fragments is a
        // chain's true continuation — and processing order traced back to a
        // raw y coordinate in the sort key. Mirrors `stitch_tracks`.
        var chains = tracks.map { $0 }.sorted {
            guard let a = $0.first, let b = $1.first else { return $0.count > $1.count }
            if a.t != b.t { return a.t < b.t }
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
        while true {
            var bestErr = Double.infinity
            var bestI = -1
            var bestJ = -1
            for i in chains.indices {
                // Each chain bids for its EARLIEST-STARTING stitchable
                // successor only. Without this the globally smallest error can
                // pick a skip-join over the adjacent one when a couple of
                // pixels of jitter make it marginally tighter, stranding the
                // middle fragment inside the merged span where it can never
                // join anything — measured at 6.9% of trials.
                var candJ = -1
                var candT = Double.infinity
                var candErr = Double.infinity
                for j in chains.indices where i != j {
                    guard let err = stitchError(chains[i], chains[j]),
                          let bt = chains[j].first?.t else { continue }
                    if bt < candT || (bt == candT && err < candErr) {
                        candT = bt; candErr = err; candJ = j
                    }
                }
                guard candJ >= 0 else { continue }
                if candErr < bestErr
                    || (candErr == bestErr && (i < bestI || (i == bestI && candJ < bestJ))) {
                    bestErr = candErr
                    bestI = i
                    bestJ = candJ
                }
            }
            if bestI < 0 { return chains }
            chains[bestI] += chains[bestJ]
            chains.remove(at: bestJ)
        }
    }

    // MARK: - Seeded tracking

    /// The detected candidate a tap refers to.
    ///
    /// Searches nearby frames outward in time, not only the exact one: a
    /// playhead can sit between decoded frames, and the ball is detected in
    /// only some of them. Mirrors `_seed_observation`.
    static func seedObservation(perFrame: [Int: [BallObservation]],
                                t: Double, x: Double, y: Double,
                                radiusPx: Double = SLA.seedSearchRadiusPx) -> BallObservation? {
        guard !perFrame.isEmpty else { return nil }
        let frames = perFrame.keys.sorted()
        let times = Dictionary(uniqueKeysWithValues: frames.map {
            ($0, perFrame[$0]?.first?.t ?? 0)
        })
        let ordered = frames.sorted {
            let da = abs((times[$0] ?? 0) - t), db = abs((times[$1] ?? 0) - t)
            return da != db ? da < db : $0 < $1
        }
        for f in ordered.prefix(12) {
            var best: BallObservation?
            var bestD = radiusPx
            for c in perFrame[f] ?? [] {
                let d = ((c.x - x) * (c.x - x) + (c.y - y) * (c.y - y)).squareRoot()
                if d < bestD { best = c; bestD = d }
            }
            if let best { return best }
        }
        return nil
    }

    /// Walk one direction in time from a known observation. Mirrors `_follow`.
    private static func follow(perFrame: [Int: [BallObservation]],
                               start: BallObservation, fps: Double,
                               forward: Bool) -> [BallObservation] {
        var chain = [start]
        var frames = perFrame.keys.sorted()
        if !forward { frames.reverse() }
        let step = forward ? 1 : -1

        for f in frames {
            guard let last = chain.last else { break }
            if (f - last.frame) * step <= 0 { continue }
            let gap = abs(f - last.frame)
            if gap > SLA.seedMaxCoastFrames { break }

            var vx = 0.0, vy = 0.0
            if chain.count >= 2 {
                let prev = chain[chain.count - 2]
                let dt = last.t - prev.t
                if dt != 0 { vx = (last.x - prev.x) / dt; vy = (last.y - prev.y) / dt }
            }
            let dtPred = Double(gap * step) / fps
            let predX = last.x + vx * dtPred
            let predY = last.y + vy * dtPred
            let speedPxFr = (vx * vx + vy * vy).squareRoot() / fps
            let gate = chain.count >= 2
                ? max(SLA.seedGatePredictedPx, SLA.seedGateSpeedMult * speedPxFr) * Double(gap)
                : SLA.seedGateBasePx * Double(gap)
            let speedNow = (vx * vx + vy * vy).squareRoot()

            var best: BallObservation?
            var bestD = gate
            for c in perFrame[f] ?? [] {
                let d = ((c.x - predX) * (c.x - predX) + (c.y - predY) * (c.y - predY)).squareRoot()
                if d >= bestD { continue }
                if speedNow > 1e-9 {
                    let cvx = (c.x - last.x) / dtPred
                    let cvy = (c.y - last.y) / dtPred
                    let speedC = (cvx * cvx + cvy * cvy).squareRoot()
                    if speedC <= 1e-9 { continue }
                    let ratio = speedC / speedNow
                    if ratio < 1.0 / SLA.seedSpeedRatioMax || ratio > SLA.seedSpeedRatioMax { continue }
                    let cosang = (vx * cvx + vy * cvy) / (speedNow * speedC)
                    if cosang < cos(SLA.seedMaxTurnDeg * .pi / 180) { continue }
                }
                best = c; bestD = d
            }
            if let best { chain.append(best) }
        }
        return chain
    }

    /// Drop observations that do not lie on the track's own ballistic fit.
    /// Mirrors `_prune_to_ballistic`. Valid here and nowhere else: the tap
    /// asserted this is ONE object in flight.
    static func pruneToBallistic(_ track: [BallObservation], passes: Int = 2) -> [BallObservation] {
        var out = track
        for _ in 0..<passes {
            guard out.count >= 5, let first = out.first else { return out }
            let rel = out.map { $0.t - first.t }
            let n = Double(out.count)
            let meanT = rel.reduce(0, +) / n
            let varT = rel.reduce(0.0) { $0 + ($1 - meanT) * ($1 - meanT) }
            guard varT > 1e-12 else { return out }
            var num = 0.0
            for (i, o) in out.enumerated() { num += (rel[i] - meanT) * o.x }
            let vx = num / varT
            let x0 = out.reduce(0.0) { $0 + $1.x } / n - vx * meanT
            let fit = Geometry.fitQuadratic(ts: rel, vs: out.map(\.y))
            var res: [Double] = []
            for (i, o) in out.enumerated() {
                let px = x0 + vx * rel[i]
                let py = fit.a * rel[i] * rel[i] + fit.b * rel[i] + fit.c
                res.append(((o.x - px) * (o.x - px) + (o.y - py) * (o.y - py)).squareRoot())
            }
            let median = res.sorted()[res.count / 2]
            let diameters = out.map(\.diameterPx).sorted()
            let cap = max(SLA.seedOutlierMinPx, diameters[diameters.count / 2])
            let limit = max(SLA.seedOutlierMinPx, min(SLA.seedOutlierSigma * median, cap))
            let kept = zip(out, res).filter { $0.1 <= limit }.map(\.0)
            if kept.count == out.count || kept.count < 5 {
                return kept.count < 5 ? out : kept
            }
            out = kept
        }
        return out
    }

    /// The ball's track, followed both ways from a point a human pointed at.
    ///
    /// `nil` only when nothing was DETECTED near the tap — a genuine detection
    /// failure, as distinct from the detector having found the ball and the
    /// pipeline having chosen something else. Mirrors `track_from_seed`.
    static func trackFromSeed(perFrame: [Int: [BallObservation]], fps: Double,
                              t: Double, x: Double, y: Double,
                              frameWidthPx: Double = 1920) -> [BallObservation]? {
        guard let seed = seedObservation(perFrame: perFrame, t: t, x: x, y: y,
                                         radiusPx: SLA.seedSearchRadius(frameWidthPx: frameWidthPx))
        else { return nil }
        let back = follow(perFrame: perFrame, start: seed, fps: fps, forward: false)
        let fwd = follow(perFrame: perFrame, start: seed, fps: fps, forward: true)
        let track = Array(back.dropFirst().reversed()) + fwd
        return pruneToBallistic(track)
    }

    /// Net displacement over path length, in 0...1.
    ///
    /// 1.0 is a straight line. A ball flight sits just under it — it curves,
    /// but it never turns back. A blob detected over and over in the same
    /// place, jittering, sits near 0 however many frames it survives for.
    ///
    /// Mirrors `track_straightness` in `spike/sla_common.py`.
    static func straightness(_ track: [BallObservation]) -> Double {
        guard track.count >= 2 else { return 0 }
        var walked = 0.0
        for (a, b) in zip(track, track.dropFirst()) {
            walked += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        guard walked > 1e-9, let first = track.first, let last = track.last else { return 0 }
        let dx = last.x - first.x, dy = last.y - first.y
        return (dx * dx + dy * dy).squareRoot() / walked
    }

    static func selectOutboundTrack(_ tracks: [[BallObservation]],
                                    direction: Direction = .auto,
                                    minLen: Int = SLA.minTrackFrames) -> [BallObservation]? {
        struct Scored {
            /// Speed alone. Length used to multiply this, and in slow-pitch
            /// that is exactly backwards: a lobbed pitch is slow and hangs in
            /// frame for two seconds while a hit is several times faster and
            /// gone in a fraction of one, so the two came out within a percent
            /// of each other and the choice fell to noise. Speed alone
            /// separates them about seven to one.
            var score: Double
            var straightness: Double
            var vx: Double
            var index: Int
            var track: [BallObservation]
        }

        var scored: [Scored] = []
        for (i, tr) in tracks.enumerated() {
            guard tr.count >= minLen, let first = tr.first, let last = tr.last else { continue }
            let dt = last.t - first.t
            guard dt > 0 else { continue }
            let vx = (last.x - first.x) / dt
            let vy = (last.y - first.y) / dt
            let speed = (vx * vx + vy * vy).squareRoot()
            scored.append(Scored(score: speed, straightness: straightness(tr),
                                 vx: vx, index: i, track: tr))
        }
        guard !scored.isEmpty else { return nil }

        // Straightness is a PREFERENCE, not a hard gate. A gate that rejects
        // every track returns nothing at all, which is a worse answer than a
        // doubtful one — and on real footage the hit is sometimes detected
        // raggedly enough to fail it.
        let straight = scored.filter { $0.straightness >= SLA.trackStraightnessMin }
        scored = straight.isEmpty ? scored : straight

        // Descending by score; the index tiebreak reproduces Python's stable
        // sort so the two implementations pick the same track on a tie.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }

        if direction == .auto { return scored[0].track }
        let wantPositive = (direction == .right)
        for s in scored where (s.vx > 0) == wantPositive {
            return s.track
        }
        return nil
    }
}
