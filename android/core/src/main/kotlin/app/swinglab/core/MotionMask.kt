// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/** Port of `MotionMask.swift` `MotionMask` (sla_common.motion_mask); the reasoning lives there. */
object MotionMask {

    /**
     * Port of `MotionMask.Luma`: one frame's luma, unsigned bytes, row-major,
     * `width` apart (what [PixelImage.lumaPlane] returns). A plain class, not a
     * data class, because data-class equality on a ByteArray is reference identity.
     */
    class Luma(
        val pixels: ByteArray,
        val width: Int,
        val height: Int,
    )

    /**
     * Port of `MotionMask.mask(current:previous:threshold:dilatePx:)`; the
     * reasoning lives there. `null` for the first frame. An even [dilatePx]
     * throws `IllegalArgumentException` where the Swift's `precondition` traps.
     */
    fun mask(
        current: Luma,
        previous: Luma?,
        threshold: Int = SLA.motionDiffThreshold.toInt(),
        dilatePx: Int = SLA.motionDilatePx.toInt(),
    ): BooleanArray? {
        if (previous == null ||
            previous.width != current.width ||
            previous.height != current.height ||
            current.pixels.size != current.width * current.height ||
            previous.pixels.size != current.pixels.size
        ) return null

        val w = current.width
        val h = current.height
        var moved = BooleanArray(w * h)
        for (i in moved.indices) {
            val d = (current.pixels[i].toInt() and 0xFF) - (previous.pixels[i].toInt() and 0xFF)
            moved[i] = (if (d < 0) -d else d) > threshold
        }
        if (dilatePx <= 0) return moved
        require(dilatePx % 2 == 1) {
            "motion dilation must be odd; even kernels dilate one-sidedly in the reference"
        }
        val r = (dilatePx / 2) * 2
        moved = dilateRows(moved, w, h, r)
        moved = dilateCols(moved, w, h, r)
        return moved
    }

    private fun dilateRows(src: BooleanArray, w: Int, h: Int, radius: Int): BooleanArray {
        if (radius <= 0) return src
        val out = BooleanArray(src.size)
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) {
                if (!src[row + x]) continue
                val lo = maxOf(0, x - radius)
                val hi = minOf(w - 1, x + radius)
                for (k in lo..hi) out[row + k] = true
            }
        }
        return out
    }

    private fun dilateCols(src: BooleanArray, w: Int, h: Int, radius: Int): BooleanArray {
        if (radius <= 0) return src
        val out = BooleanArray(src.size)
        for (y in 0 until h) {
            for (x in 0 until w) {
                if (!src[y * w + x]) continue
                val lo = maxOf(0, y - radius)
                val hi = minOf(h - 1, y + radius)
                for (k in lo..hi) out[k * w + x] = true
            }
        }
        return out
    }
}
