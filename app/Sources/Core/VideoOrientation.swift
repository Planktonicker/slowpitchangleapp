// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation

/// Turning measured buffer pixels into the picture a person sees.
///
/// A video track carries a `preferredTransform` that rotates the encoded
/// buffer into the displayed frame, and iPhone footage uses it constantly —
/// the sensor reads out landscape whichever way the phone was held.
///
/// This app used to measure in raw buffer pixels and say that made every
/// number orientation-independent. That is true of a **diameter**, which is a
/// length, and false of a **launch angle**, which is signed and needs to know
/// which way is up. On a clip whose buffer is upside down the app read a ball
/// dropped from head height as `+76.9 deg` — going almost straight UP — and
/// then correctly refused it as impossible. The tracking was perfect; the
/// frame it was measured in was upside down.
///
/// For a real swing that is worse than a refusal, because a hit that rises
/// reads as one that falls and nothing about the number looks wrong.
///
/// Only the copy the numbers come from is rotated. The track handed back to
/// the caller stays in raw buffer pixels, because the overlay draws on the
/// original frames — the same split `TiltRectifier` already uses.
enum VideoOrientation {

    /// Quarter turns the transform applies, 0-3, counted clockwise.
    ///
    /// Snapped to a right angle on purpose. Container transforms are always
    /// multiples of 90 degrees in practice, and a fractional answer here would
    /// mean the metadata is describing something this cannot honour anyway.
    static func quarterTurns(_ t: CGAffineTransform) -> Int {
        let angle = atan2(t.b, t.a)
        let turns = Int((angle / (.pi / 2)).rounded())
        return ((turns % 4) + 4) % 4
    }

    /// The displayed frame's size, given the buffer's.
    static func displaySize(width: Int, height: Int, quarterTurns q: Int) -> (width: Int, height: Int) {
        (q % 2 == 0) ? (width, height) : (height, width)
    }

    /// One point, buffer pixels in, display pixels out. y is down in both.
    static func point(x: Double, y: Double,
                      width: Int, height: Int, quarterTurns q: Int) -> (x: Double, y: Double) {
        let w = Double(width), h = Double(height)
        switch q {
        case 1:  return (h - 1 - y, x)          // 90 clockwise
        case 2:  return (w - 1 - x, h - 1 - y)  // 180
        case 3:  return (y, w - 1 - x)          // 270 clockwise
        default: return (x, y)
        }
    }

    /// Quarter turns implied by a capture-time Vision orientation, for clips
    /// whose container carries NO display matrix — the app's own recordings,
    /// which are written straight from the encoder. The capture path records
    /// which way Vision had to be shown the frames; that is the same fact.
    static func quarterTurns(from orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .right, .rightMirrored: return 1
        case .down, .downMirrored:   return 2
        case .left, .leftMirrored:   return 3
        default:                     return 0
        }
    }

    /// ...and back the other way, for telling Vision how to look at a buffer
    /// whose container DOES carry a display matrix.
    static func imageOrientation(quarterTurns q: Int) -> CGImagePropertyOrientation {
        switch ((q % 4) + 4) % 4 {
        case 1:  return .right
        case 2:  return .down
        case 3:  return .left
        default: return .up
        }
    }

    /// A pose track. Confidences are untouched for the same reason diameters
    /// are — they are not coordinates.
    static func rotate(pose: [PoseObservation],
                       width: Int, height: Int, quarterTurns q: Int) -> [PoseObservation] {
        guard q != 0 else { return pose }
        return pose.map { obs in
            var joints: [PoseJoint: PosePoint] = [:]
            for (j, pt) in obs.joints {
                let p = point(x: pt.x, y: pt.y, width: width, height: height, quarterTurns: q)
                joints[j] = PosePoint(x: p.x, y: p.y, confidence: pt.confidence)
            }
            return PoseObservation(frame: obs.frame, t: obs.t, joints: joints)
        }
    }

    /// A whole track. Diameters are untouched — a length does not rotate.
    static func rotate(track: [BallObservation],
                       width: Int, height: Int, quarterTurns q: Int) -> [BallObservation] {
        guard q != 0 else { return track }
        return track.map { o in
            let p = point(x: o.x, y: o.y, width: width, height: height, quarterTurns: q)
            return BallObservation(frame: o.frame, t: o.t, x: p.x, y: p.y,
                                   diameterPx: o.diameterPx, areaPx: o.areaPx)
        }
    }
}
