// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Port of `BatTracker.swift` `BatMetrics` (barrel path through contact, from the
 * fluorescent tape on the bat); the reasoning lives there. Codable is dropped,
 * as it is from [BallObservation]: the JSON shape belongs to the app layer.
 *
 * There is no Python counterpart to pin this against: `sla_common.py` is handed
 * the tape's velocity and contact position (`bat_speed_mps`, `undercut_m`) and
 * never tracks the tape itself. The tests are synthetic for that reason.
 */
data class BatMetrics(
    val attackAngleDeg: Double,
    val nFrames: Int,
    val fitRmsPx: Double,
    val pathPx: List<Point>,
    val vxPxS: Double,
    val vyPxS: Double,
    val contactXPx: Double,
    val contactYPx: Double,
) {
    val isLowConfidence: Boolean get() = nFrames < 6 || fitRmsPx > 6.0
}

/** Port of `BatTracker.swift` `enum BatTracker`; the reasoning lives there. */
object BatTracker {

    /** Port of `BatTracker.Settings`; the reasoning (including the 8 m/s presence floor) lives there. */
    data class Settings(
        var hsvLo: HSVBounds = SLA.batHSVLoDefault,
        var hsvHi: HSVBounds = SLA.batHSVHiDefault,
        var windowS: Double = 0.06,
        var minBlobArea: Double = 30.0,
        var maxBlobArea: Double = 20000.0,
        var minBarrelSpeedMps: Double = 8.0,
    ) {
        /** Kotlin-only: the copy a Swift struct assignment makes; see [DetectorSettings.deepCopy]. */
        fun deepCopy(): Settings = copy(hsvLo = hsvLo.copy(), hsvHi = hsvHi.copy())
    }

    /** Port of `BatTracker.TapeObservation`. */
    data class TapeObservation(val t: Double, val x: Double, val y: Double)

    /**
     * Port of `BatTracker.detectTape`: the largest tape-coloured blob, motion-gated,
     * in full-frame pixels; the reasoning lives there. The Swift's `(x:, y:)`
     * tuple is a [Point]. [motion] is in full-frame coordinates, as for
     * [BallDetector.maskAfterMorphology].
     */
    fun detectTape(
        image: PixelImage,
        settings: Settings,
        roi: ROI? = null,
        motion: BooleanArray? = null,
    ): Point? {
        val r = (roi ?: ROI(0, 0, image.width, image.height))
            .clamped(image.width, image.height)
        val w = r.x1 - r.x0
        val h = r.y1 - r.y0
        if (!(w > 2 && h > 2)) return null

        val mask = BallDetector.maskAfterMorphology(image, r, settings.hsvLo, settings.hsvHi, motion)

        val blobs = ConnectedComponents.label(mask, w, h)
        var best: ConnectedComponents.Blob? = null
        for (b in blobs) {
            val area = b.count.toDouble()
            if (!(area >= settings.minBlobArea && area <= settings.maxBlobArea)) continue
            if (best == null || b.count > best.count) best = b
        }
        val b = best ?: return null
        return Point(r.x0.toDouble() + b.meanX, r.y0.toDouble() + b.meanY)
    }

    /** Port of `BatTracker.analyze`: quadratic fit of the tape path, angle at contact; the reasoning lives there. */
    fun analyze(observations: List<TapeObservation>, contactTime: Double): BatMetrics? {
        if (observations.size < 3) return null
        val sorted = observations.sortedBy { it.t }
        val ts = sorted.map { it.t - contactTime }
        val xs = sorted.map { it.x }
        val ys = sorted.map { it.y }

        val fx = Geometry.fitQuadratic(ts = ts, vs = xs)
        val fy = Geometry.fitQuadratic(ts = ts, vs = ys)
        val vx = fx.b
        val vy = fy.b
        if (!(vx != 0.0 || vy != 0.0)) return null

        val angle = atan2(-vy, abs(vx)) * 180 / PI
        val rms = sqrt(fx.rms * fx.rms + fy.rms * fy.rms)

        return BatMetrics(
            attackAngleDeg = angle,
            nFrames = sorted.size,
            fitRmsPx = rms,
            pathPx = xs.zip(ys) { x, y -> Point(x, y) },
            vxPxS = vx,
            vyPxS = vy,
            contactXPx = fx.c,
            contactYPx = fy.c,
        )
    }

    /**
     * Kotlin-only: the frames the tape is looked for in — `batWindow`, which
     * `ClipAnalyzer.swift` builds inline, lifted out so it can be tested before
     * ClipAnalyzer is ported. `null` without a contact time: no contact, no bat
     * panel (the reasoning is at that site — a window anchored on anything else
     * extrapolated a fabricated attack angle). Closed at both ends, like the
     * Swift's `ClosedRange`.
     */
    fun window(contactTime: Double?, settings: Settings = Settings()): ClosedFloatingPointRange<Double>? =
        contactTime?.let { (it - settings.windowS)..(it + 0.005) }

    /**
     * Kotlin-only: `ClipAnalyzer.swift`'s presence gate, lifted out for the same
     * reason as [window]. A candidate whose tape moved slower than
     * [Settings.minBarrelSpeedMps] at contact was not a swinging bat and is
     * withheld, not flagged. A NaN scale fails the comparison and withholds it,
     * as in the Swift.
     */
    fun isSwingingBat(candidate: BatMetrics, scaleMPerPx: Double, settings: Settings = Settings()): Boolean =
        SLA.batSpeedMps(candidate.vxPxS, candidate.vyPxS, scaleMPerPx) >= settings.minBarrelSpeedMps
}
