// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Port of `BallDetector.swift` `DetectorSettings`; the reasoning lives there. */
data class DetectorSettings(
    var hsvLo: HSVBounds = SLA.hsvLoDefault,
    var hsvHi: HSVBounds = SLA.hsvHiDefault,
    var minRadiusPx: Double = SLA.minRadiusPxDefault,
    var maxRadiusPx: Double = SLA.maxRadiusPxDefault,
) {
    /**
     * Kotlin-only: the copy a Swift `var out = base` makes. `copy()` alone is
     * shallow, and [HSVBounds] has `var` fields, so editing `copy().hsvLo.h`
     * would edit the original's window too — which is how a session window
     * built "from" the user's settings would quietly rewrite them.
     */
    fun deepCopy(): DetectorSettings = DetectorSettings(
        hsvLo = hsvLo.copy(),
        hsvHi = hsvHi.copy(),
        minRadiusPx = minRadiusPx,
        maxRadiusPx = maxRadiusPx,
    )
}

/** Port of `BallDetector.swift` `BallMeasurement` (one ball measured at rest during setup); the reasoning lives there. */
data class BallMeasurement(
    val diameterPx: Double,
    val x: Double,
    val y: Double,
    val areaPx: Double,
    val subpixelRefined: Boolean,
)

/**
 * Port of `BallDetector.swift` `BallMeasureResult`; the reasoning lives there.
 * Case names are the Swift's, so `.found(m)` reads `BallMeasureResult.found(m)`.
 */
@Suppress("ClassName")
sealed class BallMeasureResult {
    data class found(val measurement: BallMeasurement) : BallMeasureResult()
    data object noFrameYet : BallMeasureResult()
    data object conversionFailed : BallMeasureResult()
    data class noBallNearTap(val searchRadiusPx: Double) : BallMeasureResult()
    data object notAnEdge : BallMeasureResult()
    data object mergedWithBackground : BallMeasureResult()
    data object shadowed : BallMeasureResult()
    data object truncatedByFrame : BallMeasureResult()
}

/** Port of `BallDetector.swift` `ROI` (search window in image pixels, x1/y1 exclusive); the reasoning lives there. */
data class ROI(val x0: Int, val y0: Int, val x1: Int, val y1: Int) {

    fun clamped(width: Int, height: Int): ROI = ROI(
        x0 = maxOf(0, minOf(x0, width - 1)),
        y0 = maxOf(0, minOf(y0, height - 1)),
        x1 = maxOf(1, minOf(x1, width)),
        y1 = maxOf(1, minOf(y1, height)),
    )

    companion object {
        fun around(x: Double, y: Double, radius: Double): ROI = ROI(
            x0 = (x - radius).toInt(),
            y0 = (y - radius).toInt(),
            x1 = (x + radius).toInt() + 1,
            y1 = (y + radius).toInt() + 1,
        )
    }
}

/**
 * Port of `BallDetector.swift` `BallDetector` (sla_common.detect_ball_candidates /
 * _subpixel_diameter); the reasoning lives there, including its two deliberate
 * deviations from OpenCV (pixel-count area, moment ellipse).
 *
 * Masks are ByteArrays of 0 and 255 (`255.toByte()` reads back as -1), one byte
 * a pixel, row-major over the ROI — the Swift's `[UInt8]`.
 */
object BallDetector {

    private val MASK_ON: Byte = 255.toByte()

    /** Port of `BallDetector.countInWindow` (2x-subsampled, scaled back to whole-frame pixels); the reasoning lives there. */
    fun countInWindow(image: PixelImage, settings: DetectorSettings): Int {
        val bytes = image.bytes
        var count = 0
        var y = 0
        while (y < image.height) {
            val row = y * image.bytesPerRow
            var x = 0
            while (x < image.width) {
                val p = row + x * 4
                if (HSVConvert.inRange(
                        (bytes[p].toInt() and 0xFF).toDouble(),
                        (bytes[p + 1].toInt() and 0xFF).toDouble(),
                        (bytes[p + 2].toInt() and 0xFF).toDouble(),
                        settings.hsvLo, settings.hsvHi,
                    )
                ) count += 1
                x += 2
            }
            y += 2
        }
        return count * 4
    }

