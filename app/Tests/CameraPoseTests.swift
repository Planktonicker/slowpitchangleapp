// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import ImageIO
import XCTest
@testable import SwingLab

/// The geometry behind the setup screen's horizon line and camera-height
/// readout.
///
/// Pinned rather than eyeballed because these numbers are only ever seen as a
/// line on a moving picture, where being wrong by a factor of two — or, worse,
/// by a sign — looks exactly like being right. The batter outline was wrong in
/// precisely that way for a whole field trip.
final class CameraPoseTests: XCTestCase {

    // A typical iPhone wide lens.
    private let fov = 68.0

    // MARK: - Field of view

    func testVerticalHalfAngleIsNarrowerThanHorizontal() throws {
        let v = try XCTUnwrap(CameraPose.verticalHalfAngleDeg(horizontalFovDeg: fov,
                                                              frameAspect: 16.0 / 9.0))
        XCTAssertLessThan(v, fov / 2)
        XCTAssertEqual(v, 20.78, accuracy: 0.02)
    }

    func testSquareFrameHasEqualHalfAngles() throws {
        let v = try XCTUnwrap(CameraPose.verticalHalfAngleDeg(horizontalFovDeg: fov,
                                                              frameAspect: 1))
        XCTAssertEqual(v, fov / 2, accuracy: 1e-9)
    }

    func testNonsenseOpticsReturnNil() {
        XCTAssertNil(CameraPose.verticalHalfAngleDeg(horizontalFovDeg: 0, frameAspect: 1.78))
        XCTAssertNil(CameraPose.verticalHalfAngleDeg(horizontalFovDeg: fov, frameAspect: 0))
    }

