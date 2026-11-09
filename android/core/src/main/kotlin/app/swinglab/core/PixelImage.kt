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

    /**
     * Port of `PixelImage.lumaPlane`. Unsigned bytes, row-major, `width` apart.
     *
     * Deliberately NOT the Swift's arithmetic: the Swift used 29/150/77 out of
     * 256 on the grounds that any reasonable luma answers "did this pixel
     * change", but the motion gate's threshold is strict (`> 18`), so a luma one
     * count off flips every pixel whose change sits on the line, and that 8-bit
     * sum is one count off `cv2.cvtColor(BGR2GRAY)` — what every Python caller
     * hands `motion_mask` — on 13% of colours. This is OpenCV's own 15-bit sum,
     * exact on all 2^24 (pinned by the `cv_color` fixture's digest).
     */
    fun lumaPlane(): ByteArray {
        val out = ByteArray(width * height)
        for (y in 0 until height) {
            val row = y * bytesPerRow
            val outRow = y * width
            for (x in 0 until width) {
                val p = row + x * 4
                out[outRow + x] = luma(bytes[p].toInt() and 0xFF,
                                       bytes[p + 1].toInt() and 0xFF,
                                       bytes[p + 2].toInt() and 0xFF).toByte()
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
     *
     * The diameter probe no longer samples through this: OpenCV 5's float remap
     * interpolates in float32 with fused multiply-adds, up to 2e-5 of a level
     * away from this Double bilinear, and the probe now reproduces that instead
     * (see [BallDetector.subpixelDiameter]).
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

    companion object {
        /** `cv2.cvtColor(BGR2GRAY)` of one pixel: OpenCV's `RGB2Gray<uchar>`, 15-bit weights, rounded. */
        fun luma(b: Int, g: Int, r: Int): Int = (b * 3735 + g * 19235 + r * 9798 + (1 shl 14)) shr 15
    }
}

/**
 * Port of `PixelImage.swift` `HSVConvert` (OpenCV 8-bit HSV: H halved into
 * 0..179, S and V 0..255); the reasoning lives there.
 *
 * Deliberately NOT the Swift's arithmetic. The Swift promised "OpenCV-compatible
 * 8-bit HSV" but computed it unrounded, and `cv2.cvtColor` ROUNDS H and S (in
 * fixed point) before `cv2.inRange` compares them: S 99.78 is 100 to OpenCV and
 * inside a window that starts at 100. Over all 2^24 colours the default window
 * admits 69,679 more of them than the unrounded test does, and every one of
 * those is a pixel the reference's mask has and the Swift's did not. This is
 * OpenCV's `RGB2HSV_b` exactly, integer for integer (pinned by the `cv_color`
 * fixture's digest of every colour).
 */
object HSVConvert {

    /** The Swift's `(h:, s:, v:)` tuple. Whole numbers here, as OpenCV's are. */
    data class HSV(val h: Double, val s: Double, val v: Double)

    private const val HSV_SHIFT = 12

    // OpenCV's tables: saturate_cast<int>((255 << 12) / i) and ((180 << 12) / (6 i)).
    // No entry is a tie, so how saturate_cast breaks ties cannot matter.
    private val sdiv = IntArray(256) { if (it == 0) 0 else ((255 shl HSV_SHIFT) / it.toDouble()).rounded().toInt() }
    private val hdiv = IntArray(256) { if (it == 0) 0 else ((180 shl HSV_SHIFT) / (6.0 * it)).rounded().toInt() }

    /** `cv2.cvtColor(BGR2HSV)` of one 8-bit pixel, packed `h shl 16 or s shl 8 or v`. */
    fun packedFromBGR(b: Int, g: Int, r: Int): Int {
        val v = maxOf(b, g, r)
        val diff = v - minOf(b, g, r)
        val vr = if (v == r) -1 else 0
        val vg = if (v == g) -1 else 0
        val s = (diff * sdiv[v] + (1 shl (HSV_SHIFT - 1))) shr HSV_SHIFT
        var h = (vr and (g - b)) +
            (vr.inv() and ((vg and (b - r + 2 * diff)) + (vg.inv() and (r - g + 4 * diff))))
        h = (h * hdiv[diff] + (1 shl (HSV_SHIFT - 1))) shr HSV_SHIFT
        if (h < 0) h += 180
        return (h shl 16) or (s shl 8) or v
    }

    /** Port of `HSVConvert.fromBGR`, on OpenCV's rounded values. Channels are whole 0-255 values, as every caller's are. */
    fun fromBGR(b: Double, g: Double, r: Double): HSV {
        val p = packedFromBGR(b.toInt(), g.toInt(), r.toInt())
        return HSV((p shr 16).toDouble(), ((p shr 8) and 0xFF).toDouble(), (p and 0xFF).toDouble())
    }

    /** Port of `HSVConvert.inRange`: `fromBGR` plus `cv2.inRange`'s inclusive tests. */
    fun inRange(b: Double, g: Double, r: Double, lo: HSVBounds, hi: HSVBounds): Boolean =
        inRange(b.toInt(), g.toInt(), r.toInt(), lo, hi)

    /**
     * As above, from the bytes themselves; the mask loop calls this one. The
     * arithmetic of [packedFromBGR], short-circuited as the Swift's is: most of
     * a frame of grass and sky fails on V or S before H is worth computing.
     */
    fun inRange(b: Int, g: Int, r: Int, lo: HSVBounds, hi: HSVBounds): Boolean {
        val v = maxOf(b, g, r)
        if (!(v >= lo.v && v <= hi.v)) return false
        val diff = v - minOf(b, g, r)
        val s = (diff * sdiv[v] + (1 shl (HSV_SHIFT - 1))) shr HSV_SHIFT
        if (!(s >= lo.s && s <= hi.s)) return false
        val vr = if (v == r) -1 else 0
        val vg = if (v == g) -1 else 0
        var h = (vr and (g - b)) +
            (vr.inv() and ((vg and (b - r + 2 * diff)) + (vg.inv() and (r - g + 4 * diff))))
        h = (h * hdiv[diff] + (1 shl (HSV_SHIFT - 1))) shr HSV_SHIFT
        if (h < 0) h += 180
        return h >= lo.h && h <= hi.h
    }
}
