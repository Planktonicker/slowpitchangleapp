// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation

/// Sagittal-plane body measurements from a recorded pose track.
///
/// The geometry functions are a line-for-line port of `sagittal_angle_deg`,
/// `spine_tilt_deg`, `planar_distance_m`, `stride_length_m` and
/// `head_drift_plausible` in `spike/sla_common.py`, pinned by `ParityTests`.
/// Change the Python first, regenerate the fixtures, then mirror here.
///
/// The selection logic above them — which frame is "load", which is "contact",
/// which leg is the front leg — is app-side, because it depends on the tracked
/// ball and the pose track together, and the Python reference has neither. It
/// is kept deliberately simple and explicit for that reason.
///
/// What this does **not** compute, at any confidence: hip–shoulder separation,
/// X-factor, kinematic-sequence ordering, or joint torque. The first three are
/// rotation about the vertical axis, which a side-on camera views nearly
/// edge-on — the worst-measured quantity in every markerless system. Torque
/// needs segment masses, inertias and ground reaction forces, which no camera
/// measures. See `docs/BIOMECHANICS.md`.
enum BodyAnalyzer {

    // MARK: - Pinned geometry

    /// Interior angle at `b` between the segments `b→a` and `b→c`, in degrees.
    ///
    /// Pure image geometry, so the y-down convention does not matter: flipping
    /// y reflects both vectors and leaves the angle between them unchanged.
    /// Returns NaN for a degenerate input rather than a plausible-looking
    /// angle — a pose model that loses a joint hands back coincident points,
    /// and 0° would be indistinguishable from a real fully-folded joint.
    static func sagittalAngleDeg(a: CGPoint, b: CGPoint, c: CGPoint) -> Double {
        let v1x = Double(a.x - b.x), v1y = Double(a.y - b.y)
        let v2x = Double(c.x - b.x), v2y = Double(c.y - b.y)
        let n1 = (v1x * v1x + v1y * v1y).squareRoot()
        let n2 = (v2x * v2x + v2y * v2y).squareRoot()
        guard n1 >= 1e-9, n2 >= 1e-9 else { return .nan }
        let cosine = (v1x * v2x + v1y * v2y) / (n1 * n2)
        return acos(max(-1, min(1, cosine))) * 180 / Double.pi
    }

    /// Lean of the hip-to-shoulder line away from vertical, in degrees.
    ///
    /// Signed in image terms — positive means the shoulders sit toward
    /// increasing x from the hips — so it flips with which way the hitter
    /// faces. Callers report the magnitude; direction belongs to the hitter's
    /// own baseline, not to a number the camera side decides.
    static func spineTiltDeg(hip: CGPoint, shoulder: CGPoint) -> Double {
        let dx = Double(shoulder.x - hip.x)
        let dy = Double(shoulder.y - hip.y)      // negative: shoulders above hips
        guard abs(dx) >= 1e-9 || abs(dy) >= 1e-9 else { return .nan }
        return atan2(dx, -dy) * 180 / Double.pi
    }

    /// Straight-line displacement between two image points, in metres.
    ///
    /// Uses the metres-per-pixel the ball measurement produced. That is the
    /// point: body distances inherit the ball's calibration instead of
    /// introducing a second one, so they are wrong in exactly the same way if
    /// it is wrong — far better than being wrong independently.
    static func planarDistanceM(_ p: CGPoint, _ q: CGPoint, scaleMPerPx: Double) -> Double {
        let dx = Double(q.x - p.x), dy = Double(q.y - p.y)
        return (dx * dx + dy * dy).squareRoot() * scaleMPerPx
    }

    /// How far the front foot travelled toward the pitcher, in metres.
    ///
    /// Horizontal only, and unsigned. Vertical ankle motion during a stride is
    /// the foot lifting, not stride length, and including it would inflate the
    /// number for a hitter with a big leg kick.
    static func strideLengthM(loadX: Double, contactX: Double, scaleMPerPx: Double) -> Double {
        abs(contactX - loadX) * scaleMPerPx
    }

    /// False when a head-movement reading is too large to be a swing.
    ///
    /// A sanity gate, not a coaching judgement. Beyond this the pose model has
    /// almost certainly jumped the head joint to another person or a background
    /// shape, and the number is withheld rather than shown.
    static func headDriftPlausible(_ driftM: Double?) -> Bool {
        guard let driftM else { return false }
        return driftM <= SLA.headDriftImplausibleM
    }

    // MARK: - Swing-level measurement

    /// Seconds before contact treated as the loaded position.
    ///
    /// The swing itself is roughly 150–200 ms from launch to contact in
    /// slow-pitch; a quarter second back is reliably *before* the hands go,
    /// while still being inside the clip's pre-roll (0.75 s).
    static let loadLeadS = 0.25

