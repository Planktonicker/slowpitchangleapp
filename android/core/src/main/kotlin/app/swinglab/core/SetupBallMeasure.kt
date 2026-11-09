// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Port of `SetupBallMeasure.swift` `SetupBallMeasure` (one stationary, tapped
 * ball measured during setup; NOT the parity-pinned tracking detector); the
 * reasoning lives there.
 */
object SetupBallMeasure {

    const val minMeasurableDiameterPx = 14.0
    const val maxDiameterFractionOfWidth = 0.45
    const val extentLo = 0.62
    const val extentHi = 0.90
    const val rayCount = 16
    const val raysRequired = 13
    const val rayBand = 0.15
    const val rayReachFactor = 1.6
    const val stabilityDiameterTol = 0.10
    const val stabilityCentroidTol = 0.25
    const val subpixelVsMaskTol = 0.25
    const val maxElongation = 1.5

    /** Port of `SetupBallMeasure.Outcome`; the reasoning lives there. Case names are the Swift's. */
    @Suppress("ClassName")
    sealed class Outcome {
        data class found(val measurement: BallMeasurement) : Outcome()
        data object notAnEdge : Outcome()
        data object mergedWithBackground : Outcome()
        data object shadowed : Outcome()
        data object truncatedByFrame : Outcome()
        data object needsWiderSearch : Outcome()
        data object nothingThere : Outcome()
    }

    /** The Swift's `(outcome:, report:, learned:)` tuple from `measure`. */
    data class MeasureResult(val outcome: Outcome, val report: String, val learned: DetectorSettings?)

    /**
     * Port of `SetupBallMeasure.sessionWindow`; the reasoning lives there.
     * Returns a new value and never edits [base] — see [DetectorSettings.deepCopy].
     */
    fun sessionWindow(tap: HSVConvert.HSV, measuredDiameterPx: Double, base: DetectorSettings): DetectorSettings {
        val c = tap
        val d = measuredDiameterPx
        val out = base.deepCopy()
        out.hsvLo.h = swiftMax(0.0, c.h - 18)
        out.hsvHi.h = swiftMin(179.0, c.h + 18)
        out.hsvLo.s = swiftMax(base.hsvLo.s, c.s * 0.55)
        out.hsvLo.v = swiftMax(base.hsvLo.v, c.v * 0.45)
        if (d > 1) {
            val r = d / 2
            out.minRadiusPx = swiftMax(base.minRadiusPx, r * 0.45)
            out.maxRadiusPx = swiftMin(base.maxRadiusPx, r * 2.5)
            if (out.maxRadiusPx <= out.minRadiusPx) {
                out.minRadiusPx = base.minRadiusPx
                out.maxRadiusPx = base.maxRadiusPx
            }
        }
        return out
    }

    /** Port of `SetupBallMeasure.measure`; the reasoning lives there. */
    fun measure(
        image: PixelImage,
        tapX: Double,
        tapY: Double,
        searchRadiusPx: Double,
        settings: DetectorSettings,
        fovDeg: Double,
    ): MeasureResult {
        val (minDiameter, maxDiameter) = diameterBand(image.width, fovDeg, searchRadiusPx)
        if (!(maxDiameter > minDiameter)) {
            return MeasureResult(Outcome.needsWiderSearch, "window too small for any ball", null)
        }

        val c = tapColour(image, tapX, tapY)
        val variants = listOf(
            Variant("seed24c", seededWindow(c, 24.0, settings), true),
            Variant("seed24", seededWindow(c, 24.0, settings), false),
            Variant("seed12c", seededWindow(c, 12.0, settings), true),
            Variant("dflt-c", settings, true),
            Variant("dflt", settings, false),
        )

        var bestFound: BestFound? = null
        var lastFail: Attempt? = null

        for (v in variants) {
            val attempt = bestCandidate(image, tapX, tapY, searchRadiusPx, v.settings, v.close,
                                        minDiameter, maxDiameter)
            when (attempt) {
                is Attempt.found -> {
                    if (bestFound == null || attempt.shape.score < bestFound.shape.score) {
                        bestFound = BestFound(attempt.measurement, attempt.shape, v.settings, v.name)
                    }
                }
                is Attempt.failed -> lastFail = attempt
            }
        }

        val tapDesc = "tap hsv ${formatFixed(c.h, 0)}/${formatFixed(c.s, 0)}/${formatFixed(c.v, 0)}"

        val found = bestFound
        if (found == null) {
            val trace = lastFail?.trace ?: "no candidate"
            return MeasureResult(lastFail?.outcomeOnly ?: Outcome.nothingThere,
                                 "r${searchRadiusPx.toInt()} · $tapDesc · $trace", null)
        }
        val primary = found.measurement
        val shape = found.shape
        val winning = found.settings
        val winName = found.name

        val learned = sessionWindow(c, primary.diameterPx, settings)

        val base = "$winName · d ${formatFixed(primary.diameterPx, 0)}px" +
            " · fill ${formatFixed(shape.extent, 2)} · rays ${shape.goodRays}/16" +
            " · edge ${if (primary.subpixelRefined) "yes" else "no"}"

        val b = bestCandidate(image, tapX, tapY, searchRadiusPx, tightened(winning), true,
                              minDiameter, maxDiameter)

        val unmistakable = shape.goodRays >= rayCount - 1 &&
            shape.extent >= 0.70 && shape.extent <= 0.86

        if (b !is Attempt.found) {
            return if (unmistakable) {
                MeasureResult(Outcome.found(primary), "$base · tight:none, allowed (round)", learned)
            } else {
                MeasureResult(Outcome.notAnEdge, "$base · vanished under tighter colour", null)
            }
        }
        val check = b.measurement

        val dDiff = abs(primary.diameterPx - check.diameterPx) / swiftMax(1e-6, primary.diameterPx)
        val drift = sqrt((primary.x - check.x) * (primary.x - check.x) +
                         (primary.y - check.y) * (primary.y - check.y))
        val stable = dDiff <= stabilityDiameterTol &&
            drift <= stabilityCentroidTol * primary.diameterPx
        if (!(stable || unmistakable)) {
            return MeasureResult(Outcome.notAnEdge,
                                 "$base · size moved ${formatFixed(dDiff * 100, 0)}% under tighter colour", null)
        }
        return MeasureResult(Outcome.found(primary), "$base · stable ${formatFixed(dDiff * 100, 0)}%", learned)
    }

