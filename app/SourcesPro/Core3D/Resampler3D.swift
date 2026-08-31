// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Putting two free-running cameras on one timeline.
enum Resampler3D {

    /// Monotone cubic (Fritsch–Carlson) resampling, with honest gaps.
    ///
    /// Two free-running sensors interleave with a uniformly random half-frame
    /// phase, so no pairing of "frame k with frame k" aligns them. Each
    /// camera's track is resampled onto one shared grid instead, before
    /// triangulation.
    ///
    /// Monotone cubic rather than a plain spline because a spline overshoots
    /// at exactly the place that matters most — the velocity spike through
    /// contact — and an overshoot there is an invented bat speed.
    ///
    /// Grid points outside the samples, or inside a gap wider than
    /// `maxGapS`, come back NaN: a dropout is absent, not bridged. Endpoint
    /// slopes use the one-sided secant, pinned by fixtures so the port cannot
    /// silently pick a different endpoint rule.
    static func pchip(ts: [Double], vs: [Double], grid: [Double],
                      maxGapS: Double = SLA3D.resampleMaxGapS) -> [Double] {
        var out = [Double](repeating: .nan, count: grid.count)

        var pairs: [(Double, Double)] = []
        pairs.reserveCapacity(ts.count)
        for i in 0..<min(ts.count, vs.count) where ts[i].isFinite && vs[i].isFinite {
            pairs.append((ts[i], vs[i]))
        }
        guard pairs.count >= 2 else { return out }
        // Stable sort, then drop duplicate stamps — two samples at one
        // instant give an infinite slope.
        pairs.sort { $0.0 < $1.0 }
        var t: [Double] = [pairs[0].0]
        var v: [Double] = [pairs[0].1]
        for p in pairs.dropFirst() where p.0 > t[t.count - 1] {
            t.append(p.0); v.append(p.1)
        }
        let n = t.count
        guard n >= 2 else { return out }

        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = t[i + 1] - t[i]
            delta[i] = (v[i + 1] - v[i]) / h[i]
        }

        var d = [Double](repeating: 0, count: n)
        d[0] = delta[0]
        d[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            if delta[i - 1] == 0 || delta[i] == 0 || (delta[i - 1] > 0) != (delta[i] > 0) {
                d[i] = 0                        // local extremum: flat, no overshoot
            } else {
                let w1 = 2 * h[i] + h[i - 1]
                let w2 = h[i] + 2 * h[i - 1]
                d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
            }
        }

        for (gi, g) in grid.enumerated() {
            guard g >= t[0], g <= t[n - 1] else { continue }
            var j = upperBound(t, g) - 1
            if g == t[n - 1] { j = n - 2 }
            guard j >= 0, j <= n - 2 else { continue }
            guard h[j] <= maxGapS else { continue }
            let s = (g - t[j]) / h[j]
            let s2 = s * s
            let s3 = s2 * s
            out[gi] = (2 * s3 - 3 * s2 + 1) * v[j]
                + (s3 - 2 * s2 + s) * h[j] * d[j]
                + (-2 * s3 + 3 * s2) * v[j + 1]
                + (s3 - s2) * h[j] * d[j + 1]
        }
        return out
    }

    /// First index whose value is strictly greater than `x` (NumPy's
    /// `searchsorted(..., side: "right")`).
    static func upperBound(_ xs: [Double], _ x: Double) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Did this track have an interior dropout wider than `maxGapS`?
    /// Surfaced as `RESAMPLE_GAP` so a dropout-riddled capture cannot pose
    /// as a clean one.
    static func hadGap(ts: [Double], maxGapS: Double = SLA3D.resampleMaxGapS) -> Bool {
        let f = ts.filter(\.isFinite).sorted()
        guard f.count >= 2 else { return false }
        for i in 1..<f.count where f[i] - f[i - 1] > maxGapS { return true }
        return false
    }
}
