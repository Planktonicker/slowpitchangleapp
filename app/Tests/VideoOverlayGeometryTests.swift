// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import XCTest
@testable import SwingLab

/// Mapping measured points back onto the picture.
///
/// Pinned because the failure mode is not a crash or an obviously empty
/// screen: it is an overlay drawn ninety degrees out, confidently, on top of
/// real footage — which looks exactly like a broken tracker and would send
/// anyone reading it to tune the wrong thing.
final class VideoOverlayGeometryTests: XCTestCase {

    private let landscape = CGSize(width: 1920, height: 1080)

    /// What an iPhone filming in portrait writes: a landscape buffer plus a
    /// quarter turn.
    private var quarterTurn: CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    }

    // MARK: - Display size

    func testIdentityTransformLeavesTheSizeAlone() {
        let s = VideoOverlayGeometry.displaySize(natural: landscape, transform: .identity)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testQuarterTurnSwapsTheSize() {
        let s = VideoOverlayGeometry.displaySize(natural: landscape, transform: quarterTurn)
        XCTAssertEqual(s.width, 1080, accuracy: 1e-9)
        XCTAssertEqual(s.height, 1920, accuracy: 1e-9)
    }

    // MARK: - Letterboxing

    /// A 16:9 video in a square view gets bars top and bottom, and the overlay
    /// has to land between them rather than on the whole view.
    func testWideVideoInASquareViewIsLetterboxed() {
        let r = VideoOverlayGeometry.videoRect(displaySize: landscape,
                                               in: CGSize(width: 400, height: 400))
        XCTAssertEqual(r.width, 400, accuracy: 1e-9)
        XCTAssertEqual(r.height, 225, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 87.5, accuracy: 1e-9)
    }

    func testDegenerateSizesGiveAnEmptyRect() {
        XCTAssertEqual(VideoOverlayGeometry.videoRect(displaySize: .zero,
                                                      in: CGSize(width: 100, height: 100)),
                       .zero)
        XCTAssertEqual(VideoOverlayGeometry.videoRect(displaySize: landscape, in: .zero), .zero)
    }

    // MARK: - Points

    func testUnrotatedCornersLandOnTheVideoCorners() {
        let view = CGSize(width: 1920, height: 1080)
        let topLeft = VideoOverlayGeometry.viewPoint(bufferPoint: .zero, natural: landscape,
                                                     transform: .identity, in: view)
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-6)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-6)

        let bottomRight = VideoOverlayGeometry.viewPoint(
            bufferPoint: CGPoint(x: 1920, y: 1080), natural: landscape,
            transform: .identity, in: view)
        XCTAssertEqual(bottomRight.x, 1920, accuracy: 1e-6)
        XCTAssertEqual(bottomRight.y, 1080, accuracy: 1e-6)
    }

    /// The case the old overlay got wrong. A point at the LEFT edge of the
    /// encoded buffer belongs at the TOP of a quarter-turned picture, not the
    /// left of it — draw it without the transform and the whole skeleton lands
    /// on its side.
    func testQuarterTurnMovesTheBufferOriginToTheTopRight() {
        let view = CGSize(width: 1080, height: 1920)
        let p = VideoOverlayGeometry.viewPoint(bufferPoint: .zero, natural: landscape,
                                               transform: quarterTurn, in: view)
        XCTAssertEqual(p.x, 1080, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0, accuracy: 1e-6)
    }

    func testQuarterTurnKeepsEveryCornerInsideThePicture() {
        let view = CGSize(width: 1080, height: 1920)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0),
                       CGPoint(x: 0, y: 1080), CGPoint(x: 1920, y: 1080)]
        for c in corners {
            let p = VideoOverlayGeometry.viewPoint(bufferPoint: c, natural: landscape,
                                                   transform: quarterTurn, in: view)
            XCTAssertGreaterThanOrEqual(p.x, -1e-6)
            XCTAssertLessThanOrEqual(p.x, 1080 + 1e-6)
            XCTAssertGreaterThanOrEqual(p.y, -1e-6)
            XCTAssertLessThanOrEqual(p.y, 1920 + 1e-6)
        }
    }

    /// The centre of the buffer is the centre of the picture under any
    /// rotation. Cheap, and it catches a translation dropped from the
    /// transform, which is the classic way this goes wrong.
    func testTheCentreStaysTheCentreUnderRotation() {
        let view = CGSize(width: 540, height: 960)
        let p = VideoOverlayGeometry.viewPoint(bufferPoint: CGPoint(x: 960, y: 540),
                                               natural: landscape,
                                               transform: quarterTurn, in: view)
        XCTAssertEqual(p.x, 270, accuracy: 1e-6)
        XCTAssertEqual(p.y, 480, accuracy: 1e-6)
    }

    // MARK: - Lengths

    /// A ball diameter is a length in encoded pixels and has to shrink with the
    /// picture, or the circle drawn round the ball stops being the size that
    /// was actually measured — which is the one thing this overlay exists to
    /// let somebody check.
    func testScaleMatchesTheLetterboxedPicture() {
        let s = VideoOverlayGeometry.scale(natural: landscape, transform: .identity,
                                           in: CGSize(width: 960, height: 1000))
        XCTAssertEqual(s, 0.5, accuracy: 1e-9)
    }

    func testScaleIsUnaffectedByRotation() {
        let view = CGSize(width: 540, height: 960)
        let s = VideoOverlayGeometry.scale(natural: landscape, transform: quarterTurn, in: view)
        XCTAssertEqual(s, 0.5, accuracy: 1e-9)
    }
}

