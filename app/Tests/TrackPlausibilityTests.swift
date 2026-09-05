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
        XCTAssertEqual(fast, 1.96, accuracy: 0.25)
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

    /// An import has no audio trigger, so there is no instant to be late
    /// relative to and the lateness test must not fire on one.
    func testLatenessIsSkippedWhenContactIsUnknown() {
        XCTAssertNil(TrackPlausibility.rejection(track: realFlight, launchAngleDeg: -0.3,
                                                 flags: [], fps: 240, contactTime: nil))
    }
}
