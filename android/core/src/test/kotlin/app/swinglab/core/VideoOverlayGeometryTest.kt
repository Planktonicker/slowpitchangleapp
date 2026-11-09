// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port of `app/Tests/VideoOverlayGeometryTests.swift`, case by case at the same accuracies. */
class VideoOverlayGeometryTest {

    private val landscape = Size(width = 1920.0, height = 1080.0)

    /** What an iPhone filming in portrait writes: a landscape buffer plus a quarter turn. */
    private val quarterTurn: AffineTransform
        get() = AffineTransform(a = 0.0, b = 1.0, c = -1.0, d = 0.0, tx = 1080.0, ty = 0.0)

    // Display size

    @Test
    fun identityTransformLeavesTheSizeAlone() {
        val s = VideoOverlayGeometry.displaySize(natural = landscape, transform = AffineTransform.identity)
        assertEquals(1920.0, s.width)
        assertEquals(1080.0, s.height)
    }

    @Test
    fun quarterTurnSwapsTheSize() {
        val s = VideoOverlayGeometry.displaySize(natural = landscape, transform = quarterTurn)
        assertEquals(1080.0, s.width, 1e-9)
        assertEquals(1920.0, s.height, 1e-9)
    }

    // Letterboxing

    @Test
    fun wideVideoInASquareViewIsLetterboxed() {
        val r = VideoOverlayGeometry.videoRect(displaySize = landscape,
                                               viewSize = Size(width = 400.0, height = 400.0))
        assertEquals(400.0, r.width, 1e-9)
        assertEquals(225.0, r.height, 1e-9)
        assertEquals(0.0, r.minX, 1e-9)
        assertEquals(87.5, r.minY, 1e-9)
    }

    @Test
    fun degenerateSizesGiveAnEmptyRect() {
        assertEquals(Rect.zero, VideoOverlayGeometry.videoRect(displaySize = Size.zero,
                                                               viewSize = Size(width = 100.0, height = 100.0)))
        assertEquals(Rect.zero, VideoOverlayGeometry.videoRect(displaySize = landscape, viewSize = Size.zero))
    }

    // Points

    @Test
    fun unrotatedCornersLandOnTheVideoCorners() {
        val view = Size(width = 1920.0, height = 1080.0)
        val topLeft = VideoOverlayGeometry.viewPoint(bufferPoint = Point.zero, natural = landscape,
                                                     transform = AffineTransform.identity, viewSize = view)
        assertEquals(0.0, topLeft.x, 1e-6)
        assertEquals(0.0, topLeft.y, 1e-6)

        val bottomRight = VideoOverlayGeometry.viewPoint(
            bufferPoint = Point(x = 1920.0, y = 1080.0), natural = landscape,
            transform = AffineTransform.identity, viewSize = view)
        assertEquals(1920.0, bottomRight.x, 1e-6)
        assertEquals(1080.0, bottomRight.y, 1e-6)
    }

    @Test
    fun quarterTurnMovesTheBufferOriginToTheTopRight() {
        val view = Size(width = 1080.0, height = 1920.0)
        val p = VideoOverlayGeometry.viewPoint(bufferPoint = Point.zero, natural = landscape,
                                               transform = quarterTurn, viewSize = view)
        assertEquals(1080.0, p.x, 1e-6)
        assertEquals(0.0, p.y, 1e-6)
    }

    @Test
    fun quarterTurnKeepsEveryCornerInsideThePicture() {
        val view = Size(width = 1080.0, height = 1920.0)
        val corners = listOf(Point(0.0, 0.0), Point(1920.0, 0.0),
                             Point(0.0, 1080.0), Point(1920.0, 1080.0))
        for (c in corners) {
            val p = VideoOverlayGeometry.viewPoint(bufferPoint = c, natural = landscape,
                                                   transform = quarterTurn, viewSize = view)
            assertTrue(p.x >= -1e-6, "x ${p.x} for corner $c")
            assertTrue(p.x <= 1080 + 1e-6, "x ${p.x} for corner $c")
            assertTrue(p.y >= -1e-6, "y ${p.y} for corner $c")
            assertTrue(p.y <= 1920 + 1e-6, "y ${p.y} for corner $c")
        }
    }

    @Test
    fun theCentreStaysTheCentreUnderRotation() {
        val view = Size(width = 540.0, height = 960.0)
        val p = VideoOverlayGeometry.viewPoint(bufferPoint = Point(x = 960.0, y = 540.0),
                                               natural = landscape,
                                               transform = quarterTurn, viewSize = view)
        assertEquals(270.0, p.x, 1e-6)
        assertEquals(480.0, p.y, 1e-6)
    }

    // Tap, inverted

    @Test
    fun tapRoundTripsThroughTheTransform() {
        val view = Size(width = 540.0, height = 960.0)
        for (transform in listOf(AffineTransform.identity, quarterTurn)) {
            for (buffer in listOf(Point(100.0, 80.0), Point(1500.0, 900.0), Point(960.0, 540.0))) {
                val onScreen = VideoOverlayGeometry.viewPoint(
                    bufferPoint = buffer, natural = landscape,
                    transform = transform, viewSize = view)
                val back = VideoOverlayGeometry.bufferPoint(
                    viewPoint = onScreen, natural = landscape,
                    transform = transform, viewSize = view)
                assertNotNull(back, "round trip lost the point")
                assertEquals(buffer.x, back.x, 1e-6)
                assertEquals(buffer.y, back.y, 1e-6)
            }
        }
    }

    @Test
    fun tapOutsideThePictureIsRejected() {
        val view = Size(width = 400.0, height = 400.0)   // 16:9 video, bars top and bottom
        assertNull(VideoOverlayGeometry.bufferPoint(
            viewPoint = Point(x = 200.0, y = 10.0), natural = landscape,
            transform = AffineTransform.identity, viewSize = view))
    }

    // Lengths

    @Test
    fun scaleMatchesTheLetterboxedPicture() {
        val s = VideoOverlayGeometry.scale(natural = landscape, transform = AffineTransform.identity,
                                           viewSize = Size(width = 960.0, height = 1000.0))
        assertEquals(0.5, s, 1e-9)
    }

    @Test
    fun scaleIsUnaffectedByRotation() {
        val view = Size(width = 540.0, height = 960.0)
        val s = VideoOverlayGeometry.scale(natural = landscape, transform = quarterTurn, viewSize = view)
        assertEquals(0.5, s, 1e-9)
    }
}
