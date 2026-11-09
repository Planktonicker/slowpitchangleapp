// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Port of `BallObservation.swift` `BallObservation` (sla_common.BallObservation);
 * the reasoning lives there. Image coordinates: x right, y DOWN, px; t in s.
 */
data class BallObservation(
    val frame: Int,
    val t: Double,
    val x: Double,
    val y: Double,
    val diameterPx: Double,
    val areaPx: Double,
)

/** Port of `BallObservation.swift` `SwingMetrics` (sla_common.SwingMetrics); the reasoning lives there. */
data class SwingMetrics(
    val launchAngleDeg: Double,
    val exitVeloMph: Double,
    val exitVeloMps: Double,
    val scaleBallMPerPx: Double,
    val scaleGravityMPerPx: Double?,
    val scaleDisagreement: Double?,
    val diameterDrift: Double,
    val nFrames: Int,
    val trackDurationS: Double,
    val fitRmsPx: Double,
    val t0: Double,
    val vxPxS: Double,
    val vyPxS: Double,
    val x0Px: Double = 0.0,
    val y0Px: Double = 0.0,
    val flags: List<SwingFlag>,
) {
    val highConfidence: Boolean get() = flags.isEmpty()
}