/// The region the ball search is restricted to.
///
/// This is the bug that made a ball in plain sight "undetected": the corridor
/// filter extrapolates a fitted parabola across the whole frame, while the
/// search region was the bounding box of the few points Vision reported. The
/// two disagreed about where the ball might be and the tighter one won without
/// saying so.
final class TrajectoryHintROITests: XCTestCase {

    private let width = 1920
    private let height = 1080

    /// Points along a gentle downward-opening arc, all in the left third of
    /// the frame — the shape `VNDetectTrajectoriesRequest` typically reports:
    /// a confident segment, not the whole flight.
    private func risingHint() -> TrajectoryHint {
        var pts: [CGPoint] = []
        for x in stride(from: 200.0, through: 500.0, by: 50.0) {
            let y = 0.0008 * (x - 900) * (x - 900) + 300
            pts.append(CGPoint(x: x, y: y))
        }
        return TrajectoryHint(pointsPx: pts, startTime: 0, endTime: 0.2)
    }

    func testTheOldBoxStopsAtTheReportedPoints() throws {
        let roi = try XCTUnwrap(risingHint().roi(pad: 130, width: width, height: height))
        XCTAssertLessThan(roi.x1, 700, "the padded bounding box should not reach mid-frame")
    }

    /// The fix: the region follows the curve on across the frame, so pixels
    /// the corridor would accept actually get examined.
    func testSearchRegionFollowsTheCurvePastTheReportedPoints() throws {
        let roi = try XCTUnwrap(risingHint().searchROI(corridorPx: 90,
                                                       width: width, height: height))
        XCTAssertGreaterThan(roi.x1, 1200,
                             "the search must extend along the extrapolated parabola")
    }

    /// Whatever it extends to, it stays a valid region inside the frame —
    /// an unclamped ROI is a crash or an empty search, not a wider one.
    func testSearchRegionStaysInsideTheFrame() throws {
        let roi = try XCTUnwrap(risingHint().searchROI(corridorPx: 90,
                                                       width: width, height: height))
        XCTAssertGreaterThanOrEqual(roi.x0, 0)
        XCTAssertGreaterThanOrEqual(roi.y0, 0)
        XCTAssertLessThanOrEqual(roi.x1, width)
        XCTAssertLessThanOrEqual(roi.y1, height)
        XCTAssertLessThan(roi.x0, roi.x1)
        XCTAssertLessThan(roi.y0, roi.y1)
    }

    /// Anything the search region excludes, the corridor must also reject —
    /// otherwise the two disagree again and the ball goes missing in the gap.
    func testEveryPointTheCorridorAdmitsIsInsideTheSearchRegion() throws {
        let hint = risingHint()
        let corridor = 90.0
        let roi = try XCTUnwrap(hint.searchROI(corridorPx: corridor,
                                               width: width, height: height))
        for x in stride(from: 0.0, through: Double(width), by: 40) {
            for y in stride(from: 0.0, through: Double(height), by: 40) {
                guard hint.admits(x: x, y: y, corridorPx: corridor) else { continue }
                XCTAssertGreaterThanOrEqual(x, Double(roi.x0), "admitted (\(x), \(y)) is left of the search region")
                XCTAssertLessThanOrEqual(x, Double(roi.x1), "admitted (\(x), \(y)) is right of the search region")
                XCTAssertGreaterThanOrEqual(y, Double(roi.y0), "admitted (\(x), \(y)) is above the search region")
                XCTAssertLessThanOrEqual(y, Double(roi.y1), "admitted (\(x), \(y)) is below the search region")
            }
        }
    }

    func testTooFewPointsToFitStillGivesARegion() throws {
        let hint = TrajectoryHint(pointsPx: [CGPoint(x: 400, y: 300),
                                             CGPoint(x: 450, y: 280)],
                                  startTime: 0, endTime: 0.1)
        let roi = try XCTUnwrap(hint.searchROI(corridorPx: 90, width: width, height: height))
        XCTAssertLessThan(roi.x0, 400)
        XCTAssertGreaterThan(roi.x1, 450)
    }

    /// A candidate far outside the fitted span must survive the corridor, or
    /// the ball is rejected precisely where the fit knows least about it.
    func testCorridorWidensAwayFromTheFittedData() {
        let hint = risingHint()          // fitted over x 200...500
        let corridor = 90.0
        // A point 400 px past the data, 200 px off the extrapolated curve.
        let x = 900.0
        let yHat = 0.0008 * (x - 900) * (x - 900) + 300
        XCTAssertTrue(hint.admits(x: x, y: yHat + 200, corridorPx: corridor),
                      "an extrapolated corridor must not claim 90 px precision 400 px from the data")
    }

    /// Near the data it must still be tight, or it stops rejecting anything.
    func testCorridorStaysTightInsideTheFittedData() {
        let hint = risingHint()
        let x = 350.0
        let yHat = 0.0008 * (x - 900) * (x - 900) + 300
        XCTAssertTrue(hint.admits(x: x, y: yHat + 50, corridorPx: 90))
        XCTAssertFalse(hint.admits(x: x, y: yHat + 400, corridorPx: 90),
                       "inside the fitted span the corridor is the corridor")
    }

    func testNoPointsGivesNoRegion() {
        let hint = TrajectoryHint(pointsPx: [], startTime: 0, endTime: 0)
        XCTAssertNil(hint.searchROI(corridorPx: 90, width: width, height: height))
    }
}
