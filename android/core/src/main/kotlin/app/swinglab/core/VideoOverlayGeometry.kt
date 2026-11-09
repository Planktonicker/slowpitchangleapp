// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs

/**
 * Port of `VideoOverlayGeometry.swift` `enum VideoOverlayGeometry` (encoded buffer
 * pixels to view points and back); the reasoning lives there.
 *
 * The Swift's `in viewSize:` argument label is spelled `viewSize` here, because
 * `in` is a Kotlin keyword and a backticked parameter name reads worse than
 * the Swift's own internal name.
 */
object VideoOverlayGeometry {

    /** Port of `VideoOverlayGeometry.displaySize(natural:transform:)`. */
    fun displaySize(natural: Size, transform: AffineTransform): Size {
        val t = natural.applying(transform)
        return Size(width = abs(t.width), height = abs(t.height))
    }

    /** Port of `VideoOverlayGeometry.videoRect(displaySize:in:)`: aspect-fit, centred. */
    fun videoRect(displaySize: Size, viewSize: Size): Rect {
        if (!(displaySize.width > 0 && displaySize.height > 0 &&
                viewSize.width > 0 && viewSize.height > 0)) return Rect.zero
        val scale = swiftMin(viewSize.width / displaySize.width,
                             viewSize.height / displaySize.height)
        val w = displaySize.width * scale
        val h = displaySize.height * scale
        return Rect(x = (viewSize.width - w) / 2, y = (viewSize.height - h) / 2,
                    width = w, height = h)
    }

    /** Port of `VideoOverlayGeometry.scale(natural:transform:in:)`: points per encoded pixel. */
    fun scale(natural: Size, transform: AffineTransform, viewSize: Size): Double {
        val display = displaySize(natural = natural, transform = transform)
        val rect = videoRect(displaySize = display, viewSize = viewSize)
        if (!(display.width > 0)) return 0.0
        return rect.width / display.width
    }

    /** Port of `VideoOverlayGeometry.bufferPoint(viewPoint:natural:transform:in:)`; null outside the picture. */
    fun bufferPoint(viewPoint: Point, natural: Size, transform: AffineTransform, viewSize: Size): Point? {
        val p = viewPoint
        val display = displaySize(natural = natural, transform = transform)
        val rect = videoRect(displaySize = display, viewSize = viewSize)
        if (!(rect.width > 0 && rect.height > 0 && rect.contains(p))) return null
        val dx = (p.x - rect.minX) * (display.width / rect.width)
        val dy = (p.y - rect.minY) * (display.height / rect.height)
        val det = transform.a * transform.d - transform.b * transform.c
        if (!(abs(det) > 1e-12)) return Point(dx, dy)
        return Point(dx, dy).applying(transform.inverted())
    }

    /** Port of `VideoOverlayGeometry.isQuarterTurned(natural:transform:)`. */
    fun isQuarterTurned(natural: Size, transform: AffineTransform): Boolean {
        val d = displaySize(natural = natural, transform = transform)
        return abs(d.width - natural.height) < 1 && abs(d.height - natural.width) < 1
    }

    /** Port of `VideoOverlayGeometry.viewPoint(bufferPoint:natural:transform:in:)`. */
    fun viewPoint(bufferPoint: Point, natural: Size, transform: AffineTransform, viewSize: Size): Point {
        val display = displaySize(natural = natural, transform = transform)
        val rect = videoRect(displaySize = display, viewSize = viewSize)
        if (!(display.width > 0 && display.height > 0)) return Point.zero
        val p = bufferPoint.applying(transform)
        return Point(x = rect.minX + p.x * (rect.width / display.width),
                     y = rect.minY + p.y * (rect.height / display.height))
    }
}
