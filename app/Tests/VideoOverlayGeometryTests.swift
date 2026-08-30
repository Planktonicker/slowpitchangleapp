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

    // MARK: - Tap, inverted

    /// The tap that seeds a track has to land on the pixel the user saw. Any
    /// error here points the ball-picker at the wrong object, which is worse
    /// than not having it.
    func testTapRoundTripsThroughTheTransform() {
        let view = CGSize(width: 540, height: 960)
        for transform in [CGAffineTransform.identity, quarterTurn] {
            for buffer in [CGPoint(x: 100, y: 80), CGPoint(x: 1500, y: 900),
                           CGPoint(x: 960, y: 540)] {
                let onScreen = VideoOverlayGeometry.viewPoint(
                    bufferPoint: buffer, natural: landscape,
                    transform: transform, in: view)
                guard let back = VideoOverlayGeometry.bufferPoint(
                    viewPoint: onScreen, natural: landscape,
                    transform: transform, in: view) else {
                    XCTFail("round trip lost the point")
                    continue
                }
                XCTAssertEqual(back.x, buffer.x, accuracy: 1e-6)
                XCTAssertEqual(back.y, buffer.y, accuracy: 1e-6)
            }
        }
    }

    /// A tap in the letterbox bar is not a point in the picture.
    func testTapOutsideThePictureIsRejected() {
        let view = CGSize(width: 400, height: 400)   // 16:9 video, bars top and bottom
        XCTAssertNil(VideoOverlayGeometry.bufferPoint(
            viewPoint: CGPoint(x: 200, y: 10), natural: landscape,
            transform: .identity, in: view))
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
