// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Conditions the *camera* was in when a swing was captured.
///
/// Deliberately separate from `SwingFlag`. That enum mirrors the flag
/// constants in `spike/sla_common.py` string-for-string, and `ParityTests`
/// asserts every case appears in a fixture — but the Python reference analyses
/// a track and has no idea whether a tripod was level, so it can never produce
/// these. Folding them in would either break parity or force the fixture
/// generator to invent flags it cannot compute.
///
/// They exist because level stopped blocking arming. The honest-measurement
/// rule still holds: a reading taken in poor conditions is *labelled*, not
/// silently reported as if it were clean, and not refused outright.
enum CaptureFlag: String, Codable, CaseIterable, Sendable {
    /// Tilt beyond what the rectification can honestly claim to undo, or tilt
    /// with unknown optics so it could not be undone at all.
    case cameraTilted = "CAMERA_TILTED"
    /// The camera was aimed up or down and the tilt *was* corrected. Recorded
    /// rather than hidden: the correction is exact for a pinhole and real
    /// lenses are not, so a reading that needed it is worth knowing about.
    case tiltCorrected = "TILT_CORRECTED"
    case notLevel = "NOT_LEVEL"
    case levelUnknown = "LEVEL_UNKNOWN"
    case distanceOutsideProtocol = "DISTANCE_OUTSIDE_PROTOCOL"
    case scaleFromManualDistance = "SCALE_FROM_MANUAL_DISTANCE"
    case hitterGateDisabled = "HITTER_GATE_DISABLED"
    /// Frames were dropped while this clip was being captured. Stamped at
    /// capture time on purpose: the live counter is transient, and without
    /// this the fact evaporates when the counter clears, leaving a swing in
    /// history that looks clean but was measured on a broken frame interval.
    case framesDropped = "FRAMES_DROPPED"
    /// The clip came from a file rather than from this app's own capture, so
    /// there is no placement, no level reading and no audio trigger behind it.
    case importedClip = "IMPORTED_CLIP"

    var explanation: String {
        switch self {
        case .cameraTilted:
            return "The camera was pointing up or down steeply, or its lens field of view was unknown, so the tilt could not be corrected. That leaves the flight plane projected — treat the launch angle as approximate. Raise the tripod and keep it level rather than aiming up at contact height."
        case .tiltCorrected:
            return "The camera was aimed up or down, and the track was rectified to what a level camera would have recorded before anything was measured. Costs little accuracy at this angle; recorded so a surprising reading can be traced."
        case .notLevel:
            return "The horizon sat at an angle in frame. This one IS corrected in the maths, so it costs little accuracy; it is recorded so a surprising reading can be explained."
        case .levelUnknown:
            return "No motion-sensor reading was available, so the camera's angle is unknown rather than known-good."
        case .distanceOutsideProtocol:
            return "The camera was outside the 3.5–8.5 m window the capture protocol asks for. Readings are still computed, but the ball is smaller or larger in frame than the detector is tuned for."
        case .scaleFromManualDistance:
            return "Scale came from a typed distance rather than a measured object, so it inherits whatever error is in that number."
        case .hitterGateDisabled:
            return "The requirement for a person in frame was switched off for this session, so a loud noise alone could have started this clip."
        case .importedClip:
            return "This clip was imported, not filmed by the app. Launch angle and exit velocity still hold — both come from the ball's own size in the picture, which travels with the footage. What is missing is everything the app measures at capture time: no camera distance, no level or tilt reading to correct with, and no audio trigger, so contact is taken to be the first frame the ball was tracked in rather than the crack of the bat."
        case .framesDropped:
            return "The camera dropped frames while this clip was recorded. Every measurement here assumes a constant frame interval, so timing — and therefore exit velocity — may be off. Close other apps and let the phone cool down."
        }
    }

    /// Short label for the chip row.
    var shortLabel: String {
        switch self {
        case .cameraTilted: return "tilted"
        case .tiltCorrected: return "tilt corrected"
        case .notLevel: return "off level"
        case .levelUnknown: return "level unknown"
        case .distanceOutsideProtocol: return "distance"
        case .scaleFromManualDistance: return "typed distance"
        case .hitterGateDisabled: return "no hitter check"
        case .importedClip: return "imported"
        case .framesDropped: return "dropped frames"
        }
    }
}