    private data class Variant(val name: String, val settings: DetectorSettings, val close: Boolean)

    private data class BestFound(
        val measurement: BallMeasurement,
        val shape: Shape,
        val settings: DetectorSettings,
        val name: String,
    )

    // Size band

    @Suppress("UNUSED_PARAMETER")   // as in the Swift: distance sanity is the wizard's job
    private fun diameterBand(imageWidth: Int, fovDeg: Double, searchRadiusPx: Double): Pair<Double, Double> {
        val roomCap = 2 * searchRadiusPx / rayReachFactor
        val hi = swiftMin(maxDiameterFractionOfWidth * imageWidth.toDouble(), roomCap)
        return Pair(minMeasurableDiameterPx, hi)
    }

    // Colour window

    /** Port of `SetupBallMeasure.tapColour` (per-channel median over a patch); the reasoning lives there. */
    fun tapColour(image: PixelImage, x: Double, y: Double, radius: Int = 6): HSVConvert.HSV {
        val hs = ArrayList<Double>()
        val ss = ArrayList<Double>()
        val vs = ArrayList<Double>()
        val cx = x.rounded().toInt()
        val cy = y.rounded().toInt()
        for (dy in -radius..radius) {
            for (dx in -radius..radius) {
                val p = image.pixel(cx + dx, cy + dy)
                val hsv = HSVConvert.fromBGR(p.b, p.g, p.r)
                hs.add(hsv.h); ss.add(hsv.s); vs.add(hsv.v)
            }
        }
        fun median(a: List<Double>): Double {
            val sorted = a.sorted()
            return if (sorted.isEmpty()) 0.0 else sorted[sorted.size / 2]
        }
        return HSVConvert.HSV(median(hs), median(ss), median(vs))
    }

    private fun seededWindow(c: HSVConvert.HSV, hueSpan: Double, base: DetectorSettings): DetectorSettings {
        val out = base.deepCopy()
        out.hsvLo.h = swiftMax(0.0, c.h - hueSpan)
        out.hsvHi.h = swiftMin(179.0, c.h + hueSpan)
        out.hsvLo.s = swiftMax(30.0, c.s * 0.45)
        out.hsvHi.s = 255.0
        out.hsvLo.v = swiftMax(45.0, c.v * 0.40)
        out.hsvHi.v = 255.0
        return out
    }

    private fun tightened(s: DetectorSettings): DetectorSettings {
        val t = s.deepCopy()
        val span = swiftMax(4.0, (s.hsvHi.h - s.hsvLo.h) * 0.35)
        val mid = (s.hsvHi.h + s.hsvLo.h) / 2
        t.hsvLo.h = mid - span / 2
        t.hsvHi.h = mid + span / 2
        t.hsvLo.s = swiftMin(255.0, s.hsvLo.s + 25)
        return t
    }

    // Candidate search

    /** Port of `SetupBallMeasure.Shape`; the reasoning lives there. */
    data class Shape(val extent: Double, val goodRays: Int, val score: Double)