    /**
     * Port of `BallDetector.maskAfterMorphology`: colour threshold, open (+close),
     * then the motion gate — in that order, always; the reasoning lives there.
     * [motion] is in FULL-FRAME coordinates. Like the Swift, [roi] must already
     * lie inside the image (callers pass a clamped one).
     */
    fun maskAfterMorphology(
        image: PixelImage,
        roi: ROI,
        lo: HSVBounds,
        hi: HSVBounds,
        motion: BooleanArray? = null,
        close: Boolean = true,
    ): ByteArray {
        val r = roi
        val w = r.x1 - r.x0
        val h = r.y1 - r.y0
        if (!(w > 0 && h > 0)) return ByteArray(0)

        val bytes = image.bytes
        val mask = ByteArray(w * h)
        for (yy in 0 until h) {
            val row = (r.y0 + yy) * image.bytesPerRow + r.x0 * 4
            val rowBase = yy * w
            for (xx in 0 until w) {
                val p = row + xx * 4
                if (HSVConvert.inRange(
                        (bytes[p].toInt() and 0xFF).toDouble(),
                        (bytes[p + 1].toInt() and 0xFF).toDouble(),
                        (bytes[p + 2].toInt() and 0xFF).toDouble(),
                        lo, hi,
                    )
                ) mask[rowBase + xx] = MASK_ON
            }
        }

        Morphology.open(mask, w, h)
        if (close) Morphology.close(mask, w, h)

        if (motion != null && motion.size == image.width * image.height) {
            for (yy in 0 until h) {
                val rowBase = yy * w
                val motionRow = (r.y0 + yy) * image.width + r.x0
                for (xx in 0 until w) {
                    if (!motion[motionRow + xx]) mask[rowBase + xx] = 0
                }
            }
        }
        return mask
    }

    /** Port of `BallDetector.GateCensus`; the reasoning lives there. */
    data class GateCensus(
        var blobs: Int = 0,
        var tooSmall: Int = 0,
        var tooLarge: Int = 0,
        var tooElongated: Int = 0,
        var diameterOutOfRange: Int = 0,
        var passed: Int = 0,
    )

    /** The Swift's `(observations:, census:)` tuple from `detectWithCensus`. */
    data class DetectionResult(val observations: List<BallObservation>, val census: GateCensus)

    /** Port of `BallDetector.detect`; the reasoning lives there. */
    fun detect(
        image: PixelImage,
        frame: Int,
        t: Double,
        settings: DetectorSettings = DetectorSettings(),
        roi: ROI? = null,
        motion: BooleanArray? = null,
    ): List<BallObservation> =
        detectWithCensus(image, frame, t, settings, roi, motion).observations

    /** Port of `BallDetector.detectWithCensus`; the reasoning lives there. */
    fun detectWithCensus(
        image: PixelImage,
        frame: Int,
        t: Double,
        settings: DetectorSettings = DetectorSettings(),
        roi: ROI? = null,
        motion: BooleanArray? = null,
    ): DetectionResult {
        val census = GateCensus()
        val r = (roi ?: ROI(0, 0, image.width, image.height))
            .clamped(image.width, image.height)
        val w = r.x1 - r.x0
        val h = r.y1 - r.y0
        if (!(w > 2 && h > 2)) return DetectionResult(emptyList(), census)

        val mask = maskAfterMorphology(image, r, settings.hsvLo, settings.hsvHi, motion)

        val blobs = ConnectedComponents.label(mask, w, h)

        val minArea = PI * settings.minRadiusPx * settings.minRadiusPx
        val maxArea = PI * settings.maxRadiusPx * settings.maxRadiusPx * 4.0

        val out = ArrayList<BallObservation>()
        census.blobs = blobs.size
        for (blob in blobs) {
            val area = blob.count.toDouble()
            if (area < minArea) { census.tooSmall += 1; continue }
            if (area > maxArea) { census.tooLarge += 1; continue }

            val cx = r.x0.toDouble() + blob.meanX
            val cy = r.y0.toDouble() + blob.meanY

            var minor = blob.minorAxis
            val major = blob.majorAxis
            if (major > 0 && minor > 1e-6 && major / minor > 6.0) {
                census.tooElongated += 1
                continue
            }
            if (minor <= 1e-6) minor = 2 * settings.minRadiusPx

            val refined = subpixelDiameter(image, cx, cy, minor / 2.0)
            if (refined != null) minor = refined

            if (!(2 * settings.minRadiusPx <= minor && minor <= 2 * settings.maxRadiusPx)) {
                census.diameterOutOfRange += 1
                continue
            }
            out.add(BallObservation(frame = frame, t = t, x = cx, y = cy,
                                    diameterPx = minor, areaPx = area))
        }
        census.passed = out.size
        return DetectionResult(out, census)
    }