    /// Measure one swing.
    ///
    /// - Parameters:
    ///   - track: pose observations in frame order, in buffer pixels.
    ///   - contactTime: seconds from clip start, from the audio trigger.
    ///   - scaleMPerPx: the ball measurement's scale. Without it, distances
    ///     cannot be reported at all — angles still can, and are.
    ///   - ballDirectionX: sign of the ball's horizontal velocity at contact.
    ///     Positive means the ball left toward increasing x. The hitter faces
    ///     the camera and strides *toward the pitcher*, which is the direction
    ///     the ball leaves — so this is what identifies the front leg without
    ///     asking the user which way round they bat.
    static func analyze(track: [PoseObservation],
                        contactTime: Double,
                        scaleMPerPx: Double?,
                        ballDirectionX: Double) -> BodyMetrics {
        var out = BodyMetrics()
        out.frames = track.count
        guard !track.isEmpty else { return out }

        let sorted = track.sorted { $0.t < $1.t }
        guard let contact = nearest(sorted, to: contactTime),
              let load = nearest(sorted, to: contactTime - loadLeadS) else { return out }

        // Coverage over the window the metrics are actually taken from, not
        // over the whole clip: frames after the ball has left say nothing about
        // whether the swing was measurable.
        let window = sorted.filter { $0.t >= load.t - 0.001 && $0.t <= contact.t + 0.001 }
        let usable = window.filter { $0.midpoint(.leftHip, .rightHip) != nil }
        out.coverage = window.isEmpty ? 0 : Double(usable.count) / Double(window.count)

        // --- angles (no scale needed) ---
        let front = frontLeg(ballDirectionX: ballDirectionX, contact: contact)
        if let hip = contact.point(front.hip),
           let knee = contact.point(front.knee),
           let ankle = contact.point(front.ankle) {
            let angle = sagittalAngleDeg(a: hip, b: knee, c: ankle)
            if angle.isFinite { out.frontKneeDeg = angle }
        }
        if let hip = contact.midpoint(.leftHip, .rightHip),
           let shoulder = contact.midpoint(.leftShoulder, .rightShoulder) {
            let tilt = spineTiltDeg(hip: hip, shoulder: shoulder)
            if tilt.isFinite { out.spineTiltDeg = abs(tilt) }
        }

        // --- distances (scale needed) ---
        guard let scale = scaleMPerPx, scale > 0, scale.isFinite else { return out }

        if let a0 = load.point(front.ankle), let a1 = contact.point(front.ankle) {
            out.strideM = strideLengthM(loadX: Double(a0.x),
                                        contactX: Double(a1.x),
                                        scaleMPerPx: scale)
        }
        if let (h0, h1) = headPair(load, contact) {
            let drift = planarDistanceM(h0, h1, scaleMPerPx: scale)
            // Withheld rather than shown when it is too large to be a swing:
            // an implausible number in a feedback screen is worse than a dash,
            // because the hitter has no way to tell it is the model's mistake.
            if headDriftPlausible(drift) { out.headDriftM = drift }
        }
        if let p0 = load.midpoint(.leftHip, .rightHip),
           let p1 = contact.midpoint(.leftHip, .rightHip) {
            out.weightShiftM = planarDistanceM(p0, p1, scaleMPerPx: scale)
        }
        return out
    }

    /// Nose at both ends if the model has it at both ends; neck at both ends
    /// otherwise.
    ///
    /// A helmet and a turned head both cost the nose joint regularly, and the
    /// neck moves with the head for this purpose. Falling back keeps the
    /// metric available; mixing the two WITHIN one swing does not — nose at
    /// load against neck at contact adds the ~20 cm anatomical offset as
    /// phantom head movement, which is exactly the losing-the-nose case. The
    /// old code's comment claimed this check existed; now it does.
    private static func headPair(_ a: PoseObservation,
                                 _ b: PoseObservation) -> (CGPoint, CGPoint)? {
        if let n0 = a.point(.nose), let n1 = b.point(.nose) { return (n0, n1) }
        if let k0 = a.point(.neck), let k1 = b.point(.neck) { return (k0, k1) }
        return nil
    }


    private static func nearest(_ sorted: [PoseObservation], to t: Double) -> PoseObservation? {
        sorted.min { abs($0.t - t) < abs($1.t - t) }
    }

    /// Which leg is the front (lead) leg.
    ///
    /// The hitter strides toward the pitcher, and the ball leaves in that same
    /// direction, so the ball's horizontal velocity picks the leg out with no
    /// question asked of the user. Ties — a ball leaving straight up the
    /// middle, or no ball track at all — fall back to whichever ankle is
    /// farther along that axis at contact, which is the same test with a
    /// weaker signal.
    private static func frontLeg(ballDirectionX: Double,
                                 contact: PoseObservation)
        -> (hip: PoseJoint, knee: PoseJoint, ankle: PoseJoint) {
        let left = (hip: PoseJoint.leftHip, knee: PoseJoint.leftKnee, ankle: PoseJoint.leftAnkle)
        let right = (hip: PoseJoint.rightHip, knee: PoseJoint.rightKnee, ankle: PoseJoint.rightAnkle)

        var direction = ballDirectionX
        if abs(direction) < 1e-9 {
            guard let la = contact.point(.leftAnkle), let ra = contact.point(.rightAnkle) else {
                return left
            }
            direction = Double(la.x - ra.x)
        }
        guard let la = contact.point(.leftAnkle), let ra = contact.point(.rightAnkle) else {
            return left
        }
        // The front foot is the one farther along the direction of travel.
        return (Double(la.x - ra.x) * direction > 0) ? left : right
    }
}
