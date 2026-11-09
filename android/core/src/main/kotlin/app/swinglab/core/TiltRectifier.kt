// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/** Port of `TiltRectifier.swift` (sla_common.focal_px_from_fov / rectify_tilt_point / rectify_tilt); the reasoning lives there. */
object TiltRectifier {

    /** The unnamed `(x, y, magnification)` tuple the point-level `rectify` returns. */
    data class Rectified(val x: Double, val y: Double, val magnification: Double)

    /** Port of `TiltRectifier.focalPx` (sla_common.focal_px_from_fov); the reasoning lives there. */
    fun focalPx(widthPx: Double, fovDeg: Double): Double {
        if (!(widthPx > 0) || !(fovDeg > 0) || !(fovDeg < 180)) return 0.0
        return (widthPx / 2) / tan(fovDeg * PI / 180 / 2)
    }

    /** Port of the point-level `TiltRectifier.rectify` (sla_common.rectify_tilt_point); the reasoning lives there. */
    fun rectify(
        x: Double, y: Double,
        tiltDeg: Double, focalPx: Double,
        cx: Double, cy: Double,
    ): Rectified {
        if (tiltDeg == 0.0 || !(focalPx > 0)) return Rectified(x, y, 1.0)
        val t = tiltDeg * PI / 180
        val cosT = cos(t); val sinT = sin(t)
        val u = x - cx
        val v = y - cy
        val d = focalPx * cosT - v * sinT
        if (!(d > 0)) return Rectified(x, y, 1.0)
        val mag = focalPx / d
        return Rectified(
            cx + u * mag,
            cy + (v * cosT + focalPx * sinT) * mag,
            mag,
        )
    }

    /** Port of the track-level `TiltRectifier.rectify` (sla_common.rectify_tilt); the reasoning lives there. */
    fun rectify(
        track: List<BallObservation>,
        tiltDeg: Double, focalPx: Double,
        cx: Double, cy: Double,
    ): List<BallObservation> {
        if (tiltDeg == 0.0 || !(focalPx > 0)) return track
        return track.map { o ->
            val r = rectify(x = o.x, y = o.y, tiltDeg = tiltDeg, focalPx = focalPx, cx = cx, cy = cy)
            BallObservation(
                frame = o.frame, t = o.t, x = r.x, y = r.y,
                diameterPx = o.diameterPx * r.magnification,
                areaPx = o.areaPx,
            )
        }
    }
}
