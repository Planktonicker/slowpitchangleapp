// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// One camera's view of one point at one instant.
struct Ray3D {
    var camera: Camera3D
    var u: Double
    var v: Double
    var weight: Double
}

/// A triangulated series. NaN rows are honest absences, not gaps to fill.
struct Track3D {
    var t: [Double]
    var xyz: [Vec3]
    var reprojectionPx: [Double]
    var coverage: Double
    var flags: [Swing3DFlag]
}

enum Triangulator3D {

    /// Weighted DLT for one instant.
    ///
    /// Each view contributes two homogeneous constraints. Rows are
    /// normalised to unit length BEFORE the confidence weight is applied,
    /// because raw DLT rows carry focal-length-sized magnitudes and the
    /// unnormalised normal matrix is conditioned like its square.
    ///
    /// Solved as the smallest eigenvector of the 4x4 normal matrix rather
    /// than by SVD of the tall system: a fixed-sweep symmetric eigensolver
    /// ports without LAPACK and is bit-stable across platforms, and
    /// determinism across the port matters more here than elegance. An
    /// iterative geometric refinement was measured to change nothing at this
    /// baseline and depth (see docs/SWINGLAB_PRO.md).
    ///
    /// `nil` for fewer than two rays, a degenerate solve, or a solution
    /// behind any contributing camera.
    static func triangulate(_ rays: [Ray3D]) -> (point: Vec3, reprojectionPx: Double)? {
        guard rays.count >= SLA3D.minViews else { return nil }
        var rows: [Vec4] = []
        rows.reserveCapacity(rays.count * 2)
        for ray in rays {
            let (p0, p1, p2) = ray.camera.projectionRows
            for r in [p2 * ray.u - p0, p2 * ray.v - p1] {
                let n = r.norm
                guard n > 0, n.isFinite else { return nil }
                rows.append(r * (ray.weight / n))
            }
        }

        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for r in rows {
            for i in 0..<4 {
                for j in 0..<4 { m[i][j] += r[i] * r[j] }
            }
        }
        guard let x = smallestEigenvector(m) else { return nil }
        guard abs(x.w) > 1e-12 else { return nil }
        let point = Vec3(x.x / x.w, x.y / x.w, x.z / x.w)
        guard point.isFinite else { return nil }

        var sum = 0.0
        for ray in rays {
            guard let uv = ray.camera.project(point) else { return nil }
            let du = uv.x - ray.u, dv = uv.y - ray.v
            sum += du * du + dv * dv
        }
        return (point, (sum / Double(rays.count)).squareRoot())
    }

    /// Eigenvector of the smallest eigenvalue of a symmetric 4x4, by cyclic
    /// Jacobi rotations. Fixed sweep count, no convergence-dependent
    /// branching, so two platforms take the same path.
    static func smallestEigenvector(_ input: [[Double]]) -> Vec4? {
        var a = input
        var v = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<4 { v[i][i] = 1 }

        for _ in 0..<24 {
            for p in 0..<3 {
                for q in (p + 1)..<4 {
                    let apq = a[p][q]
                    if abs(apq) < 1e-18 { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * apq)
                    let sign = theta >= 0 ? 1.0 : -1.0
                    let tval = sign / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (tval * tval + 1).squareRoot()
                    let s = tval * c
                    for k in 0..<4 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<4 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<4 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }

        var best = 0
        for i in 1..<4 where a[i][i] < a[best][best] { best = i }
        let e = Vec4(v[0][best], v[1][best], v[2][best], v[3][best])
        guard e.norm.isFinite, e.norm > 0 else { return nil }
        return e
    }

    /// Triangulate a whole series on a shared grid.
    ///
    /// A grid sample needs `minViews` usable views or it is NaN — absent,
    /// not guessed, the same rule the 2D pose path already follows for
    /// low-confidence joints. Flags are appended in a fixed order, which the
    /// fixtures pin.
    static func series(grid: [Double],
                       views: [(camera: Camera3D, us: [Double], vs: [Double], ws: [Double])],
                       hadGap: Bool = false) -> Track3D {
        let n = grid.count
        var xyz = [Vec3](repeating: .nan, count: n)
        var rms = [Double](repeating: .nan, count: n)

        func usable(_ view: (camera: Camera3D, us: [Double], vs: [Double], ws: [Double]),
                    _ i: Int) -> Bool {
            i < view.us.count && i < view.vs.count && i < view.ws.count
                && view.us[i].isFinite && view.vs[i].isFinite
                && view.ws[i].isFinite && view.ws[i] > 0
        }

        let live = views.filter { view in (0..<n).contains { usable(view, $0) } }
        if live.count >= SLA3D.minViews {
            for i in 0..<n {
                let rays = views.filter { usable($0, i) }
                    .map { Ray3D(camera: $0.camera, u: $0.us[i], v: $0.vs[i], weight: $0.ws[i]) }
                guard rays.count >= SLA3D.minViews else { continue }
                if let got = triangulate(rays) {
                    xyz[i] = got.point
                    rms[i] = got.reprojectionPx
                }
            }
        }

        let found = xyz.filter(\.isFinite).count
        let coverage = n > 0 ? Double(found) / Double(n) : 0
        var flags: [Swing3DFlag] = []
        if live.count < SLA3D.minViews { flags.append(.oneViewOnly) }
        if coverage < SLA3D.coverageMin3D { flags.append(.lowCoverage) }
        let finiteRMS = rms.filter(\.isFinite)
        if !finiteRMS.isEmpty,
           ClockSync3D.median(finiteRMS) > SLA3D.reprojectionRMSMaxPx {
            flags.append(.highReprojection)
        }
        if hadGap { flags.append(.resampleGap) }
        return Track3D(t: grid, xyz: xyz, reprojectionPx: rms,
                       coverage: coverage, flags: flags)
    }
}
