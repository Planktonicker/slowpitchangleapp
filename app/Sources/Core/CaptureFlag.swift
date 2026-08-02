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
    case cameraTilted = "CAMERA_TILTED"
    case notLevel = "NOT_LEVEL"
    case levelUnknown = "LEVEL_UNKNOWN"
    case distanceOutsideProtocol = "DISTANCE_OUTSIDE_PROTOCOL"
    case scaleFromManualDistance = "SCALE_FROM_MANUAL_DISTANCE"
    case hitterGateDisabled = "HITTER_GATE_DISABLED"

    var explanation: String {
        switch self {
        case .cameraTilted:
            return "The camera was pointing up or down rather than level. That turns the flight plane into a projection, and unlike roll it cannot be corrected afterwards — treat the launch angle as approximate."
        case .notLevel:
            return "The horizon sat at an angle in frame. This one IS corrected in the maths, so it costs little accuracy; it is recorded so a surprising reading can be explained."
        case .levelUnknown:
            return "No motion-sensor reading was available, so the camera's angle is unknown rather than known-good."
        case .distanceOutsideProtocol:
            return "The camera was outside the 12–28 ft window the capture protocol asks for. Readings are still computed, but the ball is smaller or larger in frame than the detector is tuned for."
        case .scaleFromManualDistance:
            return "Scale came from a typed distance rather than a measured object, so it inherits whatever error is in that number."
        case .hitterGateDisabled:
            return "The requirement for a person in frame was switched off for this session, so a loud noise alone could have started this clip."
        }
    }

    /// Short label for the chip row.
    var shortLabel: String {
        switch self {
        case .cameraTilted: return "tilted"
        case .notLevel: return "off level"
        case .levelUnknown: return "level unknown"
        case .distanceOutsideProtocol: return "distance"
        case .scaleFromManualDistance: return "typed distance"
        case .hitterGateDisabled: return "no hitter check"
        }
    }
}
