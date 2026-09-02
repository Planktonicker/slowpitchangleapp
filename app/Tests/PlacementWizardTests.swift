// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import ImageIO
import XCTest
@testable import SwingLab

/// The setup screen's state machine: which stage, which distance method, and
/// what it takes to lock a measurement.
///
/// `@MainActor` throughout, because `PlacementWizard` is — it owns published
/// state that drives a live view over a 240fps preview.
///
/// One thing these tests deliberately do NOT drive is camera tilt.
/// `LevelSensor.tiltDeg` is `private(set)` and fed by CoreMotion, so there is
/// no honest way to set it from here; the tilt rectification the wizard applies
/// is pinned in `HitterScaleTests`, against the same functions.
@MainActor
final class PlacementWizardTests: XCTestCase {

    private let widthPx = 1920.0
    private let heightPx = 1080.0
    private let fov = 68.0
    private let hitterHeightM = 1.75
    private let distanceM = 5.25

    private var focal: Double { TiltRectifier.focalPx(widthPx: widthPx, fovDeg: fov) }

    private func makeWizard(height: Double? = 1.75) -> PlacementWizard {
        let wizard = PlacementWizard()
        wizard.imageWidthPx = widthPx
        wizard.imageHeightPx = heightPx
        wizard.fieldOfViewDeg = fov
        wizard.bufferOrientation = .up
        // Silenced: the tone stands up an AVAudioEngine, which has no business
        // in a unit test and no speaker to reach.
        wizard.lockChime = {}
        wizard.hitterHeightM = height
        return wizard
    }

    /// The span a 1.75 m hitter shows at 5.25 m through this lens.
    private var expectedSpanPx: Double {
        focal * hitterHeightM * HitterScale.noseToAnkleStatureFraction / distanceM
    }

