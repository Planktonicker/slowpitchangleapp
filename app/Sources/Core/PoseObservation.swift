// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation

/// The joints SwingLab keeps.
///
/// A deliberate subset of Apple's body-pose output, not all of it. Every joint
/// here feeds a metric `docs/BIOMECHANICS.md` says a side-on camera can
/// honestly measure — stride, head movement, weight shift, knee flexion, spine
/// tilt. Wrists and elbows are not included: the hands are what the bat tape
/// already tracks far more precisely, and adding joints that feed nothing would
/// only make the skeleton busier.
///
/// Raw values match `sla_common.py`'s joint-name constants, so the reference
/// implementation and the port name the same thing the same way.
///
/// `CodingKeyRepresentable` so `[PoseJoint: PosePoint]` serialises as a JSON
/// object keyed by joint name. Without it Swift encodes a non-String-keyed
/// dictionary as a flat array of alternating keys and values — correct, and
/// unreadable, which defeats the reason the pose track is written to disk at
/// all: so a suspicious body number can be read back by a human.
enum PoseJoint: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case nose
    case neck
    case leftShoulder = "left_shoulder"
    case rightShoulder = "right_shoulder"
    case leftHip = "left_hip"
    case rightHip = "right_hip"
    case leftKnee = "left_knee"
    case rightKnee = "right_knee"
    case leftAnkle = "left_ankle"
    case rightAnkle = "right_ankle"

    /// Segments to stroke for the on-screen skeleton, in draw order.
    ///
    /// Not the anatomical skeleton — the *measured* one. Drawing exactly the
    /// joints the metrics use means the overlay is also the diagnostic: if the
    /// stride number looks wrong, the ankle in the picture is where to look.
    static let segments: [[PoseJoint]] = [
        [.leftShoulder, .neck, .rightShoulder],
        [.neck, .nose],
        [.leftShoulder, .leftHip],
        [.rightShoulder, .rightHip],
        [.leftHip, .rightHip],
        [.leftHip, .leftKnee, .leftAnkle],
        [.rightHip, .rightKnee, .rightAnkle],
    ]
}

/// One joint in one frame.
struct PosePoint: Equatable, Codable, Sendable {
    /// Pixels in the capture buffer, y down — the same coordinate space the
    /// ball and the bat tape are measured in, so a body distance and a ball
    /// distance mean the same thing.
    var x: Double
    var y: Double
    var confidence: Double
}

/// The hitter's pose in one frame.
struct PoseObservation: Equatable, Codable, Sendable {
    var frame: Int
    var t: Double
    var joints: [PoseJoint: PosePoint]

    /// A joint, but only if the model was actually confident about it.
    ///
    /// Apple's pose model reports low-confidence joints at plausible-looking
    /// positions rather than omitting them, so reading `joints` directly would
    /// produce body metrics with no body behind them.
    func point(_ joint: PoseJoint, minConfidence: Double = SLA.jointConfidenceMin) -> CGPoint? {
        guard let p = joints[joint], p.confidence >= minConfidence else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    /// Midpoint of a left/right pair, when both are confident.
    ///
    /// Used for the hip and shoulder centres. Requiring both is the point: from
    /// a side view the near and far joints of a pair sit at noticeably
    /// different image positions, so silently falling back to whichever one was
    /// visible would move the "centre" by half a body width between frames and
    /// show up as weight shift that never happened.
    func midpoint(_ a: PoseJoint, _ b: PoseJoint,
                  minConfidence: Double = SLA.jointConfidenceMin) -> CGPoint? {
        guard let p = point(a, minConfidence: minConfidence),
              let q = point(b, minConfidence: minConfidence) else { return nil }
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }
}

/// Sagittal-plane body measurements for one swing.
///
/// Every field is optional, and that is the design: a joint the pose model
/// could not see honestly produces no number. Nothing here is scored against a
/// population band — there are no published slow-pitch swing-kinematics norms,
/// so the only legitimate reference is the hitter's own history.
///
/// Deliberately absent: hip–shoulder separation, X-factor, kinematic-sequence
/// ordering, and any torque. The first three are axial rotation, which a
/// side-on camera views nearly edge-on; the last needs segment masses, inertias
/// and ground reaction forces, none of which a camera measures. See
/// `docs/BIOMECHANICS.md`.
struct BodyMetrics: Equatable, Codable, Sendable {
    /// How far the front foot travelled toward the pitcher, horizontally.
    var strideM: Double?
    /// Straight-line head movement between load and contact.
    var headDriftM: Double?
    /// Hip-centre movement between load and contact.
    var weightShiftM: Double?
    /// Front-knee interior angle at contact. 180° is a straight leg.
    var frontKneeDeg: Double?
    /// Lean of the hip-to-shoulder line from vertical at contact, magnitude.
    var spineTiltDeg: Double?
    /// Fraction of the frames between load and contact in which the pose model
    /// found the hitter at all. Low coverage means these numbers rest on a
    /// handful of frames, which the UI says rather than hides.
    var coverage: Double = 0
    /// Frames of pose actually recorded for the swing.
    var frames: Int = 0

    var hasAnything: Bool {
        strideM != nil || headDriftM != nil || weightShiftM != nil
            || frontKneeDeg != nil || spineTiltDeg != nil
    }
}
