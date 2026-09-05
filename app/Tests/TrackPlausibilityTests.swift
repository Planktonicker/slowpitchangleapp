// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import XCTest
@testable import SwingLab

/// The gate that decides whether to publish a number at all.
///
/// Pinned on real clips, because every threshold here was set from one and a
/// synthetic case cannot say whether the number separates the two things it
/// has to separate.
final class TrackPlausibilityTests: XCTestCase {

    private func track(_ pts: [(t: Double, x: Double, y: Double, d: Double)]) -> [BallObservation] {
        pts.enumerated().map { i, p in
            BallObservation(frame: i, t: p.t, x: p.x, y: p.y,
                            diameterPx: p.d, areaPx: 80)
        }
    }

    /// `live_49`, which the hitter labelled as having NO swing in it. The app
    /// published 10.1 deg at 4.8 mph from this: a blob drifting 11 px to the
    /// left over 71 ms. Every gate that existed passed it — 71 ms long, angle
    /// in range, straightness 0.91, no residual flag — because none of them
    /// asked how fast it was going.
    private var driftingBlob: [BallObservation] {
        track([(2.229371, 500.16, 499.61, 9.52), (2.233538, 499.40, 499.48, 9.05),
               (2.237704, 498.96, 499.83, 9.32), (2.241883, 498.24, 499.82, 9.36),
               (2.266879, 493.42, 499.40, 10.26), (2.275212, 492.38, 499.84, 10.75),
               (2.279379, 491.61, 498.95, 9.69), (2.291875, 490.37, 500.16, 8.71),
               (2.300208, 489.01, 500.49, 10.00)])
    }

    /// `live_39`, verified as the ball by fitting the incoming pitch and the
    /// outgoing flight separately and finding they intersect within 4 px.
    private var realFlight: [BallObservation] {
        track([(1.4883, 740.2, 509.0, 11.1), (1.5050, 797.6, 540.7, 16.0),
               (1.5083, 818.1, 552.9, 19.1), (1.5167, 855.9, 563.1, 8.9),
               (1.5250, 895.0, 577.9, 10.7), (1.5333, 928.8, 593.6, 11.9),
               (1.5383, 947.3, 600.2, 12.9), (1.5417, 962.6, 606.2, 16.7),
               (1.5500, 998.6, 621.6, 9.5), (1.5550, 1013.8, 631.0, 11.0),
               (1.5583, 1027.2, 638.2, 8.3)])
    }

    func testTheGapBetweenARealFlightAndSceneryIsWide() throws {
        let slow = try XCTUnwrap(TrackPlausibility.diametersPerFrame(track: driftingBlob, fps: 240))
        let fast = try XCTUnwrap(TrackPlausibility.diametersPerFrame(track: realFlight, fps: 240))
        XCTAssertEqual(slow, 0.075, accuracy: 0.02)
        // 1.75, not the 1.96 first quoted from a nominal 10 px ball — this
        // track's own median diameter is 11.1 px, and the whole point of the
        // measure is that it uses the ball's real width.
        XCTAssertEqual(fast, 1.75, accuracy: 0.30)
        // The threshold has to sit clear of BOTH, or it is tuned to one clip.
        XCTAssertGreaterThan(TrackPlausibility.minDiametersPerFrame, slow * 2)
        XCTAssertLessThan(TrackPlausibility.minDiametersPerFrame, fast / 4)
    }

    func testADriftingBlobIsRejected() {
        let why = TrackPlausibility.rejection(track: driftingBlob, launchAngleDeg: 10.1,
                                              flags: [], fps: 240)
        XCTAssertNotNil(why, "the reading live_49 published must now be withheld")
        XCTAssertTrue(why?.contains("own width per frame") == true, why ?? "nil")
    }

    /// The same track under the gates as they were: every one passes. This is
    /// the regression test — it fails the moment somebody removes the speed
    /// floor and assumes the others were enough.
    func testEveryOtherGatePassesThatBlob() {
        XCTAssertNil(TrackPlausibility.rejection(track: driftingBlob, launchAngleDeg: 10.1,
                                                 flags: [], fps: 0),
                     "without fps there is no speed gate, and nothing else catches it")
    }