    /// A standing hitter, in the device-normalized coordinates the capture
    /// controller publishes.
    private func standingJoints() -> [PoseJoint: CGPoint] {
        let cx = widthPx / 2, cy = heightPx / 2
        let span = expectedSpanPx
        let top = cy - span / 2
        let foot = cy + span / 2
        let pixels: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: cx, y: top),
            .leftShoulder: CGPoint(x: cx - 70, y: top + 0.10 * span),
            .rightShoulder: CGPoint(x: cx + 70, y: top + 0.10 * span),
            .leftHip: CGPoint(x: cx - 20, y: top + 0.45 * span),
            .rightHip: CGPoint(x: cx + 20, y: top + 0.45 * span),
            .leftKnee: CGPoint(x: cx - 20, y: top + 0.72 * span),
            .rightKnee: CGPoint(x: cx + 20, y: top + 0.72 * span),
            .leftAnkle: CGPoint(x: cx - 20, y: foot),
            .rightAnkle: CGPoint(x: cx + 20, y: foot),
        ]
        return pixels.mapValues { CGPoint(x: Double($0.x) / widthPx, y: Double($0.y) / heightPx) }
    }

    private func feedStandingHitter(_ wizard: PlacementWizard, samples: Int = 5) {
        let joints = standingJoints()
        for i in 0..<samples {
            wizard.noteSkeleton(joints, hitterPresent: true, at: Double(i) * 0.1)
        }
    }

    // MARK: - Stages

    func testStagesAdvanceAndClampAtBothEnds() {
        let wizard = makeWizard()
        XCTAssertEqual(wizard.stage, .level)
        wizard.back()
        XCTAssertEqual(wizard.stage, .level, "there is nothing before the first stage")
        wizard.advance()
        XCTAssertEqual(wizard.stage, .hitter)
        wizard.skip()
        XCTAssertEqual(wizard.stage, .ready)
        wizard.advance()
        XCTAssertEqual(wizard.stage, .ready, "there is nothing after the last stage")
        wizard.back()
        XCTAssertEqual(wizard.stage, .hitter)
        wizard.go(to: .level)
        XCTAssertEqual(wizard.stage, .level)
    }

    func testBeginSetupReturnsToTheFirstStage() {
        let wizard = makeWizard()
        wizard.go(to: .ready)
        wizard.beginSetup()
        XCTAssertEqual(wizard.stage, .level)
    }

    /// Plate mode owns the preview's touches and its display zoom, so it cannot
    /// be left running underneath another stage.
    func testLeavingTheHitterStageEndsPlateMode() {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        wizard.distanceMethod = .plate
        wizard.advance()
        XCTAssertEqual(wizard.distanceMethod, .hitter)
    }

    // MARK: - Measuring from the hitter

    func testWithoutAHeightThereIsNothingToScaleAgainst() {
        let wizard = makeWizard(height: nil)
        wizard.go(to: .hitter)
        feedStandingHitter(wizard)
        XCTAssertEqual(wizard.hitterScaleState, .needHeight)
        XCTAssertEqual(wizard.scaleSource, .none)
    }

    func testFiveGoodSamplesLockTheDistance() throws {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        feedStandingHitter(wizard)

        XCTAssertEqual(wizard.hitterScaleState, .locked)
        XCTAssertEqual(wizard.scaleSource, .hitter)
        let d = try XCTUnwrap(wizard.derivedDistanceM)
        XCTAssertEqual(d, distanceM, accuracy: 1e-6)
        XCTAssertTrue(wizard.captureFlags.contains(.distanceFromHitterHeight))
        XCTAssertEqual(wizard.distanceSourceLabel, "hitter height")
    }

    func testFourSamplesAreNotEnough() {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        feedStandingHitter(wizard, samples: 4)
        XCTAssertEqual(wizard.hitterScaleState, .sampling(accepted: 4, needed: 5))
        XCTAssertEqual(wizard.scaleSource, .none)
    }

    /// The chime is the only signal that reaches a hitter standing several
    /// metres from a screen they cannot read.
    func testTheLockChimesExactlyOnce() {
        let wizard = makeWizard()
        var chimes = 0
        wizard.lockChime = { chimes += 1 }
        wizard.go(to: .hitter)
        feedStandingHitter(wizard, samples: 8)
        XCTAssertEqual(chimes, 1)
    }

    /// A crouching hitter's span is 7-12% short, which would read back as a
    /// camera that had moved a third of a metre.
    func testACrouchIsRefusedWithItsReason() {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        var joints = standingJoints()
        // Knees pushed forward: about 120 degrees at the joint.
        let offset = 0.16 * expectedSpanPx / widthPx
        joints[.leftKnee] = CGPoint(x: Double(joints[.leftKnee]?.x ?? 0) + offset,
                                    y: Double(joints[.leftKnee]?.y ?? 0))
        joints[.rightKnee] = CGPoint(x: Double(joints[.rightKnee]?.x ?? 0) + offset,
                                     y: Double(joints[.rightKnee]?.y ?? 0))
        for i in 0..<5 { wizard.noteSkeleton(joints, hitterPresent: true, at: Double(i) * 0.1) }
        XCTAssertEqual(wizard.hitterScaleState, .notUpright(.knees))
        XCTAssertEqual(wizard.scaleSource, .none)
    }

    /// Portrait: the buffer's y axis runs sideways across the world, so there is
    /// no span to measure and the panel has to say so rather than count.
    func testPortraitAsksForLandscape() {
        let wizard = makeWizard()
        wizard.bufferOrientation = .right
        wizard.go(to: .hitter)
        feedStandingHitter(wizard)
        XCTAssertEqual(wizard.hitterScaleState, .landscapeNeeded)
        XCTAssertEqual(wizard.scaleSource, .none)
    }

    func testNoSamplingOutsideTheHitterStage() {
        for stage in [PlacementWizard.SetupStage.level, .ready] {
            let wizard = makeWizard()
            wizard.go(to: stage)
            feedStandingHitter(wizard)
            XCTAssertEqual(wizard.scaleSource, .none, "sampled during \(stage)")
        }
    }

    func testNoSamplingWhileAnotherMethodIsInUse() {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        wizard.distanceMethod = .ball
        feedStandingHitter(wizard)
        XCTAssertEqual(wizard.scaleSource, .none)
    }

    /// "0 of 5" before anybody is in frame reads as a broken counter.
    func testClearingReturnsToLookingForTheHitter() {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        feedStandingHitter(wizard)
        XCTAssertEqual(wizard.scaleSource, .hitter)

        wizard.clearScale()
        XCTAssertEqual(wizard.hitterScaleState, .noHitter)
        XCTAssertEqual(wizard.scaleSource, .none)
        XCTAssertNil(wizard.measuredPxPerM)
        XCTAssertNil(wizard.lockedSpanPx)
        XCTAssertEqual(wizard.distanceMethod, .hitter,
                       "clearing a reading must not change how the next one is taken")
    }

    /// The lock is a span in pixels; the height is only what it is divided by.
    func testCorrectingTheHeightRescalesWithoutRemeasuring() throws {
        let wizard = makeWizard()
        wizard.go(to: .hitter)
        feedStandingHitter(wizard)
        let before = try XCTUnwrap(wizard.derivedDistanceM)

        wizard.hitterHeightM = 1.60
        let after = try XCTUnwrap(wizard.derivedDistanceM)
        XCTAssertEqual(after, before * 1.60 / 1.75, accuracy: 1e-6)
        XCTAssertEqual(wizard.scaleSource, .hitter)
    }

    // MARK: - Plate

    /// 17 in, and it is the plate's DEPTH — front edge to rear point, along the
    /// pitch line, which is across the picture from a side-on camera.
    func testPlateDepthIsSeventeenInches() {
        XCTAssertEqual(PlacementWizard.plateDepthM, 17.0 * 0.0254, accuracy: 1e-12)
    }

    func testPlateMarkersGiveTheDistance() throws {
        let wizard = makeWizard()
        let spanPx = focal * PlacementWizard.plateDepthM / distanceM
        wizard.plateStart = CGPoint(x: 0.40, y: 0.60)
        wizard.plateEnd = CGPoint(x: 0.40 + spanPx / widthPx, y: 0.60)
        wizard.applyPlateMeasurement()

        XCTAssertEqual(wizard.scaleSource, .plate)
        let d = try XCTUnwrap(wizard.derivedDistanceM)
        XCTAssertEqual(d, distanceM, accuracy: 1e-6)
        XCTAssertEqual(wizard.distanceSourceLabel, "plate")
    }

    /// The normalized axes are not isotropic. Converting both with the width
    /// overweighted any vertical component by 1.78 on a 16:9 buffer.
    func testAVerticalPlateSpanMeasuresTheSameAsAHorizontalOne() throws {
        let spanPx = focal * PlacementWizard.plateDepthM / distanceM

        let across = makeWizard()
        across.plateStart = CGPoint(x: 0.40, y: 0.60)
        across.plateEnd = CGPoint(x: 0.40 + spanPx / widthPx, y: 0.60)
        across.applyPlateMeasurement()

        let down = makeWizard()
        down.plateStart = CGPoint(x: 0.40, y: 0.30)
        down.plateEnd = CGPoint(x: 0.40, y: 0.30 + spanPx / heightPx)
        down.applyPlateMeasurement()

        let a = try XCTUnwrap(across.derivedDistanceM)
        let b = try XCTUnwrap(down.derivedDistanceM)
        XCTAssertEqual(a, b, accuracy: 1e-6)
    }

    // MARK: - Ball

    func testBallMeasurementSetsTheScaleAndItsSource() throws {
        let wizard = makeWizard()
        wizard.applyBallMeasurement(diameterPx: 26, atX: 1200, atY: 700)
        XCTAssertEqual(wizard.scaleSource, .ball)
        XCTAssertEqual(wizard.lastBallDiameterPx, 26)
        XCTAssertEqual(try XCTUnwrap(wizard.measuredPxPerM),
                       26 / SLA.ballDiameterM, accuracy: 1e-9)
        XCTAssertEqual(wizard.distanceSourceLabel, "ball")
    }

    /// The other landscape is the same picture through 180 degrees, so a tap on
    /// the same real ball must produce the same scale. The mapping that makes
    /// that true is `CameraPose.uprightBufferPoint`, which the ball path did not
    /// go through before.
    func testTheTwoLandscapesAgreeAboutWhereATapLanded() throws {
        let up = try XCTUnwrap(CameraPose.uprightBufferPoint(
            CGPoint(x: 1200, y: 700), orientation: .up, width: widthPx, height: heightPx))
        let down = try XCTUnwrap(CameraPose.uprightBufferPoint(
            CGPoint(x: widthPx - 1200, y: heightPx - 700),
            orientation: .down, width: widthPx, height: heightPx))
        XCTAssertEqual(Double(up.x), Double(down.x), accuracy: 1e-9)
        XCTAssertEqual(Double(up.y), Double(down.y), accuracy: 1e-9)
    }
}