    /**
     * Port of `BallDetector.subpixelDiameter` (sla_common._subpixel_diameter):
     * radial matte-fraction probe, median of the alpha = 0.5 crossings; the
     * reasoning lives there. Pinned by the `diameter_probe` block of parity.json.
     */
    fun subpixelDiameter(image: PixelImage, cx: Double, cy: Double, r0: Double): Double? {
        val step = SLA.diameterProfileStepPx
        val reach = r0 * SLA.diameterBgOuter + SLA.diameterBgPadPx + 2.0
        val n = maxOf(10, (reach / step).toInt())
        val count = n + 1
        val dirs = SLA.diameterProbeDirections

        val rs = DoubleArray(count)
        for (i in 0 until count) rs[i] = i.toDouble() * step

        val pb = DoubleArray(dirs * count)
        val pg = DoubleArray(dirs * count)
        val pr = DoubleArray(dirs * count)
        for (d in 0 until dirs) {
            val a = 2.0 * PI * d.toDouble() / dirs.toDouble()
            val ca = cos(a)
            val sa = sin(a)
            for (i in 0 until count) {
                val p = image.sampleBilinear(cx + rs[i] * ca, cy + rs[i] * sa)
                pb[d * count + i] = p.b
                pg[d * count + i] = p.g
                pr[d * count + i] = p.r
            }
        }

        val coreLimit = swiftMax(0.4 * r0, step)
        val bgLo = SLA.diameterBgInner * r0
        val bgHi = SLA.diameterBgOuter * r0 + SLA.diameterBgPadPx
        var coreB = 0.0; var coreG = 0.0; var coreR = 0.0; var coreN = 0
        var bgB = 0.0; var bgG = 0.0; var bgR = 0.0; var bgN = 0
        for (d in 0 until dirs) {
            for (i in 0 until count) {
                val k = d * count + i
                if (rs[i] <= coreLimit) {
                    coreB += pb[k]; coreG += pg[k]; coreR += pr[k]; coreN += 1
                }
                if (rs[i] >= bgLo && rs[i] <= bgHi) {
                    bgB += pb[k]; bgG += pg[k]; bgR += pr[k]; bgN += 1
                }
            }
        }
        if (!(coreN > 0 && bgN > 0)) return null
        coreB /= coreN.toDouble(); coreG /= coreN.toDouble(); coreR /= coreN.toDouble()
        bgB /= bgN.toDouble(); bgG /= bgN.toDouble(); bgR /= bgN.toDouble()

        val dB = coreB - bgB
        val dG = coreG - bgG
        val dR = coreR - bgR
        val denom = dB * dB + dG * dG + dR * dR
        if (!(denom >= 900.0)) return null

        fun alpha(base: Int, i: Int): Double {
            val k = base + i
            return ((pb[k] - bgB) * dB + (pg[k] - bgG) * dG + (pr[k] - bgR) * dR) / denom
        }

        val edges = ArrayList<Double>(dirs)
        for (d in 0 until dirs) {
            val base = d * count
            var i = 1
            while (i < count - 1) {
                if (alpha(base, i) < 0.5 && alpha(base, i + 1) < 0.5) {
                    val a0 = alpha(base, i - 1)
                    val a1 = alpha(base, i)
                    val frac = if (a0 > a1) (a0 - 0.5) / (a0 - a1) else 0.5
                    edges.add(rs[i - 1] + frac * step)
                    break
                }
                i += 1
            }
        }

        if (edges.size < dirs / 2) return null
        edges.sort()
        return 2.0 * edges[edges.size / 2]
    }
}