    @Suppress("ClassName")
    private sealed class Attempt {
        data class found(val measurement: BallMeasurement, val shape: Shape) : Attempt() {
            override val trace: String get() = "found"
        }
        data class failed(val outcome: Outcome, override val trace: String) : Attempt()

        val outcomeOnly: Outcome
            get() = when (this) {
                is found -> Outcome.nothingThere
                is failed -> outcome
            }

        abstract val trace: String
    }

    private fun bestCandidate(
        image: PixelImage,
        tapX: Double,
        tapY: Double,
        searchRadiusPx: Double,
        settings: DetectorSettings,
        close: Boolean,
        minDiameter: Double,
        maxDiameter: Double,
    ): Attempt {
        val roi = ROI.around(tapX, tapY, searchRadiusPx).clamped(image.width, image.height)
        val w = roi.x1 - roi.x0
        val h = roi.y1 - roi.y0
        if (!(w > 8 && h > 8)) return Attempt.failed(Outcome.nothingThere, "window clipped away")

        val mask = BallDetector.maskAfterMorphology(image, roi, settings.hsvLo, settings.hsvHi,
                                                    motion = null, close = close)

        val (blobs, labels) = ConnectedComponents.labelDetailed(mask, w, h)

        val tapCol = tapX.rounded().toInt() - roi.x0
        val tapRow = tapY.rounded().toInt() - roi.y0
        var tappedRoot = 0
        if (tapCol >= 0 && tapCol < w && tapRow >= 0 && tapRow < h) {
            tappedRoot = labels[tapRow * w + tapCol]
        }

        var best: BallMeasurement? = null
        var bestShape = Shape(extent = 0.0, goodRays = 0, score = Double.POSITIVE_INFINITY)
        var bestScore = Double.POSITIVE_INFINITY
        var diagnosis: Outcome = Outcome.nothingThere
        var considered = 0
        val rejects = HashMap<String, Int>()
        fun reject(why: String) { rejects[why] = (rejects[why] ?: 0) + 1 }

        for (blob in blobs) {
            val isTapped = tappedRoot != 0 && blob.root == tappedRoot
            val dEq = 2 * sqrt(blob.count.toDouble() / PI)
            val dx = (roi.x0.toDouble() + blob.meanX) - tapX
            val dy = (roi.y0.toDouble() + blob.meanY) - tapY
            val centroidNear = sqrt(dx * dx + dy * dy) <= 0.6 * swiftMax(dEq / 2, 8.0)
            if (!(isTapped || centroidNear)) continue
            considered += 1

            val touchesImageEdge =
                (roi.x0 + blob.minX) <= 0 || (roi.x0 + blob.maxX) >= image.width - 1 ||
                    (roi.y0 + blob.minY) <= 0 || (roi.y0 + blob.maxY) >= image.height - 1
            if (touchesImageEdge) { diagnosis = Outcome.truncatedByFrame; reject("frame edge"); continue }

            val touchesROIEdge = blob.minX <= 0 || blob.maxX >= w - 1 ||
                blob.minY <= 0 || blob.maxY >= h - 1
            if (touchesROIEdge) {
                diagnosis = if (isTapped) Outcome.mergedWithBackground else Outcome.needsWiderSearch
                reject("runs off window")
                continue
            }

            val major = blob.majorAxis
            val minor = blob.minorAxis
            if (minor > 1e-6 && major / minor > maxElongation) {
                diagnosis = Outcome.mergedWithBackground
                reject("elongated ${formatFixed(major / minor, 1)}")
                continue
            }

            val filledCount = filledArea(labels, w, h, blob)
            val extent = filledCount / swiftMax(1.0, blob.boxWidth * blob.boxHeight)
            if (!(extent >= extentLo && extent <= extentHi)) {
                reject("fill ${formatFixed(extent, 2)}")
                continue
            }

            val rays = rayProfile(labels, w, h, blob)
            if (!(rays.good >= raysRequired)) {
                if (rays.good >= 8 && rays.failuresContiguous) diagnosis = Outcome.shadowed
                reject("rays ${rays.good}/16")
                continue
            }

            val cx = roi.x0.toDouble() + blob.meanX
            val cy = roi.y0.toDouble() + blob.meanY

            val diameter: Double
            var refinedOK = true
            val refined = BallDetector.subpixelDiameter(image, cx, cy, swiftMax(2.0, rays.median))
            if (refined != null) {
                if (!(abs(refined - dEq) / swiftMax(1e-6, refined) <= subpixelVsMaskTol)) {
                    diagnosis = Outcome.notAnEdge
                    reject("edge/mask disagree")
                    continue
                }
                diameter = refined
            } else if (rays.good >= rayCount - 1 && extent >= 0.70 && extent <= 0.86) {
                diameter = 2 * rays.median
                refinedOK = false
            } else {
                diagnosis = Outcome.notAnEdge
                reject("no edge to measure")
                continue
            }

            if (!(diameter >= minDiameter && diameter <= maxDiameter)) {
                diagnosis = if (diameter > maxDiameter) Outcome.needsWiderSearch else Outcome.nothingThere
                reject("size ${formatFixed(diameter, 0)}px outside " +
                       "${formatFixed(minDiameter, 0)}-${formatFixed(maxDiameter, 0)}")
                continue
            }

            val score = abs(extent - 0.785) +
                0.5 * (1 - rays.good.toDouble() / rayCount.toDouble()) +
                (if (refinedOK) 0.0 else 0.25)
            if (score < bestScore) {
                bestScore = score
                bestShape = Shape(extent = extent, goodRays = rays.good, score = score)
                best = BallMeasurement(diameterPx = diameter, x = cx, y = cy,
                                       areaPx = blob.count.toDouble(),
                                       subpixelRefined = refinedOK)
            }
        }

        if (best != null) return Attempt.found(best, bestShape)
        val why = if (rejects.isEmpty()) {
            if (considered == 0) "no coloured blob under the tap" else "no candidate"
        } else {
            rejects.map { "${it.value}x ${it.key}" }.sorted().joinToString(", ")
        }
        return Attempt.failed(diagnosis, "$considered near tap · $why")
    }