    /// Portrait shows the full horizontal sweep down the screen's long axis;
    /// landscape crops it. Getting this backwards is what put the batter
    /// outline at half its correct size in one orientation.
    func testPortraitSeesMoreVerticallyThanLandscape() throws {
        let portrait = try XCTUnwrap(CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg: fov, isLandscape: false, screenAspect: 9.0 / 19.5))
        let landscape = try XCTUnwrap(CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg: fov, isLandscape: true, screenAspect: 19.5 / 9.0))
        XCTAssertGreaterThan(portrait, landscape)
        XCTAssertEqual(portrait, fov / 2, accuracy: 1e-9)
    }

    // MARK: - Horizon

    func testLevelCameraPutsHorizonAtFrameCentre() throws {
        let f = try XCTUnwrap(CameraPose.horizonFraction(tiltDeg: 0,
                                                         visibleVerticalHalfAngleDeg: 21))
        XCTAssertEqual(f, 0.5, accuracy: 1e-9)
    }

    /// Aiming down fills the frame with ground, so the horizon climbs. This is
    /// the sign everybody gets backwards, including an earlier draft of the
    /// level chip.
    func testAimingDownRaisesTheHorizon() throws {
        let f = try XCTUnwrap(CameraPose.horizonFraction(tiltDeg: 10,
                                                         visibleVerticalHalfAngleDeg: 21))
        XCTAssertLessThan(f, 0.5)
    }

    func testAimingUpLowersTheHorizon() throws {
        let f = try XCTUnwrap(CameraPose.horizonFraction(tiltDeg: -10,
                                                         visibleVerticalHalfAngleDeg: 21))
        XCTAssertGreaterThan(f, 0.5)
    }

    /// Tilting by exactly the half-angle should place the horizon on the frame
    /// edge — the check that ties the projection to the field of view rather
    /// than to an arbitrary gain.
    func testTiltOfHalfAngleLandsHorizonOnTheEdge() throws {
        let f = try XCTUnwrap(CameraPose.horizonFraction(tiltDeg: 21,
                                                         visibleVerticalHalfAngleDeg: 21))
        XCTAssertEqual(f, 0, accuracy: 1e-9)
    }

    func testHorizonIsReportedOffFrameRatherThanClamped() throws {
        let f = try XCTUnwrap(CameraPose.horizonFraction(tiltDeg: 40,
                                                         visibleVerticalHalfAngleDeg: 21))
        XCTAssertLessThan(f, 0, "an off-frame horizon must stay off-frame so the UI can say so")
    }

    func testHorizonUndefinedPastVertical() {
        XCTAssertNil(CameraPose.horizonFraction(tiltDeg: 90, visibleVerticalHalfAngleDeg: 21))
    }

    // MARK: - Tilt from a placed horizon

    /// The round trip that makes the horizon tool trustworthy: a tilt drawn as
    /// a line, read back off that line, has to be the tilt you started with.
    func testTiltRoundTripsThroughTheHorizon() throws {
        for tilt in [-30.0, -12.0, -3.0, 0.0, 4.5, 15.0, 33.0] {
            let f = try XCTUnwrap(CameraPose.horizonFraction(
                tiltDeg: tilt, visibleVerticalHalfAngleDeg: 21))
            let back = try XCTUnwrap(CameraPose.tiltDeg(
                forHorizonFraction: f, visibleVerticalHalfAngleDeg: 21))
            XCTAssertEqual(back, tilt, accuracy: 1e-6)
        }
    }

    func testHorizonAtFrameCentreIsLevel() throws {
        let t = try XCTUnwrap(CameraPose.tiltDeg(forHorizonFraction: 0.5,
                                                 visibleVerticalHalfAngleDeg: 21))
        XCTAssertEqual(t, 0, accuracy: 1e-9)
    }

    /// A horizon low in the frame means the lens is pointed above it.
    func testHorizonBelowCentreMeansAimingUp() throws {
        let t = try XCTUnwrap(CameraPose.tiltDeg(forHorizonFraction: 0.8,
                                                 visibleVerticalHalfAngleDeg: 21))
        XCTAssertLessThan(t, 0)
    }

    func testHorizonAboveCentreMeansAimingDown() throws {
        let t = try XCTUnwrap(CameraPose.tiltDeg(forHorizonFraction: 0.2,
                                                 visibleVerticalHalfAngleDeg: 21))
        XCTAssertGreaterThan(t, 0)
    }

    // MARK: - Lens height

    /// A level camera lying on the ground sees the feet of anything standing on
    /// that ground at the exact centre of the frame — the horizon and the
    /// ground meet. This is the case that was actually filmed, and the one the
    /// batter outline happily accepted.
    func testLevelCameraOnTheGroundReadsZeroHeight() {
        let h = CameraPose.lensHeightM(feetFraction: 0.5, distanceM: 5,
                                       tiltDeg: 0, verticalHalfAngleDeg: 21)
        // Feet exactly on the horizon is the degenerate case: a height of zero
        // is not a height, and saying nothing beats saying "0.0 m".
        XCTAssertNil(h)
    }

    func testFeetBelowCentreGiveAPositiveHeight() throws {
        let h = try XCTUnwrap(CameraPose.lensHeightM(feetFraction: 0.75, distanceM: 5,
                                                     tiltDeg: 0, verticalHalfAngleDeg: 21))
        XCTAssertGreaterThan(h, 0)
        // 0.75 is a quarter of the frame below centre, i.e. half the half-angle
        // in tangent space: tan(depression) = 0.5 * tan(21 deg).
        XCTAssertEqual(h, 5 * 0.5 * tan(21 * .pi / 180), accuracy: 1e-6)
    }

    func testFeetAtFrameBottomOfLevelCameraGiveTheFullHalfAngle() throws {
        let h = try XCTUnwrap(CameraPose.lensHeightM(feetFraction: 1.0, distanceM: 5,
                                                     tiltDeg: 0, verticalHalfAngleDeg: 21))
        XCTAssertEqual(h, 5 * tan(21 * .pi / 180), accuracy: 1e-6)
    }

    /// The round trip that matters: put a camera at a known height, work out
    /// where the feet must appear, and recover the height.
    func testHeightRoundTripsThroughTheProjection() throws {
        let vHalf = 21.0, distance = 5.25, tilt = 6.0, trueHeight = 1.1
        let depression = atan(trueHeight / distance)
        let offAxis = depression - tilt * .pi / 180
        let feet = 0.5 + tan(offAxis) / (2 * tan(vHalf * .pi / 180))
        let recovered = try XCTUnwrap(CameraPose.lensHeightM(
            feetFraction: feet, distanceM: distance,
            tiltDeg: tilt, verticalHalfAngleDeg: vHalf))
        XCTAssertEqual(recovered, trueHeight, accuracy: 1e-6)
    }

    /// Aiming up moves the feet down the frame. A reading that would put the
    /// ground above the lens's own horizon is not a low camera, it is three
    /// disagreeing inputs, and it must not be dressed up as a height.
    func testFeetAboveTheHorizonReturnNil() {
        XCTAssertNil(CameraPose.lensHeightM(feetFraction: 0.2, distanceM: 5,
                                            tiltDeg: 0, verticalHalfAngleDeg: 21))
    }

    func testAbsurdDistanceReturnsNil() {
        XCTAssertNil(CameraPose.lensHeightM(feetFraction: 0.8, distanceM: 0,
                                            tiltDeg: 0, verticalHalfAngleDeg: 21))
    }

    // MARK: - Outline validity

    func testOutlineValidWhenLevelAndAtContactHeight() {
        XCTAssertTrue(CameraPose.outlineIsValid(tiltDeg: 1, tiltToleranceDeg: 3,
                                                lensHeightM: 1.1))
    }

    /// The whole point. A phone on the ground, aimed up enough to put the
    /// hitter back inside the figure, must not be told the figure fits.
    func testOutlineInvalidForAPhoneOnTheGroundAimedUp() {
        XCTAssertFalse(CameraPose.outlineIsValid(tiltDeg: -18, tiltToleranceDeg: 3,
                                                 lensHeightM: 0.1))
    }

    func testOutlineInvalidOnHeightAloneEvenWhenPerfectlyLevel() {
        XCTAssertFalse(CameraPose.outlineIsValid(tiltDeg: 0, tiltToleranceDeg: 3,
                                                 lensHeightM: 0.15))
    }

    /// An unmeasured height is not a failed one — nobody has stood in frame
    /// yet. Refusing the outline until then would deadlock setup, since
    /// standing in the outline is how the hitter gets into frame.
    func testUnmeasuredHeightDoesNotInvalidateTheOutline() {
        XCTAssertTrue(CameraPose.outlineIsValid(tiltDeg: 0, tiltToleranceDeg: 3,
                                                lensHeightM: nil))
    }

    func testUnknownTiltInvalidatesTheOutline() {
        XCTAssertFalse(CameraPose.outlineIsValid(tiltDeg: nil, tiltToleranceDeg: 3,
                                                 lensHeightM: 1.1))
    }

    // MARK: - Feet from the pose

    /// The buffer is landscape-native however the phone is held, so "down the
    /// buffer" is only "down in the world" one way up. An unchecked reading
    /// would be confidently upside down rather than obviously broken.
    func testFeetFractionPassesThroughWhenUpright() throws {
        let joints: [PoseJoint: CGPoint] = [
            .leftAnkle: CGPoint(x: 0.3, y: 0.80),
            .rightAnkle: CGPoint(x: 0.32, y: 0.84),
        ]
        let f = try XCTUnwrap(SetupOverlay.feetFraction(from: joints, orientation: .up))
        XCTAssertEqual(f, 0.82, accuracy: 1e-9)
    }

    func testFeetFractionInvertsForTheOtherLandscape() throws {
        let joints: [PoseJoint: CGPoint] = [.leftAnkle: CGPoint(x: 0.3, y: 0.80)]
        let f = try XCTUnwrap(SetupOverlay.feetFraction(from: joints, orientation: .down))
        XCTAssertEqual(f, 0.20, accuracy: 1e-9)
    }

    /// In portrait the buffer's y axis runs sideways across the world. There
    /// is no height to read, and inventing one is worse than showing nothing.
    func testFeetFractionRefusesPortrait() {
        let joints: [PoseJoint: CGPoint] = [.leftAnkle: CGPoint(x: 0.3, y: 0.80)]
        XCTAssertNil(SetupOverlay.feetFraction(from: joints, orientation: .right))
        XCTAssertNil(SetupOverlay.feetFraction(from: joints, orientation: .left))
    }

    func testFeetFractionNeedsAnAnkle() {
        XCTAssertNil(SetupOverlay.feetFraction(from: nil, orientation: .up))
        XCTAssertNil(SetupOverlay.feetFraction(from: [.nose: CGPoint(x: 0.3, y: 0.2)],
                                               orientation: .up))
    }
}

