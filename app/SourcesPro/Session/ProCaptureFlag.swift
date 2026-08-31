// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Conditions a linked two-phone session can be in that the reference maths
/// cannot know about — the state of the link, the rig and the light.
///
/// Deliberately NOT part of `Swing3DFlag`, for the same reason `CaptureFlag`
/// is not part of `SwingFlag`: the parity fixtures must be able to provoke
/// every flag they pin, and no fixture can make a peer disappear.
enum ProCaptureFlag: String, Codable, CaseIterable, Sendable {
    case syncDegraded
    case peerLost
    case calibrationStale
    case rigMoved
    case tooDarkForShutter
    case clipMissingOneView

    var shortLabel: String {
        switch self {
        case .syncDegraded: return "Sync"
        case .peerLost: return "Peer lost"
        case .calibrationStale: return "Recalibrate"
        case .rigMoved: return "Rig moved"
        case .tooDarkForShutter: return "Too dark"
        case .clipMissingOneView: return "One view"
        }
    }

    /// What it means and what to do — the app says these out loud rather
    /// than quietly reporting a worse number.
    var explanation: String {
        switch self {
        case .syncDegraded:
            return "The phones' clocks disagree by more than the 3D metrics can tolerate. 3D is withheld; each phone's own 2D measurement is unaffected."
        case .peerLost:
            return "The link to the other phone dropped. This phone kept recording on its own."
        case .calibrationStale:
            return "The rig has not been calibrated this session. 3D needs to know where the phones are standing."
        case .rigMoved:
            return "A phone appears to have moved since calibration. Redo the wand pass before trusting 3D."
        case .tooDarkForShutter:
            return "Too dark to hold a short enough shutter at 240fps. The ball would smear too far to measure."
        case .clipMissingOneView:
            return "Only one phone produced a clip for this swing, so there is nothing to triangulate."
        }
    }

    /// Does this condition withhold 3D metrics entirely?
    var gates3D: Bool {
        switch self {
        case .syncDegraded, .calibrationStale, .rigMoved, .clipMissingOneView: return true
        case .peerLost, .tooDarkForShutter: return false
        }
    }
}
