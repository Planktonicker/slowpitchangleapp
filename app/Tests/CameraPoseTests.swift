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
