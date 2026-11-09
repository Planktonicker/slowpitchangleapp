// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.devcheck

import java.util.Locale

/**
 * A plain-text report, built line by line.
 *
 * Plain text because the owner copies it into a chat and it is read by a
 * person and by whoever ports the next stage. Every number goes through
 * [num] so the decimal separator is a dot on a phone set to any locale — a
 * report that says "4,17 ms" on one phone and "4.17 ms" on another cannot be
 * compared, or parsed.
 */
class Report {
    private val sb = StringBuilder()
    fun line(s: String = "") { sb.append(s).append('\n') }
    fun section(title: String) { line(); line("== $title ==") }
    override fun toString() = sb.toString()
}

fun num(x: Double, decimals: Int = 2): String = String.format(Locale.ROOT, "%.${decimals}f", x)
fun num(x: Float, decimals: Int = 2): String = num(x.toDouble(), decimals)

/** Frame-interval statistics from a list of timestamps in microseconds. */
data class IntervalStats(
    val frames: Int,
    val medianUs: Double,
    val minUs: Double,
    val maxUs: Double,
    /** Intervals more than 1.5x the median: a dropped or late frame. */
    val longGaps: Int,
    /** Distinct interval clusters (rounded to 0.25 ms) holding at least 2% of intervals. */
    val clusters: List<Pair<Double, Int>>,
) {
    val fps: Double get() = if (medianUs > 0) 1e6 / medianUs else 0.0

    companion object {
        /**
         * Sorted first: a decoder hands samples over in DECODE order, and with
         * B-frames that is not presentation order, so raw differences would
         * include negative intervals.
         */
        fun of(timestampsUs: List<Long>): IntervalStats? {
            val t = timestampsUs.sorted()
            if (t.size < 3) return null
            val d = t.zipWithNext { a, b -> (b - a).toDouble() }.filter { it > 0 }
            if (d.isEmpty()) return null
            val s = d.sorted()
            val median = s[s.size / 2]
            val long = d.count { it > 1.5 * median }
            val buckets = d.groupingBy { Math.round(it / 250.0) * 250.0 }.eachCount()
            val clusters = buckets.filter { it.value >= maxOf(2, d.size / 50) }
                .toList().sortedByDescending { it.second }.take(6)
            return IntervalStats(t.size, median, s.first(), s.last(), long, clusters)
        }
    }

    fun describe(r: Report, label: String) {
        r.line("$label: $frames frames, median interval ${num(medianUs / 1000, 3)} ms = ${num(fps, 1)} fps")
        r.line("  min ${num(minUs / 1000, 3)} ms, max ${num(maxUs / 1000, 3)} ms, intervals over 1.5x median: $longGaps")
        r.line("  interval clusters (ms : count): " +
            clusters.joinToString(", ") { "${num(it.first / 1000, 2)} : ${it.second}" })
    }
}
