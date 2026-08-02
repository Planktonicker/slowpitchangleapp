// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// One detection of the ball in one frame.
///
/// Image coordinate convention, matching OpenCV and `sla_common.py`:
/// x grows right, **y grows DOWN**. Reported angles are up-positive in
/// real-world terms, so the sign flip happens once, in `SwingAnalyzer`.
struct BallObservation: Equatable, Codable, Sendable {
    var frame: Int
    var t: Double            // seconds from clip start
    var x: Double            // px
    var y: Double            // px (down-positive)
    /// Minor-axis diameter. Motion blur elongates the ball along its velocity
    /// vector; the minor axis is perpendicular to motion and stays equal to
    /// the true ball diameter. Measured sub-pixel — see `BallDetector`.
    var diameterPx: Double
    var areaPx: Double
}

/// The output of the measurement core for one swing.
struct SwingMetrics: Equatable, Codable, Sendable {
    var launchAngleDeg: Double
    var exitVeloMph: Double
    var exitVeloMps: Double
    var scaleBallMPerPx: Double
    var scaleGravityMPerPx: Double?
    var scaleDisagreement: Double?      // |sg - sb| / sb
    var diameterDrift: Double           // signed fractional change over the track
    var nFrames: Int
    var trackDurationS: Double
    var fitRmsPx: Double
    var t0: Double                      // contact time used (s)
    var vxPxS: Double
    var vyPxS: Double                   // down-positive (image coords)
    /// Ball centre at t0 from the velocity fit (px, raw image coords — the
    /// roll correction rotates velocities only). Extrapolated when the batter
    /// hides the first frames. Feeds the contact-offset (undercut) reading.
    var x0Px: Double = 0
    var y0Px: Double = 0
    var flags: [SwingFlag]

    var highConfidence: Bool { flags.isEmpty }
}
