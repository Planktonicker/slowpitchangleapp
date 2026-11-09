// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.sign
import kotlin.math.truncate

// Swift standard-library numerics whose Kotlin namesakes silently answer
// differently. No Swift counterpart file: these exist so that every ported file
// reproduces the Swift (and through it the Python) instead of each slice of
// the port writing its own, subtly different, copy.

/**
 * Swift's `x.rounded()`: half AWAY from zero (C `round`). Kotlin's `round()`
 * is half-to-even and `Math.round` is half-up, so neither will do.
 *
 * Exact, unlike `sign(x) * floor(abs(x) + 0.5)`, whose addition rounds
 * 0.49999999999999994 up to 1.
 */
fun Double.rounded(): Double {
    val t = truncate(this)
    // x - trunc(x) is exact for every finite double; NaN and ±inf fall through
    // with diff = NaN and come back unchanged, as they do from C `round`.
    val diff = this - t
    return if (abs(diff) >= 0.5) t + sign(this) else t
}

/**
 * Swift's two-argument `max`: `y >= x ? y : x`. Differs from `kotlin.math.max`
 * only when one side is NaN (Swift returns whichever argument the comparison
 * falls through to, as Python's builtin `max` does; Kotlin propagates NaN) and
 * in which zero it returns for `max(0.0, -0.0)`.
 */
fun swiftMax(x: Double, y: Double): Double = if (y >= x) y else x

/** Swift's two-argument `min`: `y < x ? y : x`. See [swiftMax]. */
fun swiftMin(x: Double, y: Double): Double = if (y < x) y else x

/**
 * `String(format: "%.<decimals>f", x)` as Swift prints it, `"%+.<decimals>f"`
 * with [plusSign].
 *
 * Not `String.format`: Java's formatter is locale-dependent (a comma decimal
 * point on a German phone) and rounds the shortest decimal representation
 * half-up, so `%.1f` of 0.15 reads "0.2" where C printf, rounding the exact
 * binary value half-to-even, reads "0.1". This rounds the exact value the way
 * printf does and keeps printf's sign on a negative that rounds to zero.
 */
fun formatFixed(x: Double, decimals: Int, plusSign: Boolean = false): String {
    require(decimals >= 0) { "formatFixed: negative precision" }
    val negative = x < 0 || (x == 0.0 && 1.0 / x < 0)
    val sign = if (negative) "-" else if (plusSign) "+" else ""
    if (x.isNaN()) return (if (plusSign) "+" else "") + "nan"
    if (x.isInfinite()) return sign + "inf"
    return sign + BigDecimal(abs(x)).setScale(decimals, RoundingMode.HALF_EVEN).toPlainString()
}
