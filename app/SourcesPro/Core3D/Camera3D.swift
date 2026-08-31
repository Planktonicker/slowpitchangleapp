// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation

/// Pinhole intrinsics in pixels. `fx`/`fy` come from the format's field of
/// view — the same source `TiltRectifier` already uses — with square pixels
/// assumed until a per-model table says otherwise.
struct CameraIntrinsics: Equatable, Codable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var widthPx: Int
    var heightPx: Int

    static func fromFOV(widthPx: Int, heightPx: Int, fovDeg: Double) -> CameraIntrinsics? {
        let f = TiltRectifier.focalPx(widthPx: Double(widthPx), fovDeg: fovDeg)
        guard f > 0 else { return nil }
        return CameraIntrinsics(fx: f, fy: f,
                                cx: Double(widthPx) / 2, cy: Double(heightPx) / 2,
                                widthPx: widthPx, heightPx: heightPx)
    }
}

/// World-to-camera transform: `X_cam = r * X_world + t`.
struct CameraExtrinsics: Equatable, Sendable {
    var r: Mat3
    var t: Vec3

    /// Extrinsics for a camera at `pos` aimed at `target`.
    ///
    /// Rows of `r` are the camera's axes in world coordinates: x is image
    /// right, y is image DOWN (matching the y-down image convention the ball
    /// and bat are already measured in), z is the optical axis. Both cross
    /// products are checked against hand-derived image coordinates in the
    /// Python self-test — a round trip through `project` alone could not
    /// catch a swapped row.
    ///
    /// `nil` when the view direction is parallel to `up`: a camera pointing
    /// straight down has no defined "image right".
    static func lookAt(pos: Vec3, target: Vec3, up: Vec3 = .up) -> CameraExtrinsics? {
        guard let z = (target - pos).normalized() else { return nil }
        guard let x = z.cross(up).normalized() else { return nil }
        let y = z.cross(x)
        let r = Mat3(x, y, z)
        return CameraExtrinsics(r: r, t: r.times(pos) * -1)
    }

    /// Depth of a world point along the optical axis. Negative means behind.
    func depth(of p: Vec3) -> Double { r.r2.dot(p) + t.z }
}

/// A camera's full projection, precomputed.
struct Camera3D: Equatable, Sendable {
    var intrinsics: CameraIntrinsics
    var extrinsics: CameraExtrinsics

    /// Project a world point to pixels. `nil` at or behind the camera plane
    /// — a point you cannot see must not produce pixels.
    func project(_ p: Vec3) -> CGPoint? {
        let c = extrinsics.r.times(p) + extrinsics.t
        guard c.z > 1e-9 else { return nil }
        return CGPoint(x: intrinsics.fx * c.x / c.z + intrinsics.cx,
                       y: intrinsics.fy * c.y / c.z + intrinsics.cy)
    }

    /// The three rows of `K [R|t]`, which is what triangulation consumes.
    var projectionRows: (Vec4, Vec4, Vec4) {
        let r = extrinsics.r, t = extrinsics.t, k = intrinsics
        let row0 = Vec4(k.fx * r.r0.x + k.cx * r.r2.x,
                        k.fx * r.r0.y + k.cx * r.r2.y,
                        k.fx * r.r0.z + k.cx * r.r2.z,
                        k.fx * t.x + k.cx * t.z)
        let row1 = Vec4(k.fy * r.r1.x + k.cy * r.r2.x,
                        k.fy * r.r1.y + k.cy * r.r2.y,
                        k.fy * r.r1.z + k.cy * r.r2.z,
                        k.fy * t.y + k.cy * t.z)
        let row2 = Vec4(r.r2.x, r.r2.y, r.r2.z, t.z)
        return (row0, row1, row2)
    }

    /// Rolling-shutter delay of an observation at image row `y`.
    ///
    /// The sensor reads the top row first, so a detection at row y was
    /// exposed `(y/height) * readout` after the frame's timestamp. Added
    /// before resampling, this removes a 5–9 cm bat and ball error at
    /// 240fps. Clamped so a slightly out-of-frame centroid cannot produce a
    /// delay outside the physical readout window.
    static func rowDelayS(y: Double, heightPx: Double, readoutS: Double) -> Double {
        guard heightPx > 0, readoutS > 0 else { return 0 }
        return min(max(y / heightPx, 0), 1) * readoutS
    }
}

/// A homogeneous row. Only ever used four-at-a-time by the triangulator.
struct Vec4: Equatable, Sendable {
    var x: Double, y: Double, z: Double, w: Double
    init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    static func - (a: Vec4, b: Vec4) -> Vec4 { Vec4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w) }
    static func * (a: Vec4, s: Double) -> Vec4 { Vec4(a.x * s, a.y * s, a.z * s, a.w * s) }
    var norm: Double { (x * x + y * y + z * z + w * w).squareRoot() }
    func dot(_ o: Vec4) -> Double { x * o.x + y * o.y + z * o.z + w * o.w }
    subscript(i: Int) -> Double {
        switch i { case 0: return x; case 1: return y; case 2: return z; default: return w }
    }
}
