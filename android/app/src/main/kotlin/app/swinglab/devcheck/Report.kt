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
    /** Distinct interval clusters (rounded to 0.05 ms) holding at least 2% of intervals. */
    val clusters: List<Pair<Double, Int>>,
    /** Timestamps collapsed because they were within [DUPLICATE_US] of the previous one. */
    val duplicates: Int = 0,
) {
    val fps: Double get() = if (medianUs > 0) 1e6 / medianUs else 0.0

    companion object {
        /**
         * Sorted first: a decoder hands samples over in DECODE order, and with
         * B-frames that is not presentation order, so raw differences would
         * include negative intervals.
         */
        /**
         * Closer than this is the same frame reported twice, not two frames.
         *
         * Found on the owner's S21+: in a 240fps constrained high-speed session
         * the camera delivered almost every frame's capture result TWICE, with
         * sensor timestamps about 1 microsecond apart — 621 "intervals" of
         * 0.00 ms among 631 real ones of 4.17 ms. Counted as frames they put the
         * median between the two clusters and read "295 fps" off a camera
         * delivering 240. Half a millisecond is an eighth of a 240fps period and
         * still under half of a 960fps one.
         */
        const val DUPLICATE_US = 500L

        fun of(timestampsUs: List<Long>): IntervalStats? {
            val sorted = timestampsUs.sorted()
            val t = ArrayList<Long>(sorted.size)
            for (x in sorted) if (t.isEmpty() || x - t.last() >= DUPLICATE_US) t.add(x)
            val duplicates = sorted.size - t.size
            if (t.size < 3) return null
            val d = t.zipWithNext { a, b -> (b - a).toDouble() }.filter { it > 0 }
            if (d.isEmpty()) return null
            val s = d.sorted()
            val median = s[s.size / 2]
            val long = d.count { it > 1.5 * median }
            val buckets = d.groupingBy { Math.round(it / 50.0) * 50.0 }.eachCount()
            val clusters = buckets.filter { it.value >= maxOf(2, d.size / 50) }
                .toList().sortedByDescending { it.second }.take(6)
            return IntervalStats(t.size, median, s.first(), s.last(), long, clusters, duplicates)
        }
    }

    fun describe(r: Report, label: String) {
        r.line("$label: $frames frames, median interval ${num(medianUs / 1000, 3)} ms = ${num(fps, 1)} fps")
        r.line("  min ${num(minUs / 1000, 3)} ms, max ${num(maxUs / 1000, 3)} ms, intervals over 1.5x median: $longGaps")
        r.line("  interval clusters (ms : count): " +
            clusters.joinToString(", ") { "${num(it.first / 1000, 3)} : ${it.second}" })
        if (duplicates > 0) {
            r.line("  $duplicates timestamps were within ${num(DUPLICATE_US / 1000.0, 1)} ms of the one before " +
                "and were counted as the same frame reported twice, not as frames")
        }
    }
}
