// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs
import kotlin.math.max

// The "Frame rate" section of `ClipAnalyzer.swift` (replay_corpus.derive_fps);
// the reasoning lives there. Its own file because it is the one piece of
// ClipAnalyzer every exit velocity scales with, and it is pinned to the Python
// by the `frame_timing` fixture block. The members are extensions on
// [ClipAnalyzer] so that calls read as the Swift's do —
// `ClipAnalyzer.frameTiming(fromIntervals = ...)` — without one object being
// split across two files, which Kotlin cannot do. `measureFrameTiming`, which
// reads the timestamps out of a file, is decoding and belongs to the app layer.

/** Port of `ClipAnalyzer.FrameTiming` (what a clip's own sample timing says its frame rate is); the reasoning lives there. */
data class FrameTiming(
    val fps: Double,
    val intervals: Int,
    val irregularFraction: Double,
    val droppedFraction: Double,
)

/** Port of `ClipAnalyzer.maxSinglePeriodRatio` (replay_corpus.SINGLE_INTERVAL_RATIO); the reasoning lives there. */
val ClipAnalyzer.maxSinglePeriodRatio: Double get() = 1.5

/** Port of `ClipAnalyzer.singleIntervalSlack` (replay_corpus.SINGLE_INTERVAL_SLACK); the reasoning lives there. */
val ClipAnalyzer.singleIntervalSlack: Double get() = 1e-6

/**
 * Port of `ClipAnalyzer.frameTiming(fromIntervals:)` (replay_corpus.derive_fps
 * over adjacent frames); the reasoning lives there.
 */
fun ClipAnalyzer.frameTiming(fromIntervals: List<Double>): FrameTiming? {
    val usable = fromIntervals.filter { it > 0 && it.isFinite() }
    if (usable.size < 4) return null
    val sorted = usable.sorted()

    val shortest = sorted[max(0, sorted.size / 20)]
    if (!(shortest > 0)) return null
    val singles = sorted.filter {
        it <= shortest * maxSinglePeriodRatio * (1 + singleIntervalSlack)
    }
    if (singles.isEmpty()) return null
    // Summed in sorted order, left to right, as the Swift's `reduce` and the
    // Python's `sum` both do: the mean of the singles IS the frame rate.
    var total = 0.0
    for (s in singles) total += s
    val base = total / singles.size.toDouble()
    if (!(base > 0) || !base.isFinite()) return null

    var expected = 0.0
    var irregular = 0
    for (i in usable) {
        val periods = (i / base).rounded()
        if (periods >= 1 && abs(i - periods * base) <= base * 0.25) {
            expected += periods
        } else {
            irregular += 1
            expected += 1
        }
    }
    val dropped = swiftMax(0.0, expected - usable.size.toDouble())
    return FrameTiming(
        fps = 1 / base,
        intervals = usable.size,
        irregularFraction = irregular.toDouble() / usable.size.toDouble(),
        droppedFraction = if (expected > 0) dropped / expected else 0.0,
    )
}