/**
 * Port of `BallDetector.swift` `Morphology` (3x3 cross = OpenCV's 3x3
 * MORPH_ELLIPSE); the reasoning lives there. Edits the mask in place, as the
 * Swift's `inout` does.
 */
object Morphology {

    private val ON: Byte = 255.toByte()

    fun erode(m: ByteArray, width: Int, height: Int) {
        val w = width
        val h = height
        val src = m.copyOf()
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * w + x
                if (src[i].toInt() == 0) continue
                var keep = true
                if (x == 0 || src[i - 1].toInt() == 0) keep = false
                if (keep && (x == w - 1 || src[i + 1].toInt() == 0)) keep = false
                if (keep && (y == 0 || src[i - w].toInt() == 0)) keep = false
                if (keep && (y == h - 1 || src[i + w].toInt() == 0)) keep = false
                if (!keep) m[i] = 0
            }
        }
    }

    fun dilate(m: ByteArray, width: Int, height: Int) {
        val w = width
        val h = height
        val src = m.copyOf()
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * w + x
                if (src[i].toInt() != 0) continue
                var on = false
                if (x > 0 && src[i - 1].toInt() != 0) on = true
                if (!on && x < w - 1 && src[i + 1].toInt() != 0) on = true
                if (!on && y > 0 && src[i - w].toInt() != 0) on = true
                if (!on && y < h - 1 && src[i + w].toInt() != 0) on = true
                if (on) m[i] = ON
            }
        }
    }

    fun open(m: ByteArray, width: Int, height: Int) {
        erode(m, width, height)
        dilate(m, width, height)
    }

    fun close(m: ByteArray, width: Int, height: Int) {
        dilate(m, width, height)
        erode(m, width, height)
    }
}

/** Port of `BallDetector.swift` `ConnectedComponents` (8-connected, union-find); the reasoning lives there. */
object ConnectedComponents {

    /** Port of `ConnectedComponents.Blob`; the reasoning lives there. */
    data class Blob(
        val count: Int,
        val meanX: Double,
        val meanY: Double,
        val majorAxis: Double,
        val minorAxis: Double,
        val minorAxisDeg: Double,
        val minX: Int,
        val maxX: Int,
        val minY: Int,
        val maxY: Int,
        val root: Int = 0,
    ) {
        val boxWidth: Double get() = (maxX - minX + 1).toDouble()
        val boxHeight: Double get() = (maxY - minY + 1).toDouble()
        val extent: Double
            get() {
                val box = boxWidth * boxHeight
                return if (box > 0) count.toDouble() / box else 0.0
            }
        val boxAspect: Double
            get() = if (boxHeight > 0) boxWidth / boxHeight else Double.POSITIVE_INFINITY
    }

    /** The Swift's `(blobs:, labels:)` tuple from `labelDetailed`; labels are per-pixel roots, 0 = background. */
    data class Labelled(val blobs: List<Blob>, val labels: IntArray)

    fun label(mask: ByteArray, width: Int, height: Int): List<Blob> =
        labelDetailed(mask, width, height).blobs

