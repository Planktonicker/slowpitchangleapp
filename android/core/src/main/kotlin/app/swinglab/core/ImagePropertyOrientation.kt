// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Stand-in for ImageIO's `CGImagePropertyOrientation`, alongside the CoreGraphics
 * stand-ins in Geometry.kt. Raw values are the EXIF/TIFF orientation tags the
 * Swift type carries (1 is `.up`), which is what `SwingDTO.visionOrientationRaw`
 * stores.
 */
enum class ImagePropertyOrientation(val raw: Int) {
    up(1),
    upMirrored(2),
    down(3),
    downMirrored(4),
    leftMirrored(5),
    right(6),
    rightMirrored(7),
    left(8);

    companion object {
        fun fromRaw(raw: Int): ImagePropertyOrientation? = entries.firstOrNull { it.raw == raw }
    }
}
