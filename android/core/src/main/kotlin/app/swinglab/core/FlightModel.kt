// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Port of `FlightModel.swift` (sla_common.simulate_flight / vy0_from_hang_time); the reasoning lives there. */
object FlightModel {

    data class Flight(
        val carryM: Double,
        val hangS: Double,
        val apexM: Double,
    )

    /** Port of `FlightModel.simulate` (sla_common.simulate_flight): fixed-step Euler, step for step. */
    fun simulate(
        evMps: Double,
        laDeg: Double,
        contactHeightM: Double = 0.9,
        dt: Double = 0.002,
    ): Flight {
        val k = 0.5 * SLA.airDensity * SLA.dragCd * PI *
            (SLA.ballDiameterM / 2) * (SLA.ballDiameterM / 2)
        val la = laDeg * PI / 180
        var vx = evMps * cos(la)
        var vy = evMps * sin(la)
        var x = 0.0
        var y = contactHeightM
        var t = 0.0
        var apex = contactHeightM

        while (y > 0.0 && t < 20.0) {
            val v = sqrt(vx * vx + vy * vy)
            val ax = -k / SLA.ballMassKg * v * vx
            val ay = -SLA.g - k / SLA.ballMassKg * v * vy
            vx += ax * dt
            vy += ay * dt
            x += vx * dt
            y += vy * dt
            t += dt
            apex = swiftMax(apex, y)
        }
        return Flight(carryM = x, hangS = t, apexM = apex)
    }

    /** Port of `FlightModel.vy0FromHangTime` (sla_common.vy0_from_hang_time); the reasoning lives there. */
    fun vy0FromHangTime(hangS: Double): Double = SLA.g * hangS / 2.0

    /** Port of `FlightModel.GroundTruthCheck` (validation gate G3, per clip); the reasoning lives there. */
    data class GroundTruthCheck(
        val model: Flight,
        val measuredHangS: Double?,
        val measuredCarryM: Double?,
    ) {
        val hangErrorPct: Double?
            get() {
                val h = measuredHangS
                if (h == null || !(h > 0)) return null
                return (model.hangS - h) / h * 100
            }
        val carryErrorPct: Double?
            get() {
                val c = measuredCarryM
                if (c == null || !(c > 0)) return null
                return (model.carryM - c) / c * 100
            }
        val hangPasses: Boolean? get() = hangErrorPct?.let { abs(it) <= 15 }
        val carryPasses: Boolean? get() = carryErrorPct?.let { abs(it) <= 20 }
    }

    /** Port of `FlightModel.check`; the reasoning lives there. */
    fun check(
        metrics: SwingMetrics,
        hangS: Double?,
        carryM: Double?,
        contactHeightM: Double = 0.9,
    ): GroundTruthCheck = GroundTruthCheck(
        model = simulate(
            evMps = metrics.exitVeloMps,
            laDeg = metrics.launchAngleDeg,
            contactHeightM = contactHeightM,
        ),
        measuredHangS = hangS,
        measuredCarryM = carryM,
    )
}
