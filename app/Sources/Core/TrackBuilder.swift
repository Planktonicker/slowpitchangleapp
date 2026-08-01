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

                var bestI = -1
                var bestD = gate
                for (i, c) in cands.enumerated() where !claimed[i] {
                    let d = ((c.x - predX) * (c.x - predX)
                             + (c.y - predY) * (c.y - predY)).squareRoot()
                    if d < bestD { bestI = i; bestD = d }
                }
                if bestI >= 0 {
                    active[ti].append(cands[bestI])
                    claimed[bestI] = true
                }
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

    /// Pick the hit ball: the longest/fastest coherent outbound track.
    ///
    /// An inbound pitch also forms a track; it is slower and moves the other
    /// way. With `.auto` the fastest track's horizontal direction wins.
    static func selectOutboundTrack(_ tracks: [[BallObservation]],
                                    direction: Direction = .auto,
                                    minLen: Int = SLA.minTrackFrames) -> [BallObservation]? {
        struct Scored {
            var score: Double
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
            scored.append(Scored(score: speed * Double(tr.count), vx: vx, index: i, track: tr))
        }
        guard !scored.isEmpty else { return nil }

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
