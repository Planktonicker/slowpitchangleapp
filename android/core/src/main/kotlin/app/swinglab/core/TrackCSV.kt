// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.math.BigDecimal
import kotlin.math.PI

/**
 * Port of `TrackCSV.swift` `enum TrackCSV` (the CSV format of
 * sla_common.write_track_csv); the reasoning lives there. Keep it
 * byte-compatible with the Swift.
 *
 * The private helpers below exist because the Kotlin namesakes of the Swift
 * string calls answer differently: `trim()` strips newlines and controls where
 * `.whitespaces` does not, `toDoubleOrNull()` accepts surrounding whitespace and
 * a trailing `d`/`f` where `Double(_:)` does not, `toIntOrNull()` accepts
 * non-ASCII digits, `split(",")` keeps the empty fields that the Swift header
 * split omits, and `Double.toString()` spells exponents differently.
 */
object TrackCSV {

    /** Port of `TrackCSV.serialize(track:fps:meta:)`. */
    fun serialize(
        track: List<BallObservation>,
        fps: Double,
        meta: List<Pair<String, String>> = emptyList(),
    ): String {
        val out = StringBuilder()
        for ((k, v) in meta) {
            out.append("# ").append(k).append('=').append(v).append('\n')
        }
        out.append("# fps=").append(fmt(fps)).append('\n')
        out.append("frame,t,x_px,y_px,diameter_px,area_px\n")
        for (o in track) {
            out.append(o.frame).append(',')
            out.append(formatFixed(o.t, 6)).append(',')
            out.append(formatFixed(o.x, 2)).append(',')
            out.append(formatFixed(o.y, 2)).append(',')
            out.append(formatFixed(o.diameterPx, 2)).append(',')
            out.append(formatFixed(o.areaPx, 1)).append('\n')
        }
        return out.toString()
    }

    /** Port of `TrackCSV.fmt`: `%.1f` for a whole number, else Swift's `String(Double)`. */
    private fun fmt(d: Double): String =
        if (d == d.rounded()) formatFixed(d, 1) else swiftDescription(d)

    /** Port of `TrackCSV.Parsed`. */
    data class Parsed(
        val track: List<BallObservation>,
        val meta: Map<String, String>,
    ) {
        val fps: Double? get() = meta["fps"]?.let { swiftDouble(it) }
        val contactTime: Double? get() = meta["contact_time"]?.let { swiftDouble(it) }
    }

    /** Port of `TrackCSV.parse(_:)`. */
    fun parse(text: String): Parsed {
        val meta = LinkedHashMap<String, String>()
        val rows = mutableListOf<String>()
        for (line in swiftLines(text)) {
            if (line.startsWith("#")) {
                val body = trimWhitespaces(line.substring(1))
                val eq = body.indexOf('=')
                if (eq >= 0) {
                    val k = trimWhitespaces(body.substring(0, eq))
                    val v = trimWhitespaces(body.substring(eq + 1))
                    meta[k] = v
                }
                continue
            }
            if (trimWhitespaces(line).isEmpty()) continue
            rows.add(line)
        }
        val header = rows.firstOrNull() ?: return Parsed(track = emptyList(), meta = meta)
        // Swift's `split(separator:)` omits empty subsequences by default.
        val cols = header.split(",").filter { it.isNotEmpty() }.map { trimWhitespaces(it) }
        fun idx(name: String): Int? = cols.indexOf(name).takeIf { it >= 0 }
        val iFrame = idx("frame")
        val iT = idx("t")
        val iX = idx("x_px")
        val iY = idx("y_px")
        val iD = idx("diameter_px")
        if (iFrame == null || iT == null || iX == null || iY == null || iD == null) {
            return Parsed(track = emptyList(), meta = meta)
        }
        val iA = idx("area_px")

        val track = mutableListOf<BallObservation>()
        for (row in rows.drop(1)) {
            val f = row.split(",")
            if (f.size < cols.size) continue
            val frame = swiftInt(f[iFrame]) ?: continue
            val t = swiftDouble(f[iT]) ?: continue
            val x = swiftDouble(f[iX]) ?: continue
            val y = swiftDouble(f[iY]) ?: continue
            val d = swiftDouble(f[iD]) ?: continue
            val area = iA?.let { swiftDouble(f[it]) } ?: (PI * (d / 2) * (d / 2))
            track.add(BallObservation(frame = frame, t = t, x = x, y = y,
                                      diameterPx = d, areaPx = area))
        }
        return Parsed(track = track, meta = meta)
    }