/// Frame rate measured from a clip's own sample timing.
///
/// The reason this is not a setting any more: real footage is not limited to
/// the round rates a picker can list. The first clip this app was handed was
/// 198.94 fps, which no preset could express — and exit velocity scales
/// directly with this number, so "near enough" is a proportional error in
/// every speed the app reports.
final class FrameTimingTests: XCTestCase {

    private func intervals(fps: Double, count: Int) -> [Double] {
        Array(repeating: 1 / fps, count: count)
    }

    func testRecoversARoundRate() throws {
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: intervals(fps: 240, count: 60)))
        XCTAssertEqual(t.fps, 240, accuracy: 1e-9)
        XCTAssertEqual(t.irregularFraction, 0, accuracy: 1e-9)
    }

    /// The rate the owner's own phone records at. A four-preset picker could
    /// only offer 200, which is a 0.5% error presented as a choice.
    func testRecoversAnAwkwardRate() throws {
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: intervals(fps: 198.94, count: 60)))
        XCTAssertEqual(t.fps, 198.94, accuracy: 1e-6)
    }

    /// A dropped frame doubles one interval. The rate must not move — and the
    /// gap must be reported as a frame that never arrived, not as a timestamp
    /// that cannot be trusted. The two have different fixes: one is the phone
    /// keeping up, the other is footage to throw away.
    func testASingleDroppedFrameIsAGapNotBadTiming() throws {
        var ints = intervals(fps: 240, count: 60)
        ints[30] *= 2
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertEqual(t.fps, 240, accuracy: 1e-9)
        XCTAssertEqual(t.irregularFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(t.droppedFraction, 1.0 / 61, accuracy: 1e-9)
    }

    /// The clip that exposed all of this, reproduced from its own container.
    ///
    /// `AVAssetWriter` gave the passthrough video track QuickTime's default
    /// time scale of 600, and 600 cannot express 240 fps — a frame is 2.5
    /// ticks — so 594 frames were written as an alternation of 2 and 3 ticks
    /// with real gaps between. The old median-based estimate landed on 3 ticks
    /// and reported 200 fps, then called every 2-tick interval irregular: 61%
    /// of a clip whose camera had been keeping perfect time, and a report that
    /// told the hitter the footage was unusable.
    func testAContainerTooCoarseToExpressTheRateStillReadsAsSquare() throws {
        let tick = 1.0 / 600
        // Straight from the clip's `stts`: ticks, and how many frames had them.
        let histogram: [(ticks: Int, count: Int)] = [
            (3, 233), (2, 224), (5, 69), (7, 21), (10, 20),
            (8, 15), (12, 4), (15, 3), (20, 2), (17, 1),
        ]
        var ints: [Double] = []
        for (ticks, count) in histogram {
            ints.append(contentsOf: Array(repeating: Double(ticks) * tick, count: count))
        }
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertEqual(t.fps, 240, accuracy: 2, "the alternation averages back to 240")
        XCTAssertLessThan(t.irregularFraction, 0.01,
                          "quantisation is not variable frame rate")
        // The real fault in that clip, and the one worth telling a hitter
        // about: nearly a third of the frames never reached the file.
        XCTAssertEqual(t.droppedFraction, 0.30, accuracy: 0.02)
    }

    /// The same clip, with its timestamps arriving the way they really do.
    ///
    /// The test above builds each interval as `Double(ticks) / 600`, and that
    /// arithmetic is exact enough that `shortest * 1.5` lands a hair ABOVE the
    /// 3-tick value and the alternation is kept. Real intervals are
    /// differences of `CMTime.seconds` — `543/600 - 540/600` — which carry
    /// rounding of a few parts in 10^16, so the 5th percentile picks a 2-tick
    /// sample that is a hair SHORT and `shortest * 1.5` then lands just BELOW
    /// 3 ticks. Every 3-tick interval is discarded, the base period becomes 2
    /// ticks, and the clip reads 300 fps.
    ///
    /// Not a rounding curiosity: the frame rate scales every velocity the app
    /// reports, so this is a silent 25% error on exit velocity. Found by
    /// replaying `spike/corpus/` (see `spike/replay_corpus.py`), on four real
    /// clips at once.
    func testTimestampRoundingCannotFlipTheBasePeriod() throws {
        // Cumulative PTS in ticks, alternating 2 and 3 — then differenced in
        // seconds, exactly as `forEachSampleBuffer` hands them over.
        var ints: [Double] = []
        var ticks = 0
        var previous = 0.0
        for i in 0..<600 {
            ticks += (i % 2 == 0) ? 2 : 3
            let seconds = Double(ticks) / 600
            ints.append(seconds - previous)
            previous = seconds
        }
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertEqual(t.fps, 240, accuracy: 1,
                       "the alternation must average back to 240, not collapse to 300")
        XCTAssertLessThan(t.irregularFraction, 0.01)
        XCTAssertEqual(t.droppedFraction, 0, accuracy: 0.01,
                       "nothing was dropped — every frame is there")
    }

    /// Variable frame rate has to be visible, not averaged away: every timing
    /// measurement downstream assumes an even interval.
    func testVariableRateIsReportedAsIrregular() throws {
        var ints = intervals(fps: 240, count: 60)
        for i in stride(from: 0, to: 60, by: 2) { ints[i] *= 1.6 }
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertGreaterThan(t.irregularFraction, 0.4)
    }

    /// Gaps of many different sizes are still gaps. A clip that lost one frame
    /// here and seven there has nothing wrong with its timestamps.
    func testAssortedGapsAreAllReadAsDroppedFrames() throws {
        var ints = intervals(fps: 240, count: 60)
        for (i, periods) in [(10, 2.0), (20, 4.0), (30, 8.0), (40, 3.0)] {
            ints[i] *= periods
        }
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertEqual(t.fps, 240, accuracy: 1e-9)
        XCTAssertEqual(t.irregularFraction, 0, accuracy: 1e-9)
        // 56 single periods + 2 + 4 + 8 + 3 = 73 expected, 60 arrived.
        XCTAssertEqual(t.droppedFraction, 13.0 / 73, accuracy: 1e-9)
    }

    func testRefusesTooFewIntervals() {
        XCTAssertNil(ClipAnalyzer.frameTiming(fromIntervals: [1.0 / 240, 1.0 / 240]))
        XCTAssertNil(ClipAnalyzer.frameTiming(fromIntervals: []))
    }

    func testIgnoresNonPositiveAndNonFiniteIntervals() throws {
        var ints = intervals(fps: 240, count: 20)
        ints.append(contentsOf: [0, -1.0 / 240, .nan, .infinity])
        let t = try XCTUnwrap(ClipAnalyzer.frameTiming(fromIntervals: ints))
        XCTAssertEqual(t.fps, 240, accuracy: 1e-9)
        XCTAssertEqual(t.intervals, 20)
    }
}