    // Shape statistics

    private fun filledArea(labels: IntArray, w: Int, h: Int, blob: ConnectedComponents.Blob): Double {
        val bw = blob.maxX - blob.minX + 1
        val bh = blob.maxY - blob.minY + 1
        if (!(bw > 0 && bh > 0)) return blob.count.toDouble()

        val outside = BooleanArray(bw * bh)
        val stack = ArrayList<Int>()
        fun consider(bx: Int, by: Int) {
            if (!(bx >= 0 && bx < bw && by >= 0 && by < bh)) return
            val i = by * bw + bx
            if (outside[i]) return
            val gx = blob.minX + bx
            val gy = blob.minY + by
            if (labels[gy * w + gx] == blob.root) return
            outside[i] = true
            stack.add(i)
        }
        for (bx in 0 until bw) { consider(bx, 0); consider(bx, bh - 1) }
        for (by in 0 until bh) { consider(0, by); consider(bw - 1, by) }
        while (stack.isNotEmpty()) {
            val i = stack.removeAt(stack.size - 1)
            val bx = i % bw
            val by = i / bw
            consider(bx - 1, by); consider(bx + 1, by)
            consider(bx, by - 1); consider(bx, by + 1)
        }
        var filled = 0
        for (i in 0 until bw * bh) if (!outside[i]) filled += 1
        return filled.toDouble()
    }

    private data class RayProfile(val good: Int, val median: Double, val failuresContiguous: Boolean)

    private fun rayProfile(labels: IntArray, w: Int, h: Int, blob: ConnectedComponents.Blob): RayProfile {
        val rEq = sqrt(blob.count.toDouble() / PI)
        val reach = rayReachFactor * rEq
        val step = 0.25

        val lengths = DoubleArray(rayCount)
        val escaped = BooleanArray(rayCount)
        val inWindow = BooleanArray(rayCount) { true }

        for (k in 0 until rayCount) {
            val a = 2 * PI * k.toDouble() / rayCount.toDouble()
            val ca = cos(a)
            val sa = sin(a)
            var r = 0.0
            var last = 0.0
            var ok = true
            while (r <= reach) {
                val px = (blob.meanX + r * ca).rounded().toInt()
                val py = (blob.meanY + r * sa).rounded().toInt()
                if (px < 0 || px >= w || py < 0 || py >= h) { ok = false; break }
                if (labels[py * w + px] == blob.root) last = r
                r += step
            }
            lengths[k] = last
            inWindow[k] = ok
            escaped[k] = last < reach - 0.3
        }

        val sorted = lengths.sorted()
        val median = sorted[sorted.size / 2]
        var good = 0
        val failing = BooleanArray(rayCount)
        for (k in 0 until rayCount) {
            val withinBand = median > 0 && abs(lengths[k] - median) <= rayBand * median
            if (inWindow[k] && escaped[k] && withinBand) good += 1 else failing[k] = true
        }

        var runs = 0
        for (k in 0 until rayCount) {
            if (failing[k] && !failing[(k + rayCount - 1) % rayCount]) runs += 1
        }
        return RayProfile(good = good, median = median, failuresContiguous = runs <= 1)
    }
}
