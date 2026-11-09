// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/** Port of `Units.swift` `SpeedUnit`; the reasoning lives there. */
enum class SpeedUnit(val raw: String) {
    mph("mph"),
    kmh("kmh");

    val displayName: String
        get() = when (this) {
            mph -> "Miles per hour"
            kmh -> "Kilometres per hour"
        }

    val suffix: String
        get() = when (this) {
            mph -> "mph"
            kmh -> "km/h"
        }

    val perMps: Double
        get() = when (this) {
            mph -> SLA.mphPerMps
            kmh -> 3.6
        }

    fun from(mps: Double): Double = mps * perMps

    fun fromMph(mph: Double): Double = when (this) {
        SpeedUnit.mph -> mph
        kmh -> mph / SLA.mphPerMps * 3.6
    }

    fun format(mph: Double, decimals: Int = 1): String = formatFixed(fromMph(mph), decimals)

    companion object {
        fun fromRaw(raw: String): SpeedUnit? = entries.firstOrNull { it.raw == raw }
    }
}

/** Port of `Units.swift` `enum Fmt` (display formatting of metric quantities); the reasoning lives there. */
object Fmt {

    fun m(metres: Double, decimals: Int = 1): String = formatFixed(metres, decimals) + " m"

    fun cm(metres: Double, decimals: Int = 1): String = formatFixed(metres * 100, decimals) + " cm"

    fun signedMm(metres: Double): String = formatFixed(metres * 1000, 0, plusSign = true) + " mm"

    fun mmPerPx(metresPerPixel: Double): String = formatFixed(metresPerPixel * 1000, 3) + " mm/px"
}
