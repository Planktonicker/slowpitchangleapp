// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Whether a chosen track can be stood behind as a struck ball.
///
/// `docs/BIOMECHANICS.md` sets the rule this implements: a number that cannot
/// be stood behind gets flagged, or withheld — never quietly shown looking
/// like every other number. The pipeline has not been following it. On a
/// cluttered clip it picks the best of six hundred candidate tracks, and when
/// the best is a patch of grass it reports a launch angle for the grass, with
/// the same confidence chrome as a real swing. Flags alone are not enough:
/// they qualify a measurement, and this is the case where there is no
/// measurement to qualify.
///
/// So this asks a different question from the flags. Not "how good is this
/// reading" but "is this a ball at all". It is deliberately app-only — the
/// Python reference is handed a track and asked to measure it, and choosing
/// whether to believe one is not its job.
enum TrackPlausibility {

    /// A hit ball is in frame for a fraction of a second. Anything an order of
    /// magnitude longer is something that lives in the scene.
    static let maxFlightS = 2.5
    /// Below this it is not a mis-measured hit, it is not a hit.
    static let minLaunchDeg = -25.0
    static let maxLaunchDeg = 75.0
    /// A ball travels; it does not wander. Well under the selector's own gate,
    /// because here we are asking whether to publish a number at all.
    static let minStraightness = 0.80

    /// `nil` when the track is worth reporting; otherwise why it is not, in
    /// words meant for the person who filmed it.
    static func rejection(track: [BallObservation],
                          launchAngleDeg: Double,
                          flags: [SwingFlag]) -> String? {
        guard let first = track.first, let last = track.last else {
            return "no ball was tracked at all"
        }
        let duration = last.t - first.t
        if duration > maxFlightS {
            return String(format: "the tracked object stayed in frame for %.1f s — a hit ball crosses in a fraction of a second, so this is something in the scene, not the swing", duration)
        }
        if launchAngleDeg < minLaunchDeg || launchAngleDeg > maxLaunchDeg {
            return String(format: "%.0f° is not a hit — that is almost straight %@",
                          launchAngleDeg, launchAngleDeg < 0 ? "into the ground" : "up")
        }
        let straight = TrackBuilder.straightness(track)
        if straight < minStraightness {
            return String(format: "the path wanders (straightness %.2f); a ball in flight does not turn back", straight)
        }
        if flags.contains(.highResidual) {
            return "the path does not fit a parabola, which a ball in flight must"
        }
        return nil
    }
}
