// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Launch numbers read straight from a triangulated ball track.
struct LaunchMetrics3D: Equatable, Sendable {
    var evMph: Double
    var evMps: Double
    /// Up-positive, from the horizontal.
    var laDeg: Double
    /// Azimuth of the horizontal velocity; 0 is straight out. The metric a
    /// single side-on camera can never see.
    var sprayDeg: Double
    var nSamples: Int
}

enum Metrics3D {

    /// Azimuth of a body segment's left-right axis, in degrees.
    ///
    /// Direction is right joint → left joint, projected onto the ground.
    /// `nil` when the segment is near-vertical: the azimuth of an upright
    /// line is noise wearing units, and returning nil is what keeps a
    /// fallen-over reading out of the separation curve.
    static func segmentAzimuthDeg(left: Vec3, right: Vec3) -> Double? {
        let d = left - right
        let total = d.norm
        guard total > 0, total.isFinite else { return nil }
        let horiz = (d.x * d.x + d.y * d.y).squareRoot()
        guard horiz >= SLA3D.segmentAzimuthMinHoriz * total else { return nil }
        return atan2(d.y, d.x) * 180 / .pi
    }

    /// Pelvis azimuth minus thorax azimuth, wrapped to (-180, 180].
    ///
    /// Positive when the pelvis leads the thorax toward the pitcher — the
    /// coiled state hitters call separation. This is SEGMENT rotation, the
    /// quantity markerless systems measure passably; JOINT axial rotation is
    /// several times worse in every published validation and is deliberately
    /// not computed anywhere in this module.
    ///
    /// Carries a known bias: Vision reports surface landmarks, not joint
    /// centres, and a surface point slides against the bone as the pelvis
    /// turns. See docs/SWINGLAB_PRO.md — it is recorded, not corrected.
    static func hipShoulderSeparationDeg(hipL: Vec3, hipR: Vec3,
                                         shoulderL: Vec3, shoulderR: Vec3) -> Double? {
        guard let pelvis = segmentAzimuthDeg(left: hipL, right: hipR),
              let thorax = segmentAzimuthDeg(left: shoulderL, right: shoulderR)
        else { return nil }
        return wrap180(pelvis - thorax)
    }

    static func wrap180(_ deg: Double) -> Double {
        var w = fmod(deg + 180, 360)
        if w <= 0 { w += 360 }
        return w - 180
    }

    /// EV, launch angle and spray from 3D positions just after contact.
    ///
    /// The same shape as the 2D read — quadratic per axis over the velocity
    /// window, velocity taken at the window start — but with no scale step
    /// at all, because the positions are already metres. That is the whole
    /// point of triangulating, and it is why this path does not inherit the
    /// ball-diameter error that `VALIDATION.md` records for one camera.
    static func launch(t: [Double], xyz: [Vec3], contactT: Double,
                       windowS: Double = SLA.velocityWindowS) -> LaunchMetrics3D? {
        var ts: [Double] = []
        var pts: [Vec3] = []
        for i in 0..<min(t.count, xyz.count) where
            t[i].isFinite && xyz[i].isFinite && t[i] >= contactT && t[i] <= contactT + windowS {
            ts.append(t[i]); pts.append(xyz[i])
        }
        guard ts.count >= SLA3D.launchMinSamples, let t0 = ts.first else { return nil }
        let tau = ts.map { $0 - t0 }

        let vx = Geometry.fitQuadratic(ts: tau, vs: pts.map(\.x)).b
        let vy = Geometry.fitQuadratic(ts: tau, vs: pts.map(\.y)).b
        let vz = Geometry.fitQuadratic(ts: tau, vs: pts.map(\.z)).b
        let speed = Vec3(vx, vy, vz).norm
        guard speed.isFinite else { return nil }
        return LaunchMetrics3D(evMph: speed * SLA.mphPerMps,
                               evMps: speed,
                               laDeg: atan2(vz, (vx * vx + vy * vy).squareRoot()) * 180 / .pi,
                               sprayDeg: atan2(vy, vx) * 180 / .pi,
                               nSamples: ts.count)
    }

    /// The gravity VECTOR from a triangulated free-flight track, drag-aware.
    ///
    /// Drag is not negligible for a hit softball — at 29 m/s the drag
    /// deceleration rivals g, the same fact that forced the drag-aware scale
    /// solve on the 2D side — so the measured acceleration is corrected at
    /// the window-midpoint velocity before being reported.
    static func gravityVector(t: [Double], xyz: [Vec3]) -> Vec3? {
        var ts: [Double] = []
        var pts: [Vec3] = []
        for i in 0..<min(t.count, xyz.count) where t[i].isFinite && xyz[i].isFinite {
            ts.append(t[i]); pts.append(xyz[i])
        }
        guard ts.count >= 12, let lo = ts.first, let hi = ts.last,
              hi - lo >= SLA3D.gravityMinSpanS else { return nil }
        let tau = ts.map { $0 - lo }
        let tauMid = (tau.last ?? 0) / 2

        func axis(_ vals: [Double]) -> (accel: Double, vMid: Double) {
            let f = Geometry.fitQuadratic(ts: tau, vs: vals)
            return (2 * f.a, 2 * f.a * tauMid + f.b)
        }
        let ax = axis(pts.map(\.x)), ay = axis(pts.map(\.y)), az = axis(pts.map(\.z))
        let accel = Vec3(ax.accel, ay.accel, az.accel)
        let vMid = Vec3(ax.vMid, ay.vMid, az.vMid)
        let kOverM = 0.5 * SLA.airDensity * SLA.dragCd
            * Double.pi * pow(SLA.ballDiameterM / 2, 2) / SLA.ballMassKg
        return accel + vMid * (kOverM * vMid.norm)
    }

    /// |g| — the scale witness. Needs no reference object, no radar and no
    /// ball diameter, so if it reads 9.81 the rig's scale is right.
    static func gravityMagnitude(t: [Double], xyz: [Vec3]) -> Double? {
        gravityVector(t: t, xyz: xyz).map(\.norm)
    }

    /// Angle between reconstructed gravity and true down, in degrees.
    ///
    /// The rotational half of the rig check, and the reason magnitude alone
    /// is not enough: a rotation of the whole rig — both tripods rolled the
    /// same way, a shared bearing error — moves every reconstructed point
    /// but PRESERVES LENGTHS, so |g| is structurally blind to it.
    ///
    /// Reported, never gated. Tilt is a transverse acceleration over g, and
    /// the noise on a quadratic acceleration fit falls steeply with the fit
    /// window, so a fixed threshold would fail correct rigs on short falls —
    /// which is the common case, and the exact afternoon a gate exists to
    /// protect. Compare it against the floor for the window actually got.
    static func gravityTiltDeg(t: [Double], xyz: [Vec3]) -> Double? {
        guard let g = gravityVector(t: t, xyz: xyz), let u = g.normalized() else { return nil }
        return acos(min(max(u.dot(.down), -1), 1)) * 180 / .pi
    }
}
