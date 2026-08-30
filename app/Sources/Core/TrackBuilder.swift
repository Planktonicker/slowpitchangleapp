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
                let speedPxPerFrame = (vx * vx + vy * vy).squareRoot() / fps
                let gate = max(baseGatePx, 2.5 * speedPxPerFrame) * Double(gap)

                for (ci, c) in cands.enumerated() {
                    let d = ((c.x - predX) * (c.x - predX)
                             + (c.y - predY) * (c.y - predY)).squareRoot()
                    if d < gate { pairs.append((d, ti, ci)) }
                }
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