    // Swift `String` semantics the parse depends on.

    /**
     * `text.split(separator: "\n", omittingEmptySubsequences: false)`. A Swift
     * String splits by Character, and "\r\n" is ONE Character that is not
     * "\n", so a CRLF pair is not a separator there and is not one here.
     */
    private val swiftLineBreak = Regex("(?<!\r)\n")
    private fun swiftLines(text: String): List<String> = text.split(swiftLineBreak)

    /** `CharacterSet.whitespaces`: Unicode Zs plus tab, and NOT newlines. */
    private fun isSwiftWhitespace(c: Char): Boolean =
        c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()

    private fun trimWhitespaces(s: String): String = s.trim { isSwiftWhitespace(it) }

    /** `Int(_: String)`: optional sign, ASCII digits only, nil on overflow. */
    private val swiftIntPattern = Regex("[+-]?[0-9]+")
    private fun swiftInt(s: String): Int? =
        if (swiftIntPattern.matches(s)) s.toIntOrNull() else null

    /**
     * `Double(_: String)`: the whole string must be a C-locale `strtod` number,
     * with no surrounding whitespace — decimal, hexadecimal, or inf/nan in any
     * case.
     */
    private val swiftDecimal = Regex("[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?")
    private val swiftHex = Regex("([+-]?)0[xX]([0-9a-fA-F]+\\.?[0-9a-fA-F]*|\\.[0-9a-fA-F]+)([pP][+-]?[0-9]+)?")
    private val swiftInf = Regex("([+-]?)(inf|infinity)", RegexOption.IGNORE_CASE)
    private val swiftNan = Regex("[+-]?nan(\\([0-9A-Za-z_]*\\))?", RegexOption.IGNORE_CASE)
    private fun swiftDouble(s: String): Double? {
        if (swiftDecimal.matches(s)) return s.toDouble()
        swiftHex.matchEntire(s)?.let { m ->
            // Java insists on the binary exponent that strtod treats as optional.
            val (sign, digits, exponent) = m.destructured
            return (sign + "0x" + digits + exponent.ifEmpty { "p0" }).toDouble()
        }
        swiftInf.matchEntire(s)?.let { m ->
            return if (m.groupValues[1] == "-") Double.NEGATIVE_INFINITY else Double.POSITIVE_INFINITY
        }
        if (swiftNan.matches(s)) return Double.NaN
        return null
    }

    /**
     * `String(describing: Double)` for a finite value: the shortest round-trip
     * digits, written out in full from 1e-4 upward and as `1.5e-05` below it.
     * Only reached for a fractional fps, so the large-magnitude exponential
     * form (every such double is a whole number) never applies.
     */
    private fun swiftDescription(d: Double): String {
        if (d.isNaN()) return "nan"
        if (d.isInfinite()) return if (d < 0) "-inf" else "inf"
        val shortest = BigDecimal(d.toString())   // JDK 19+: shortest round-trip digits
        val sciExponent = shortest.precision() - shortest.scale() - 1
        if (d != 0.0 && sciExponent < -4) {
            val digits = shortest.unscaledValue().abs().toString().trimEnd('0')
            val mantissa = if (digits.length == 1) digits else digits.substring(0, 1) + "." + digits.substring(1)
            val sign = if (d < 0) "-" else ""
            val e = -sciExponent
            return sign + mantissa + "e-" + (if (e < 10) "0$e" else "$e")
        }
        val plain = shortest.toPlainString()
        return if (plain.contains('.')) plain else "$plain.0"
    }
}
