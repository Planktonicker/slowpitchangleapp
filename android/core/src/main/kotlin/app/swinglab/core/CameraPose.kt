// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.tan

/**
 * Port of `CameraPose.swift` `enum CameraPose` (app-only placement geometry, no
 * sla_common counterpart); the reasoning lives there. `tiltDeg` is positive
 * aiming DOWN; vertical fractions are 0 at the top.
 */
object CameraPose {

    /** Port of `CameraPose.verticalHalfAngleDeg(horizontalFovDeg:frameAspect:)`. */
    fun verticalHalfAngleDeg(horizontalFovDeg: Double, frameAspect: Double): Double? {
        if (!(horizontalFovDeg > 1) || !(horizontalFovDeg < 179) || !(frameAspect > 0.05)) return null
        val hHalf = horizontalFovDeg * PI / 360
        return atan(tan(hHalf) / frameAspect) * 180 / PI
    }

    /** Port of `CameraPose.visibleVerticalHalfAngleDeg(horizontalFovDeg:isLandscape:screenAspect:)`. */
    fun visibleVerticalHalfAngleDeg(
        horizontalFovDeg: Double,
        isLandscape: Boolean,
        screenAspect: Double,
    ): Double? {
        if (!(horizontalFovDeg > 1) || !(horizontalFovDeg < 179)) return null
        val hHalf = horizontalFovDeg * PI / 360
        if (!isLandscape) return hHalf * 180 / PI
        return atan(tan(hHalf) / swiftMax(0.1, screenAspect)) * 180 / PI
    }

    /** Port of `CameraPose.horizonFraction(tiltDeg:visibleVerticalHalfAngleDeg:)`; deliberately not clamped. */
    fun horizonFraction(tiltDeg: Double, visibleVerticalHalfAngleDeg: Double): Double? {
        val vHalf = visibleVerticalHalfAngleDeg
        if (!(vHalf > 0.5) || !(vHalf < 89)) return null
        val t = tiltDeg * PI / 180
        if (!(abs(tiltDeg) < 85)) return null
        return 0.5 - tan(t) / (2 * tan(vHalf * PI / 180))
    }

    /** Port of `CameraPose.tiltDeg(forHorizonFraction:visibleVerticalHalfAngleDeg:)`, the inverse of [horizonFraction]. */
    fun tiltDeg(forHorizonFraction: Double, visibleVerticalHalfAngleDeg: Double): Double? {
        val fraction = forHorizonFraction
        val vHalf = visibleVerticalHalfAngleDeg
        if (!(vHalf > 0.5) || !(vHalf < 89) || !fraction.isFinite()) return null
        val t = atan((0.5 - fraction) * 2 * tan(vHalf * PI / 180))
        return t * 180 / PI
    }

    /** Port of `CameraPose.lensHeightM(feetFraction:distanceM:tiltDeg:verticalHalfAngleDeg:)`; null when it is not a height. */
    fun lensHeightM(
        feetFraction: Double,
        distanceM: Double,
        tiltDeg: Double,
        verticalHalfAngleDeg: Double,
    ): Double? {
        val vHalf = verticalHalfAngleDeg
        if (!(distanceM > 0.3) || !(distanceM < 60) || !(vHalf > 0.5) || !(vHalf < 89)) return null
        if (!feetFraction.isFinite() || !(feetFraction >= -0.5) || !(feetFraction <= 1.5)) return null
        val t = tiltDeg * PI / 180
        val offAxis = atan((0.5 - feetFraction) * 2 * tan(vHalf * PI / 180))
        val depression = t - offAxis
        if (!(depression > 0.002)) return null
        val h = distanceM * tan(depression)
        if (!h.isFinite() || !(h < 12)) return null
        return h
    }

    /** Port of `CameraPose.uprightBufferPoint(_:orientation:width:height:)`; null in portrait. */
    fun uprightBufferPoint(
        p: Point,
        orientation: ImagePropertyOrientation,
        width: Double,
        height: Double,
    ): Point? = when (quarterTurns(from = orientation)) {
        0 -> p
        2 -> Point(width - p.x, height - p.y)
        else -> null
    }

    /**
     * `VideoOrientation.quarterTurns(from:)`, copied because VideoOrientation.kt
     * belongs to another slice of the port and this one has to compile without
     * it. The Swift insists on ONE shared table; once VideoOrientation.kt is on
     * the same branch, delete this and call `VideoOrientation.quarterTurns(from =)`.
     */
    private fun quarterTurns(from: ImagePropertyOrientation): Int = when (from) {
        ImagePropertyOrientation.right, ImagePropertyOrientation.rightMirrored -> 1
        ImagePropertyOrientation.down, ImagePropertyOrientation.downMirrored -> 2
        ImagePropertyOrientation.left, ImagePropertyOrientation.leftMirrored -> 3
        else -> 0
    }

    /** Port of `CameraPose.idealLensHeightM`: contact height, and the height the outline is drawn for. */
    const val idealLensHeightM = 1.1

    /** Port of `CameraPose.lensHeightToleranceM`. */
    const val lensHeightToleranceM = 0.55

    /** Port of `CameraPose.outlineIsValid(tiltDeg:tiltToleranceDeg:lensHeightM:)`; an unmeasured height is not a failed one. */
    fun outlineIsValid(tiltDeg: Double?, tiltToleranceDeg: Double, lensHeightM: Double?): Boolean {
        if (tiltDeg == null || !(abs(tiltDeg) <= tiltToleranceDeg)) return false
        if (lensHeightM == null) return true
        return abs(lensHeightM - idealLensHeightM) <= lensHeightToleranceM
    }
}
