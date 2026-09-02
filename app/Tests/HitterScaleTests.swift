// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import ImageIO
import XCTest
@testable import SwingLab

/// The maths behind "stand tall in the box and the app measures how far away
/// the camera is".
///
/// Pinned rather than eyeballed for the same reason `CameraPoseTests` is: the
/// only place these numbers are ever seen is a single line of text on a live
/// picture, where a distance that is wrong by five percent looks exactly like
/// one that is right.
final class HitterScaleTests: XCTestCase {

    // A typical iPhone wide lens on a 1080p240 buffer.
    private let fov = 68.0
    private let widthPx = 1920.0
    private let heightPx = 1080.0
    private var focal: Double { TiltRectifier.focalPx(widthPx: widthPx, fovDeg: fov) }
    private var cx: Double { widthPx / 2 }
    private var cy: Double { heightPx / 2 }

    private let hitterHeightM = 1.75
    private let distanceM = 5.25

    /// The nose-to-ankle span a 1.75 m hitter shows at 5.25 m through this lens.
    private var expectedSpanPx: Double {
        focal * hitterHeightM * HitterScale.noseToAnkleStatureFraction / distanceM
    }

    // MARK: - A synthetic hitter

    /// Upright buffer pixels for someone standing in the middle of the frame.
    ///
    /// Both legs are built exactly vertical, so a straight-knee reading is 180°
    /// by construction and any deviation in a test comes from what that test
    /// changed. Nose and mean ankle share an x, so the span is purely vertical
    /// and equals the argument.
    private func skeleton(spanPx: Double,
                          kneeOffset: Double = 0,
                          leanDx: Double = 0,
                          includeAnkles: Bool = true) -> [PoseJoint: CGPoint] {
        let top = cy - spanPx / 2
        let footY = cy + spanPx / 2
        let shoulderY = top + 0.10 * spanPx
        let hipY = top + 0.45 * spanPx
        let kneeY = top + 0.72 * spanPx
        var joints: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: cx, y: top),
            .leftShoulder: CGPoint(x: cx - 70 + leanDx, y: shoulderY),
            .rightShoulder: CGPoint(x: cx + 70 + leanDx, y: shoulderY),
            .leftHip: CGPoint(x: cx - 20, y: hipY),
            .rightHip: CGPoint(x: cx + 20, y: hipY),
            .leftKnee: CGPoint(x: cx - 20 + kneeOffset, y: kneeY),
            .rightKnee: CGPoint(x: cx + 20 + kneeOffset, y: kneeY),
        ]
        if includeAnkles {
            joints[.leftAnkle] = CGPoint(x: cx - 20, y: footY)
            joints[.rightAnkle] = CGPoint(x: cx + 20, y: footY)
        }
        return joints
    }

    private func acceptedSpan(_ joints: [PoseJoint: CGPoint], tiltDeg: Double = 0) throws -> Double {
        let verdict = HitterScale.evaluate(upright: joints, tiltDeg: tiltDeg,
                                           focalPx: focal, cx: cx, cy: cy)
        guard case .accepted(let span) = verdict else {
            XCTFail("expected an accepted sample, got \(verdict)")
            throw XCTSkip("not accepted")
        }
        return span
    }

    // MARK: - The gate

    func testStandingTallIsAccepted() throws {
        let span = try acceptedSpan(skeleton(spanPx: expectedSpanPx))
        XCTAssertEqual(span, expectedSpanPx, accuracy: 1e-6)
    }

    /// A batting crouch shortens the nose-to-ankle span by 7–12 %, which would
    /// read back as a camera that had moved a third of a metre. Refused, with
    /// the reason, rather than measured.
    func testBentKneesAreRejected() {
        let joints = skeleton(spanPx: expectedSpanPx,
                              kneeOffset: 0.16 * expectedSpanPx)   // ~120° at the knee
        XCTAssertEqual(HitterScale.evaluate(upright: joints, tiltDeg: 0,
                                            focalPx: focal, cx: cx, cy: cy),
                       .rejected(.knees))
    }

    func testLeaningIsRejected() {
        // 25° of spine lean: shoulders pushed forward of the hips.
        let joints = skeleton(spanPx: expectedSpanPx,
                              leanDx: tan(25 * Double.pi / 180) * 0.35 * expectedSpanPx)
        XCTAssertEqual(HitterScale.evaluate(upright: joints, tiltDeg: 0,
                                            focalPx: focal, cx: cx, cy: cy),
                       .rejected(.leaning))
    }

    func testMissingAnklesAreOutOfFrame() {
        let joints = skeleton(spanPx: expectedSpanPx, includeAnkles: false)
        XCTAssertEqual(HitterScale.evaluate(upright: joints, tiltDeg: 0,
                                            focalPx: focal, cx: cx, cy: cy),
                       .rejected(.outOfFrame))
    }

    // MARK: - Optics

    func testDistanceRoundTrips() throws {
        let d = try XCTUnwrap(HitterScale.distanceM(spanPx: expectedSpanPx,
                                                    hitterHeightM: hitterHeightM,
                                                    focalPx: focal))
        XCTAssertEqual(d, distanceM, accuracy: 1e-6)
    }

    /// Tilt at 12°, not at 3°.
    ///
    /// At 3° the raw span is off by about a third of a percent, which is inside
    /// the band this test is supposed to be policing — the assertion would pass
    /// with the rectification deleted. At 12° the uncorrected reading misses by
    /// more than 4 %, so the test can tell the difference between correcting the
    /// tilt and ignoring it.
    func testTiltIsUndoneBeforeTheSpanIsMeasured() throws {
        let tilt = 12.0
        // Build the picture a camera aimed 12° down would have recorded, by
        // running the rectification backwards over the level-camera points.
        var tilted: [PoseJoint: CGPoint] = [:]
        for (joint, p) in skeleton(spanPx: expectedSpanPx) {
            let r = TiltRectifier.rectify(x: Double(p.x), y: Double(p.y),
                                          tiltDeg: -tilt, focalPx: focal, cx: cx, cy: cy)
            tilted[joint] = CGPoint(x: r.x, y: r.y)
        }

        let rawSpan = try acceptedSpan(tilted, tiltDeg: 0)
        let rawDistance = try XCTUnwrap(HitterScale.distanceM(spanPx: rawSpan,
                                                              hitterHeightM: hitterHeightM,
                                                              focalPx: focal))
        XCTAssertGreaterThan(abs(rawDistance - distanceM) / distanceM, 0.03,
                             "an uncorrected 12° tilt must miss by more than the test's own tolerance")

        let corrected = try acceptedSpan(tilted, tiltDeg: tilt)
        let d = try XCTUnwrap(HitterScale.distanceM(spanPx: corrected,
                                                    hitterHeightM: hitterHeightM,
                                                    focalPx: focal))
        XCTAssertEqual(d, distanceM, accuracy: distanceM * 0.005)
    }

    // MARK: - Orientation

    private func normalized(_ joints: [PoseJoint: CGPoint]) -> [PoseJoint: CGPoint] {
        joints.mapValues { CGPoint(x: Double($0.x) / widthPx, y: Double($0.y) / heightPx) }
    }

    /// The buffer is landscape-native however the phone is held, so the other
    /// landscape is the same picture through 180°. Both must measure the same
    /// person the same length.
    func testBothLandscapesGiveTheSameSpan() throws {
        let upright = skeleton(spanPx: expectedSpanPx)
        let up = try XCTUnwrap(HitterScale.uprightPixels(normalized(upright), orientation: .up,
                                                         widthPx: widthPx, heightPx: heightPx))
        let flipped = normalized(upright).mapValues {
            CGPoint(x: 1 - Double($0.x), y: 1 - Double($0.y))
        }
        let down = try XCTUnwrap(HitterScale.uprightPixels(flipped, orientation: .down,
                                                           widthPx: widthPx, heightPx: heightPx))
        let upSpan = try acceptedSpan(up)
        let downSpan = try acceptedSpan(down)
        XCTAssertEqual(upSpan, expectedSpanPx, accuracy: 1e-6)
        XCTAssertEqual(downSpan, upSpan, accuracy: 1e-6)
    }

    /// In portrait the buffer's y axis runs sideways across the world. There is
    /// no height to read, and inventing one is worse than showing nothing.
    func testPortraitHasNoReading() {
        let joints = normalized(skeleton(spanPx: expectedSpanPx))
        XCTAssertNil(HitterScale.uprightPixels(joints, orientation: .right,
                                               widthPx: widthPx, heightPx: heightPx))
        XCTAssertNil(HitterScale.uprightPixels(joints, orientation: .left,
                                               widthPx: widthPx, heightPx: heightPx))
    }

    // MARK: - Sampling

    func testSamplerHoldsOutUntilItHasEnough() throws {
        var sampler = HitterScale.Sampler()
        for i in 0..<4 { sampler.add(spanPx: 400 + Double(i), at: Double(i) * 0.1) }
        XCTAssertEqual(sampler.count(at: 0.3), 4)
        XCTAssertNil(sampler.medianIfReady(at: 0.3))

        sampler.add(spanPx: 402, at: 0.4)
        let median = try XCTUnwrap(sampler.medianIfReady(at: 0.4))
        XCTAssertEqual(median, 402, accuracy: 1e-9)
    }

    /// One frame where the pose model puts an ankle on the fence is an outlier
    /// of arbitrary size. The median absorbs it; a mean would not.
    func testMedianIgnoresOneWildSample() throws {
        var sampler = HitterScale.Sampler()
        for span in [410.0, 412.0, 411.0, 9000.0, 413.0] {
            sampler.add(spanPx: span, at: 0)
        }
        let median = try XCTUnwrap(sampler.medianIfReady(at: 0))
        XCTAssertEqual(median, 412, accuracy: 1e-9)
    }

    func testSamplesOlderThanTheWindowArePruned() {
        var sampler = HitterScale.Sampler()
        for i in 0..<5 { sampler.add(spanPx: 410, at: Double(i) * 0.1) }
        XCTAssertNotNil(sampler.medianIfReady(at: 0.4))
        // Four seconds later, every one of them has aged out.
        sampler.add(spanPx: 410, at: 4.4)
        XCTAssertEqual(sampler.count(at: 4.4), 1)
        XCTAssertNil(sampler.medianIfReady(at: 4.4))
    }

    func testResetEmptiesTheWindow() {
        var sampler = HitterScale.Sampler()
        for i in 0..<5 { sampler.add(spanPx: 410, at: Double(i) * 0.1) }
        sampler.reset()
        XCTAssertEqual(sampler.count(at: 0.5), 0)
        XCTAssertNil(sampler.medianIfReady(at: 0.5))
    }
}
