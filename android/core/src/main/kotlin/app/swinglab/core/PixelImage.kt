// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.floor

/**
 * Port of `PixelImage.swift` `PixelImage`; the reasoning lives there.
 *
 * Platform-neutral where the Swift borrows a locked `CVPixelBuffer`, so this
 * module stays free of Android imports. The Android capture and decoder paths
 * fill it; the detector only ever reads it.
 *
 * LAYOUT — the contract whoever fills [bytes] must meet:
 *  - 8-bit **BGRA**, four bytes a pixel in the order B, G, R, A — the same
 *    32BGRA the Swift detector reads, so every index and every channel the
 *    parity-pinned code touches is the same on both platforms. Alpha is never
 *    read; fill it with anything.
 *  - Row-major, row 0 at the TOP of the image, x to the right (image
 *    coordinates, y down — the convention of every pixel position in this
 *    module). Pixel (x, y) starts at byte `y * bytesPerRow + x * 4`.
 *  - Rows are [bytesPerRow] bytes apart, which may exceed `width * 4`; the
 *    padding at the end of a row is never read.
 *  - Bytes are unsigned 0-255 (read through `and 0xFF`).
 *  - Full-range sRGB-ish RGB, converted from the camera's YUV with the colour
 *    matrix (601 vs 709) and range (video vs full) the source frame is tagged
 *    with. `PixelBufferConvert.swift` explains why that matters: a wrong matrix
 *    or range makes a live scale disagree with an offline one for the same ball.
 *
 * A plain class rather than a data class: data-class equality on a ByteArray is
 * reference identity, which would read as "same picture" and mean "same array".
 * The Swift's `withImage(CVPixelBuffer)` is not ported — it only locks a
 * CoreVideo buffer and refuses non-BGRA formats, which here is the caller's job.
 */
class PixelImage(
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
    val bytesPerRow: Int = width * 4,
) {
    init {
        // Kotlin-only guard: the Swift's CVPixelBuffer guarantees these, and an
        // out-of-range read there is undefined behaviour rather than an exception.
        require(width >= 0 && height >= 0) { "PixelImage: negative size ${width}x$height" }
        require(bytesPerRow >= width * 4) { "PixelImage: bytesPerRow $bytesPerRow < width*4" }
        require(height == 0 || bytes.size >= (height - 1) * bytesPerRow + width * 4) {
            "PixelImage: ${bytes.size} bytes cannot hold ${width}x$height at $bytesPerRow per row"
        }
    }

    /** One pixel's colour channels, 0-255 as Doubles; the Swift's `(b:, g:, r:)` tuple. */
    data class BGR(val b: Double, val g: Double, val r: Double)

    /** Port of `PixelImage.lumaPlane`; the reasoning lives there. Unsigned bytes, row-major, `width` apart. */
    fun lumaPlane(): ByteArray {
        val out = ByteArray(width * height)
        for (y in 0 until height) {
            val row = y * bytesPerRow
            val outRow = y * width
            for (x in 0 until width) {
                val p = row + x * 4
                val v = 29 * (bytes[p].toInt() and 0xFF) +
                    150 * (bytes[p + 1].toInt() and 0xFF) +
                    77 * (bytes[p + 2].toInt() and 0xFF)
                out[outRow + x] = ((v + 128) shr 8).toByte()
            }
        }
        return out
    }

    /** Port of `PixelImage.pixel(x:y:)` (edge-clamped); the reasoning lives there. */
    fun pixel(x: Int, y: Int): BGR {
        val p = offset(x, y)
        return BGR(channel(p), channel(p + 1), channel(p + 2))
    }

    /**
     * Port of `PixelImage.sampleBilinear` (OpenCV `remap` INTER_LINEAR,
     * BORDER_REPLICATE); the reasoning lives there. Reads the four corners
     * without allocating a [BGR] each; the arithmetic, and its order, is the Swift's.
     */
    fun sampleBilinear(x: Double, y: Double): BGR {
        val x0 = floor(x).toInt()
        val y0 = floor(y).toInt()
        val fx = x - x0.toDouble()
        val fy = y - y0.toDouble()
        val p00 = offset(x0, y0)
        val p10 = offset(x0 + 1, y0)
        val p01 = offset(x0, y0 + 1)
        val p11 = offset(x0 + 1, y0 + 1)
        val w00 = (1 - fx) * (1 - fy)
        val w10 = fx * (1 - fy)
        val w01 = (1 - fx) * fy
        val w11 = fx * fy
        return BGR(
            channel(p00) * w00 + channel(p10) * w10 + channel(p01) * w01 + channel(p11) * w11,
            channel(p00 + 1) * w00 + channel(p10 + 1) * w10 + channel(p01 + 1) * w01 + channel(p11 + 1) * w11,
            channel(p00 + 2) * w00 + channel(p10 + 2) * w10 + channel(p01 + 2) * w01 + channel(p11 + 2) * w11,
        )
    }

    /** Byte offset of the clamped pixel, exactly the Swift `pixel(x:y:)` clamp. */
    private fun offset(x: Int, y: Int): Int {
        val cx = minOf(maxOf(x, 0), width - 1)
        val cy = minOf(maxOf(y, 0), height - 1)
        return cy * bytesPerRow + cx * 4
    }

    private fun channel(i: Int): Double = (bytes[i].toInt() and 0xFF).toDouble()
}

/**
 * Port of `PixelImage.swift` `HSVConvert` (OpenCV 8-bit HSV: H halved into
 * 0..179, S and V 0..255); the reasoning lives there.
 */
object HSVConvert {

    /** The Swift's `(h:, s:, v:)` tuple. */
    data class HSV(val h: Double, val s: Double, val v: Double)

    /** Port of `HSVConvert.fromBGR`; the reasoning lives there. */
    fun fromBGR(b: Double, g: Double, r: Double): HSV {
        val v = swiftMax(r, swiftMax(g, b))
        val minC = swiftMin(r, swiftMin(g, b))
        val delta = v - minC
        val s = if (v > 0) delta * 255.0 / v else 0.0
        var h = 0.0
        if (delta > 0) {
            h = if (v == r) {
                60 * (g - b) / delta
            } else if (v == g) {
                120 + 60 * (b - r) / delta
            } else {
                240 + 60 * (r - g) / delta
            }
            if (h < 0) h += 360
        }
        return HSV(h / 2, s, v)
    }

    /** Port of `HSVConvert.inRange` (exactly `fromBGR` plus the range tests, short-circuited); the reasoning lives there. */
    fun inRange(b: Double, g: Double, r: Double, lo: HSVBounds, hi: HSVBounds): Boolean {
        val v = swiftMax(r, swiftMax(g, b))
        if (!(v >= lo.v && v <= hi.v)) return false

        val minC = swiftMin(r, swiftMin(g, b))
        val delta = v - minC
        val s = if (v > 0) delta * 255.0 / v else 0.0
        if (!(s >= lo.s && s <= hi.s)) return false

        var h = 0.0
        if (delta > 0) {
            h = if (v == r) {
                60 * (g - b) / delta
            } else if (v == g) {
                120 + 60 * (b - r) / delta
            } else {
                240 + 60 * (r - g) / delta
            }
            if (h < 0) h += 360
        }
        h /= 2
        return h >= lo.h && h <= hi.h
    }
}