    /**
     * Port of `ConnectedComponents.labelDetailed`; the reasoning lives there.
     *
     * Per-root statistics live in arrays indexed by label where the Swift uses a
     * dictionary: the same per-pixel raster-order sums (so the same bits), and a
     * deterministic order going into the sort. Blobs whose (meanY, meanX) tie
     * exactly come out in ascending-root order here; the Swift leaves that order
     * to dictionary iteration, so no caller can depend on it.
     */
    fun labelDetailed(mask: ByteArray, width: Int, height: Int): Labelled {
        val w = width
        val h = height
        val labels = IntArray(w * h)
        var parent = IntArray(64)
        var parentCount = 1                     // index 0 unused (0 == background)

        fun find(x: Int): Int {
            var root = x
            while (parent[root] != root) root = parent[root]
            var cur = x
            while (parent[cur] != root) {       // path compression
                val next = parent[cur]
                parent[cur] = root
                cur = next
            }
            return root
        }

        fun union(a: Int, b: Int) {
            val ra = find(a)
            val rb = find(b)
            if (ra == rb) return
            if (ra < rb) parent[rb] = ra else parent[ra] = rb
        }

        val neighbours = IntArray(4)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * w + x
                if (mask[i].toInt() == 0) continue
                var nCount = 0
                if (x > 0 && labels[i - 1] != 0) neighbours[nCount++] = labels[i - 1]
                if (y > 0) {
                    if (labels[i - w] != 0) neighbours[nCount++] = labels[i - w]
                    if (x > 0 && labels[i - w - 1] != 0) neighbours[nCount++] = labels[i - w - 1]
                    if (x < w - 1 && labels[i - w + 1] != 0) neighbours[nCount++] = labels[i - w + 1]
                }
                if (nCount == 0) {
                    val newLabel = parentCount
                    if (parentCount == parent.size) parent = parent.copyOf(parent.size * 2)
                    parent[parentCount] = newLabel
                    parentCount += 1
                    labels[i] = newLabel
                } else {
                    var best = neighbours[0]
                    for (k in 1 until nCount) if (neighbours[k] < best) best = neighbours[k]
                    labels[i] = best
                    for (k in 0 until nCount) if (neighbours[k] != best) union(best, neighbours[k])
                }
            }
        }

        // Second pass: accumulate per-root statistics.
        val n = IntArray(parentCount)
        val sx = DoubleArray(parentCount); val sy = DoubleArray(parentCount)
        val sxx = DoubleArray(parentCount); val syy = DoubleArray(parentCount)
        val sxy = DoubleArray(parentCount)
        val minX = IntArray(parentCount) { Int.MAX_VALUE }
        val maxX = IntArray(parentCount) { Int.MIN_VALUE }
        val minY = IntArray(parentCount) { Int.MAX_VALUE }
        val maxY = IntArray(parentCount) { Int.MIN_VALUE }
        for (y in 0 until h) {
            for (x in 0 until w) {
                val l = labels[y * w + x]
                if (l == 0) continue
                val root = find(l)
                val dx = x.toDouble()
                val dy = y.toDouble()
                n[root] += 1
                sx[root] += dx; sy[root] += dy
                sxx[root] += dx * dx; syy[root] += dy * dy; sxy[root] += dx * dy
                if (x < minX[root]) minX[root] = x
                if (x > maxX[root]) maxX[root] = x
                if (y < minY[root]) minY[root] = y
                if (y > maxY[root]) maxY[root] = y
            }
        }

        val blobs = ArrayList<Blob>()
        for (root in 1 until parentCount) {
            if (n[root] <= 0) continue
            val cnt = n[root].toDouble()
            val mx = sx[root] / cnt
            val my = sy[root] / cnt
            val mu20 = sxx[root] / cnt - mx * mx
            val mu02 = syy[root] / cnt - my * my
            val mu11 = sxy[root] / cnt - mx * my
            val common = sqrt((mu20 - mu02) * (mu20 - mu02) + 4 * mu11 * mu11)
            val l1 = swiftMax(0.0, (mu20 + mu02 + common) / 2)
            val l2 = swiftMax(0.0, (mu20 + mu02 - common) / 2)
            val majorAxis = 4 * sqrt(l1)
            val minorAxis = 4 * sqrt(l2)
            val thetaDeg = 0.5 * atan2(2 * mu11, mu20 - mu02) * 180 / PI
            blobs.add(Blob(count = n[root], meanX = mx, meanY = my,
                           majorAxis = majorAxis, minorAxis = minorAxis,
                           minorAxisDeg = thetaDeg + 90,
                           minX = minX[root], maxX = maxX[root],
                           minY = minY[root], maxY = maxY[root],
                           root = root))
        }
        val sorted = blobs.sortedWith { a, b ->
            if (a.meanY != b.meanY) a.meanY.compareTo(b.meanY) else a.meanX.compareTo(b.meanX)
        }

        val resolved = IntArray(w * h)
        for (i in 0 until w * h) {
            if (labels[i] != 0) resolved[i] = find(labels[i])
        }
        return Labelled(sorted, resolved)
    }
}