    func testARealFlightSurvives() {
        XCTAssertNil(TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                                 flags: [], fps: 240, contactTime: 1.4525))
    }

    /// A track that begins long after contact is something that moved later in
    /// the clip. On `live_49` the chosen one began 0.669 s after.
    func testATrackThatStartsLongAfterContactIsRejected() {
        let why = TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                              flags: [], fps: 240,
                                              contactTime: realFlight[0].t - 0.7)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("after contact") == true, why ?? "nil")
    }

    /// `live_48`, also labelled as having no swing. It published 22.1 deg at
    /// 198.2 mph from four points that END 1.9 ms BEFORE contact and speed up
    /// 3.3-fold while being watched.
    ///
    /// It defeats every gate added for `live_49`: 2.14 diameters a frame is a
    /// perfectly ball-like speed, and it BEGINS 39 ms before contact, inside
    /// the window. What it cannot do is finish before the bat arrives.
    private var preContactFragment: [BallObservation] {
        track([(1.541800, 1123.52, 185.64, 8.89), (1.554300, 1151.18, 198.91, 13.50),
               (1.566800, 1213.96, 191.23, 9.87), (1.579304, 1308.63, 156.13, 8.83)])
    }

    func testAPathThatEndsBeforeContactIsRejected() {
        let why = TrackPlausibility.rejection(track: preContactFragment,
                                              launchAngleDeg: 22.1, flags: [.shortTrack],
                                              fps: 240, contactTime: 1.581249,
                                              exitVeloMph: 198.2)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("before contact") == true, why ?? "nil")
    }

    /// The gates added for the previous clip do NOT catch this one. Pinned so
    /// nobody removes the new ones believing the old ones cover it.
    func testTheEarlierGatesDoNotCatchIt() throws {
        let perFrame = try XCTUnwrap(
            TrackPlausibility.diametersPerFrame(track: preContactFragment, fps: 240))
        XCTAssertGreaterThan(perFrame, TrackPlausibility.minDiametersPerFrame,
                             "2.14 diameters a frame is a ball-like speed")
        let start = preContactFragment[0].t - 1.581249
        XCTAssertLessThan(start, TrackPlausibility.maxStartAfterContactS,
                          "it begins inside the contact window")
    }

    /// A track too short for a quadratic residual to mean anything gets a
    /// direct ballistic check instead. Four points against three coefficients
    /// leaves one degree of freedom, so `highResidual` can never fire.
    func testAShortTrackThatSpeedsUpIsRejected() {
        XCTAssertLessThan(preContactFragment.count,
                          TrackPlausibility.residualMeaninglessBelow)
        let growth = TrackPlausibility.speedGrowth(track: preContactFragment)
        XCTAssertEqual(growth ?? 0, 3.29, accuracy: 0.15)
        // Contact deliberately omitted, to isolate the growth gate.
        let why = TrackPlausibility.rejection(track: preContactFragment,
                                              launchAngleDeg: 22.1, flags: [.shortTrack],
                                              fps: 240)
        XCTAssertTrue(why?.contains("sped up") == true, why ?? "nil")
    }

    /// The four-point flight on `live_42`, verified by geometry, must survive
    /// the growth gate — it is the case the relaxed minimum exists for.
    func testAVerifiedFourPointFlightSurvivesTheGrowthGate() {
        let real = track([(1.4667, 848.8, 497.6, 10.0), (1.4717, 879.3, 496.7, 11.8),
                          (1.4800, 933.2, 498.2, 12.6), (1.4833, 960.8, 498.2, 8.6)])
        let growth = TrackPlausibility.speedGrowth(track: real)
        XCTAssertEqual(growth ?? 0, 1.37, accuracy: 0.15)
        XCTAssertLessThan(growth ?? 99, TrackPlausibility.maxShortTrackSpeedGrowth)
        XCTAssertNil(TrackPlausibility.rejection(track: real, launchAngleDeg: -0.3,
                                                 flags: [.shortTrack], fps: 240,
                                                 contactTime: 1.4525, exitVeloMph: 62))
    }

    func testAnImpossibleExitVelocityIsRejected() {
        let why = TrackPlausibility.rejection(track: realFlight, launchAngleDeg: 22.1,
                                              flags: [], fps: 240, exitVeloMph: 198.2)
        XCTAssertTrue(why?.contains("mph") == true, why ?? "nil")
    }

    /// The regression this nearly shipped: an EARLY trigger is the most
    /// common fault the app has — three of the first four clips examined had
    /// one — and the analyzer already handles it by disowning the audio
    /// instant and re-deriving contact from the first frame of the flight.
    /// `ClipAnalysis` still reports the original audio time, so a lateness
    /// test against it would reject the real ball for arriving late relative
    /// to a moment nothing believes any more.
    func testContactGatesAreSkippedWhenTheTriggerIsKnownToBeWrong() {
        // A real flight, half a second after a trigger that fired early.
        let contact = realFlight[0].t - 0.5
        XCTAssertNotNil(TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                                    flags: [], fps: 240,
                                                    contactTime: contact),
                        "without the flag, lateness rejects it")
        XCTAssertNil(TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                                 flags: [.contactTimeRejected], fps: 240,
                                                 contactTime: contact),
                     "with the flag, the contact time is disowned and must not be judged against")
    }

    /// live_48 keeps being caught: its flags do NOT include
    /// contactTimeRejected, so the pre-contact gate still applies to it.
    func testThePreContactGateStillCatchesLive48() {
        let why = TrackPlausibility.rejection(track: preContactFragment,
                                              launchAngleDeg: 22.1,
                                              flags: [.shortTrack, .depthMotion],
                                              fps: 240, contactTime: 1.581249)
        XCTAssertNotNil(why)
    }

    /// An import has no audio trigger, so there is no instant to be late
    /// relative to and the lateness test must not fire on one.
    func testLatenessIsSkippedWhenContactIsUnknown() {
        XCTAssertNil(TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                                 flags: [], fps: 240, contactTime: nil))
    }
}
