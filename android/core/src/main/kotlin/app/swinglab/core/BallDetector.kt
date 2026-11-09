// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
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
 * _subpixel_diameter); the reasoning lives there.
 *
 * Pinned to the PYTHON, not to the Swift, by the `detect_candidates` fixtures,
 * and different from the Swift wherever the Swift differed from the Python:
 *
 *  - HSV is OpenCV's rounded 8-bit conversion ([HSVConvert]).
 *  - Erosion never eats a pixel for touching the frame edge ([Morphology]).
 *  - Blobs are `findContours(RETR_EXTERNAL)` contours, not connected
 *    components: a blob inside another's hole is not a candidate, and the
 *    candidates come in OpenCV's order (last found first).
 *  - The area is the contour's polygon area, not a pixel count.
 *  - The centre — where the diameter probe stands — is `fitEllipse`'s centre
 *    (`minEnclosingCircle`'s below five contour points), not the pixel
 *    centroid. On the notched fixture ball the centroid read 18.93 px.
 *  - Without a probe measurement the diameter is the fitted minor axis, with no
 *    Swift-only floor under it.
 *  - The probe samples as `cv2.remap` and numpy do, in float32 ([subpixelDiameter]).
 *
 * The Swift's two "deliberate deviations" (pixel-count area, moment ellipse)
 * were described as touching no reported number; both moved the centre, and
 * the centre moves the diameter, which is the scale.
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
                        bytes[p].toInt() and 0xFF,
                        bytes[p + 1].toInt() and 0xFF,
                        bytes[p + 2].toInt() and 0xFF,
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
     *
     * Kotlin differs at the ROI's edge. The reference only ever masks whole
     * frames, and a pixel's value after open+close depends on the colour of
     * everything within four pixels of it, so the window is masked with a
     * four-pixel margin (two without the close) and then cropped: inside the ROI
     * this is exactly the full-frame mask, which the Swift's, eroding at the ROI
     * edge as if it were the frame's, was not.
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

        val margin = if (close) 4 else 2
        val ex0 = maxOf(0, r.x0 - margin)
        val ey0 = maxOf(0, r.y0 - margin)
        val ex1 = minOf(image.width, r.x1 + margin)
        val ey1 = minOf(image.height, r.y1 + margin)
        val ew = ex1 - ex0
        val eh = ey1 - ey0

        val bytes = image.bytes
        val wide = ByteArray(ew * eh)
        for (yy in 0 until eh) {
            val row = (ey0 + yy) * image.bytesPerRow + ex0 * 4
            val rowBase = yy * ew
            for (xx in 0 until ew) {
                val p = row + xx * 4
                if (HSVConvert.inRange(
                        bytes[p].toInt() and 0xFF,
                        bytes[p + 1].toInt() and 0xFF,
                        bytes[p + 2].toInt() and 0xFF,
                        lo, hi,
                    )
                ) wide[rowBase + xx] = MASK_ON
            }
        }

        Morphology.open(wide, ew, eh)
        if (close) Morphology.close(wide, ew, eh)

        val mask = ByteArray(w * h)
        for (yy in 0 until h) {
            System.arraycopy(wide, (r.y0 - ey0 + yy) * ew + (r.x0 - ex0), mask, yy * w, w)
        }

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

    /**
     * Port of `BallDetector.detectWithCensus`: `detect_ball_candidates`, gate for
     * gate, with the tally of what each gate threw away. `census.blobs` counts
     * external contours. The guard is `w > 0`, not the Swift's `w > 2`: the
     * reference has no minimum frame size.
     */
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
        if (!(w > 0 && h > 0)) return DetectionResult(emptyList(), census)

        val mask = maskAfterMorphology(image, r, settings.hsvLo, settings.hsvHi, motion)

        // Full-frame coordinates from the start: fitEllipse works in float32,
        // so where a contour sits changes the bits of its answer.
        val contours = OpenCV.findContours(mask, w, h, r.x0, r.y0)

        val minArea = PI * settings.minRadiusPx * settings.minRadiusPx
        // Elongation allowance: up to ~4x blur smear along the motion axis.
        val maxArea = PI * settings.maxRadiusPx * settings.maxRadiusPx * 4.0

        val out = ArrayList<BallObservation>()
        census.blobs = contours.size
        for (c in contours) {
            val area = OpenCV.contourArea(c)
            if (area < minArea) { census.tooSmall += 1; continue }
            if (area > maxArea) { census.tooLarge += 1; continue }

            val cx: Double
            val cy: Double
            var minor: Double
            if (c.size >= 5) {
                val e = OpenCV.fitEllipse(c)
                cx = e.cx.toDouble()
                cy = e.cy.toDouble()
                minor = swiftMin(e.width.toDouble(), e.height.toDouble())
                val major = swiftMax(e.width.toDouble(), e.height.toDouble())
                if (major > 0 && major / swiftMax(minor, 1e-6) > 6.0) {
                    census.tooElongated += 1
                    continue
                }
            } else {
                val circle = OpenCV.minEnclosingCircle(c)
                cx = circle.cx.toDouble()
                cy = circle.cy.toDouble()
                minor = 2.0 * circle.radius.toDouble()
            }

            // The fitted shape only places the probe; the diameter comes from
            // the pixels. See `subpixelDiameter` for why the mask cannot be
            // trusted to say how big the ball is.
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
     * reasoning lives there. Pinned by the `diameter_probe` and
     * `detect_candidates` blocks of parity.json.
     *
     * Kotlin differs from the Swift, which worked in Double, by doing what the
     * reference's libraries do, in float32, so the two agree to the bit rather
     * than to a hundredth of a pixel: the sample positions are float32 offsets
     * from the crop `_subpixel_diameter` takes (numpy arithmetic), the bilinear
     * is OpenCV 5's float remap kernel (three fused multiply-adds), the window
     * means are numpy's sequential float32 sums, the window limits are compared
     * as float32 (numpy casts the Python float), the contrast is `np.dot`'s
     * (float products summed in double), and alpha is a float32 matrix-vector
     * product. Of those only the last is not reproduced exactly — the BLAS
     * associates the farthest few samples of each ray differently, an ulp in the
     * background annulus, far outside any edge — and no fixture case moves.
     */
    fun subpixelDiameter(image: PixelImage, cx: Double, cy: Double, r0: Double): Double? {
        val step = SLA.diameterProfileStepPx
        val reach = r0 * SLA.diameterBgOuter + SLA.diameterBgPadPx + 2.0
        val n = maxOf(10, (reach / step).toInt())
        val count = n + 1
        val dirs = SLA.diameterProbeDirections

        // The crop the reference samples from; the remap replicates ITS edge.
        val pad = ceil(reach).toInt() + 2
        val x0 = maxOf(0, floor(cx).toInt() - pad)
        val y0 = maxOf(0, floor(cy).toInt() - pad)
        val x1 = minOf(image.width, ceil(cx).toInt() + pad + 1)
        val y1 = minOf(image.height, ceil(cy).toInt() + pad + 1)
        if (x1 <= x0 || y1 <= y0) return null

        val rs = FloatArray(count) { (it * step).toFloat() }
        val pb = FloatArray(dirs * count)
        val pg = FloatArray(dirs * count)
        val pr = FloatArray(dirs * count)
        val ox = (cx - x0).toFloat()
        val oy = (cy - y0).toFloat()
        val bytes = image.bytes
        fun at(wx: Int, wy: Int): Int =
            (y0 + wy.coerceIn(0, y1 - y0 - 1)) * image.bytesPerRow + (x0 + wx.coerceIn(0, x1 - x0 - 1)) * 4
        fun ch(i: Int): Float = (bytes[i].toInt() and 0xFF).toFloat()
        for (d in 0 until dirs) {
            val a = d.toDouble() * (2.0 * PI / dirs)        // np.linspace(0, 2 pi, dirs, endpoint=False)
            val ca = cos(a).toFloat()
            val sa = sin(a).toFloat()
            for (i in 0 until count) {
                val sx = ox + rs[i] * ca
                val sy = oy + rs[i] * sa
                val ix = floor(sx).toInt()
                val iy = floor(sy).toInt()
                val fx = sx - ix.toFloat()
                val fy = sy - iy.toFloat()
                val p00 = at(ix, iy)
                val p01 = at(ix + 1, iy)
                val p10 = at(ix, iy + 1)
                val p11 = at(ix + 1, iy + 1)
                val k = d * count + i
                pb[k] = lerp2(ch(p00), ch(p01), ch(p10), ch(p11), fx, fy)
                pg[k] = lerp2(ch(p00 + 1), ch(p01 + 1), ch(p10 + 1), ch(p11 + 1), fx, fy)
                pr[k] = lerp2(ch(p00 + 2), ch(p01 + 2), ch(p10 + 2), ch(p11 + 2), fx, fy)
            }
        }

        val coreLimit = swiftMax(0.4 * r0, step).toFloat()
        val bgLo = (SLA.diameterBgInner * r0).toFloat()
        val bgHi = (SLA.diameterBgOuter * r0 + SLA.diameterBgPadPx).toFloat()
        var coreB = 0f; var coreG = 0f; var coreR = 0f; var coreN = 0
        var bgB = 0f; var bgG = 0f; var bgR = 0f; var bgN = 0
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
        coreB /= coreN.toFloat(); coreG /= coreN.toFloat(); coreR /= coreN.toFloat()
        bgB /= bgN.toFloat(); bgG /= bgN.toFloat(); bgR /= bgN.toFloat()

        val dB = coreB - bgB
        val dG = coreG - bgG
        val dR = coreR - bgR
        val denom = (((dB * dB).toDouble() + (dG * dG).toDouble()) + (dR * dR).toDouble()).toFloat()
        if (!(denom.toDouble() >= 900.0)) return null

        fun alpha(k: Int): Float =
            Math.fma(pr[k] - bgR, dR, Math.fma(pg[k] - bgG, dG, (pb[k] - bgB) * dB)) / denom

        val edges = ArrayList<Double>(dirs)
        for (d in 0 until dirs) {
            val base = d * count
            var i = 1
            while (i < count - 1) {
                // Two consecutive samples under half: past the edge, not noise.
                if (alpha(base + i) < 0.5f && alpha(base + i + 1) < 0.5f) {
                    val a0 = alpha(base + i - 1).toDouble()
                    val a1 = alpha(base + i).toDouble()
                    val frac = if (a0 > a1) (a0 - 0.5) / (a0 - a1) else 0.5
                    edges.add(rs[i - 1].toDouble() + frac * step)
                    break
                }
                i += 1
            }
        }

        if (edges.size < dirs / 2) return null
        edges.sort()
        return 2.0 * edges[edges.size / 2]
    }

    /** OpenCV 5's scalar bilinear for float images: `v0 = p00 + fx (p01 - p00)`, and so on, each a fused multiply-add. */
    private fun lerp2(p00: Float, p01: Float, p10: Float, p11: Float, fx: Float, fy: Float): Float {
        val v0 = Math.fma(fx, p01 - p00, p00)
        val v1 = Math.fma(fx, p11 - p10, p10)
        return Math.fma(fy, v1 - v0, v0)
    }
}

/**
 * Port of `BallDetector.swift` `Morphology` (3x3 cross = OpenCV's 3x3
 * MORPH_ELLIPSE); the reasoning lives there. Edits the mask in place, as the
 * Swift's `inout` does.
 *
 * Kotlin differs at the mask's edge, as OpenCV does. `morphologyEx`'s default
 * border is "the most neutral value": the maximum for erode, zero for dilate.
 * So outside the mask never erodes anything, where the Swift treated it as
 * background and ate every blob pixel on the frame's edge — a ball half out of
 * shot lost a column the reference keeps, and its fitted centre moved with it.
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
                if (x > 0 && src[i - 1].toInt() == 0) keep = false
                if (keep && x < w - 1 && src[i + 1].toInt() == 0) keep = false
                if (keep && y > 0 && src[i - w].toInt() == 0) keep = false
                if (keep && y < h - 1 && src[i + w].toInt() == 0) keep = false
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

/**
 * Port of `BallDetector.swift` `ConnectedComponents` (8-connected, union-find);
 * the reasoning lives there. The ball detector no longer uses it — the
 * reference's blobs are `findContours` contours, see [OpenCV.findContours] —
 * but the setup measurement does, for the per-pixel labels contours lack.
 */
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
