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

    /// How far a struck ball moves between frames, as a multiple of its own
    /// width. **Scale-free on purpose**, and that is the whole reason this is
    /// the right shape for the test: it is a ratio of two lengths measured in
    /// the same pixels, so it does not inherit the diameter scale, which
    /// `docs/VALIDATION.md` records failing by 11% at a 37 px ball and 43% at
    /// 26 px. An mph floor would be gating on the number we trust least.
    ///
    /// Measured on real clips: hits that were verified by their own geometry
    /// ran 1.96 and 2.5 diameters a frame. `live_49` — a clip the hitter
    /// labelled as having NO swing in it — produced a reading of 10.1° at
    /// 4.8 mph from a blob drifting at 0.075, and every other gate here passed
    /// it: 71 ms long, angle in range, straightness 0.91, no residual flag. It
    /// was published as a measurement.
    ///
    /// 0.20 sits about 2.7x above that blob and covers a hit down to roughly
    /// 11 mph, which is weaker than a slow-pitch dribbler. The gap either side
    /// is wide enough that this does not need tuning.
    static let minDiametersPerFrame = 0.20

    /// Above the fastest exit velocity ever recorded in softball, by a
    /// margin. Not a performance judgement — a backstop against arithmetic
    /// that has gone somewhere physical reality does not go. `live_48`
    /// published 198.2 mph.
    static let maxExitVeloMph = 130.0

    /// Below this many points a quadratic residual means nothing, so
    /// `SwingFlag.highResidual` cannot fire and the parabola test is not
    /// available. Four points against three coefficients leaves one degree of
    /// freedom: the fit is near-exact whatever the points are doing.
    ///
    /// This is the hole the relaxed near-contact minimum opened. Admitting
    /// four-frame tracks was necessary — a real flight on `live_42` was four
    /// frames — but it removed the one gate that would have caught `live_48`,
    /// whose four points accelerate 3.3x and fit a parabola perfectly.
    static let residualMeaninglessBelow = 6

    /// How much a short track's speed may grow end to end before it stops
    /// being ballistic.
    ///
    /// Over the few tens of milliseconds these tracks span, gravity adds well
    /// under one percent to a struck ball's speed and drag subtracts a little,
    /// so a real flight is near-constant: the verified four-point flight on
    /// `live_42` ran 6100, 6494, 8364 px/s — a ratio of 1.37, and that number
    /// is noise on a three-millisecond baseline. `live_48`'s junk ran 2454,
    /// 5060, 8075 — a ratio of 3.3. Two is between them with room on both
    /// sides, and it is only applied where the residual test cannot run.
    static let maxShortTrackSpeedGrowth = 2.0

    /// A hit ball is at the bat when the bat meets it. Selection already
    /// prefers tracks that begin in a window around contact but falls back
    /// when the window is empty — so on a clip with no swing in it, the
    /// fallback returns whatever else moved, and this is where that gets
    /// caught rather than reported. Matches `SLA.selectContactLateS`.
    static let maxStartAfterContactS = 0.25

    /// `nil` when the track is worth reporting; otherwise why it is not, in
    /// words meant for the person who filmed it.
    /// - Parameters:
    ///   - fps: needed to express speed per FRAME rather than per second.
    ///   - contactTime: when known. `nil` on an imported clip, where there is
    ///     no audio trigger and so no instant to be late relative to — the
    ///     lateness test is then skipped rather than guessed at.
    static func rejection(track: [BallObservation],
                          launchAngleDeg: Double,
                          flags: [SwingFlag],
                          fps: Double = 0,
                          contactTime: Double? = nil,
                          exitVeloMph: Double = 0) -> String? {
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
        if fps > 0, let perFrame = diametersPerFrame(track: track, fps: fps),
           perFrame < minDiametersPerFrame {
            return String(format: "the tracked object moved %.2f of its own width per frame; a struck ball moves about two, so this is something drifting in the scene", perFrame)
        }
        if let contactTime, first.t - contactTime > maxStartAfterContactS {
            return String(format: "it was first seen %.2f s after contact — a hit ball is at the bat when the bat meets it, so this is something else that moved later in the clip", first.t - contactTime)
        }
        // The other half of the same idea, and the one that caught `live_48`:
        // a track can BEGIN inside the contact window and still be over before
        // contact happens. A struck ball's flight is after contact by
        // definition — there is no such thing as a hit that finished before
        // the bat arrived. The whole track sat 39 ms to 2 ms BEFORE it.
        if let contactTime, last.t < contactTime {
            return String(format: "the whole path was over %.0f ms before contact — a struck ball's flight begins when the bat meets it, so this is something that crossed beforehand", (contactTime - last.t) * 1000)
        }
        if exitVeloMph > maxExitVeloMph {
            return String(format: "%.0f mph is faster than any softball has been hit", exitVeloMph)
        }
        if track.count < residualMeaninglessBelow,
           let growth = speedGrowth(track: track), growth > maxShortTrackSpeedGrowth {
            return String(format: "it sped up %.1f-fold across %d frames; a ball in flight holds its speed, and a track this short cannot be checked against a parabola", growth, track.count)
        }
        return nil
    }

    /// Last frame-to-frame speed over the first. `nil` when there are fewer
    /// than two steps to compare.
    ///
    /// Deliberately end-to-end rather than a fitted acceleration: on three
    /// steps a fit has nothing to spare, and the question being asked is
    /// coarse — did this thing roughly double in speed while it was watched.
    static func speedGrowth(track: [BallObservation]) -> Double? {
        var steps: [Double] = []
        for (a, b) in zip(track, track.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            steps.append((dx * dx + dy * dy).squareRoot() / dt)
        }
        guard steps.count >= 2, let f = steps.first, let l = steps.last, f > 0 else { return nil }
        return l / f
    }

    /// Median frame-to-frame travel as a multiple of the tracked object's own
    /// median diameter. `nil` when there is nothing to measure.
    ///
    /// Median on both, so one blurred frame or one missed detection moves
    /// neither. Same upper-median convention as `TrackBuilder.medianStepSpeed`.
    static func diametersPerFrame(track: [BallObservation], fps: Double) -> Double? {
        guard fps > 0, track.count >= 2 else { return nil }
        var steps: [Double] = []
        for (a, b) in zip(track, track.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            steps.append((dx * dx + dy * dy).squareRoot() / dt)
        }
        let diameters = track.map(\.diameterPx).filter { $0 > 0 }.sorted()
        guard !steps.isEmpty, !diameters.isEmpty else { return nil }
        steps.sort()
        let medianStep = steps[steps.count / 2]
        let medianDiameter = diameters[diameters.count / 2]
        guard medianDiameter > 0 else { return nil }
        return (medianStep / fps) / medianDiameter
    }
}
