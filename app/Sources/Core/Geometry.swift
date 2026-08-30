// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Least-squares fitting and the drag-aware scale solve.
///
/// Ported from `spike/sla_common.py`. Pinned by `ParityTests` against golden
/// vectors generated from the Python — see `spike/gen_parity_fixtures.py`.
enum Geometry {

    /// Least-squares fit of `v(t) = a t^2 + b t + c`.
    ///
    /// Returns the coefficients highest-power-first (matching `np.polyfit`
    /// order) and the RMS residual.
    ///
    /// Solved via the 3x3 normal equations with partial pivoting. NumPy uses
    /// an SVD least-squares instead; for our conditioning (t spans ~0.3 s,
    /// values are pixel coordinates in the hundreds) the two agree far inside
    /// the parity tolerance, and the normal equations avoid shipping an SVD.
    static func fitQuadratic(ts: [Double], vs: [Double]) -> (a: Double, b: Double, c: Double, rms: Double) {
        precondition(ts.count == vs.count, "fitQuadratic: mismatched input lengths")
        let n = ts.count
        guard n > 0 else { return (0, 0, 0, 0) }

        // A fit of degree 2 needs 3 distinct abscissae. With fewer points the
        // system is underdetermined; drop to the highest degree the data can
        // actually support rather than returning garbage.
        let distinct = Set(ts.map { $0.bitPattern }).count
        if n < 3 || distinct < 3 {
            return fitLowOrder(ts: ts, vs: vs)
        }

        // Normal equations for the basis [t^2, t, 1].
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for i in 0..<n {
            let t = ts[i], v = vs[i]
            let t2 = t * t
            s0 += 1
            s1 += t
            s2 += t2
            s3 += t2 * t
            s4 += t2 * t2
            b0 += t2 * v
            b1 += t * v
            b2 += v
        }
        var m = [[s4, s3, s2, b0],
                 [s3, s2, s1, b1],
                 [s2, s1, s0, b2]]

        guard let sol = solve3x3(&m) else {
            return fitLowOrder(ts: ts, vs: vs)
        }
        let (a, b, c) = (sol[0], sol[1], sol[2])

        var sumSq = 0.0
        for i in 0..<n {
            let r = vs[i] - (a * ts[i] * ts[i] + b * ts[i] + c)
            sumSq += r * r
        }
        return (a, b, c, (sumSq / Double(n)).squareRoot())
    }

    /// Degenerate fallback: straight line, or a constant when even that is
    /// underdetermined. Keeps `a` at zero so callers reading curvature see
    /// "no curvature measured" rather than a fabricated one.
    private static func fitLowOrder(ts: [Double], vs: [Double]) -> (a: Double, b: Double, c: Double, rms: Double) {
        let n = ts.count
        guard n > 0 else { return (0, 0, 0, 0) }
        let meanT = ts.reduce(0, +) / Double(n)
        let meanV = vs.reduce(0, +) / Double(n)
        var sxx = 0.0, sxy = 0.0
        for i in 0..<n {
            let dt = ts[i] - meanT
            sxx += dt * dt
            sxy += dt * (vs[i] - meanV)
        }
        let b = sxx > 0 ? sxy / sxx : 0
        let c = meanV - b * meanT
        var sumSq = 0.0
        for i in 0..<n {
            let r = vs[i] - (b * ts[i] + c)
            sumSq += r * r
        }
        return (0, b, c, (sumSq / Double(n)).squareRoot())
    }

    /// Gaussian elimination with partial pivoting on an augmented 3x4 matrix.
    private static func solve3x3(_ m: inout [[Double]]) -> [Double]? {
        for col in 0..<3 {
            var pivot = col
            for r in (col + 1)..<3 where abs(m[r][col]) > abs(m[pivot][col]) {
                pivot = r
            }
            if abs(m[pivot][col]) < 1e-18 { return nil }
            if pivot != col { m.swapAt(pivot, col) }
            let d = m[col][col]
            for r in (col + 1)..<3 {
                let f = m[r][col] / d
                if f == 0 { continue }
                for c in col..<4 {
                    m[r][c] -= f * m[col][c]
                }
            }
        }
        var out = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var acc = m[row][3]
            for c in (row + 1)..<3 {
                acc -= m[row][c] * out[c]
            }
            out[row] = acc / m[row][row]
        }
        return out
    }

    /// Drag-aware gravity scale: solve for `s` [m/px] from the fitted vertical
    /// acceleration and the mid-window velocity.
    ///
    /// This is finding #1 from the spike, and the reason the naive
    /// `s = g / ay_px` is 20-40% wrong: a 12 in softball's terminal velocity
    /// is ~30 m/s (66 mph), so a batted ball flies *at* terminal velocity and
    /// drag is comparable to gravity.
    ///
    /// Model (image coords, y down-positive):
    /// ```
    ///     ay_m = g - (k/m) * |v_m| * vy_m           with v_m = s * v_px
    ///     s * ay_px = g - (k/m) * s^2 * |v_px| * vy_px
    /// ->  A s^2 + B s + C = 0,  A = (k/m)|v_px|vy_px,  B = ay_px,  C = -g
    /// ```
    /// While the ball rises (`vy_px < 0`) both roots are positive; the
    /// physical one is whichever sits nearest the independent ball-diameter
    /// scale (`scaleHint`). Taking `min` unconditionally is wrong — the
    /// parity fixtures include a case that catches exactly that mistake.
    static func solveGravityScale(ayPx: Double,
                                  vxPxMid: Double,
                                  vyPxMid: Double,
                                  scaleHint: Double?) -> Double? {
        guard ayPx > 1e-6 else { return nil }
        let speedPx = (vxPxMid * vxPxMid + vyPxMid * vyPxMid).squareRoot()
        let a = SLA.kOverM * speedPx * vyPxMid
        let b = ayPx
        let c = -SLA.g
        if abs(a) < 1e-9 { return SLA.g / ayPx }

        let disc = b * b - 4 * a * c
        if disc < 0 { return nil }
        let sq = disc.squareRoot()
        let roots = [(-b + sq) / (2 * a), (-b - sq) / (2 * a)].filter { $0 > 0 }
        guard !roots.isEmpty else { return nil }

        if let hint = scaleHint, hint > 0 {
            // Matches Python's `min(roots, key=...)`: first minimum wins ties.
            var best = roots[0]
            var bestErr = abs(roots[0] - hint)
            for r in roots.dropFirst() {
                let e = abs(r - hint)
                if e < bestErr { best = r; bestErr = e }
            }
            return best
        }
        return roots.min()
    }

    /// NumPy-compatible median: even counts average the two middle elements.
    static func median(_ xs: ArraySlice<Double>) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Sample standard deviation (ddof = 1), matching `np.std(..., ddof=1)`.
    ///
    /// One home for the statistic the G4 repeatability gate and the Trends
    /// screen both report — two private copies is how the gate and the trend
    /// readout end up describing different spreads for the same swings.
    static func sampleStdDev(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let ss = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
