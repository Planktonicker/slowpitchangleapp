// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Port of `DetectionTrace.swift` `struct DetectionTrace` (what the detector saw,
 * as opposed to what it concluded); the reasoning lives there.
 *
 * The Swift's Codable conformance is dropped, as it is from [BallObservation]:
 * core has no serialization dependency, and the JSON shape belongs to the app
 * layer that writes the file. Fields are `var` because the analyzer fills the
 * trace in as it goes, but each holds an immutable list, so `copy()` gives the
 * independent value a Swift struct assignment does.
 */
data class DetectionTrace(
    var candidates: List<BallObservation> = emptyList(),
    var searchedX0: Int? = null,
    var searchedY0: Int? = null,
    var searchedX1: Int? = null,
    var searchedY1: Int? = null,
    var truncated: Boolean = false,
    var contactT: Double? = null,
    var contactSource: String? = null,
    var frameCensus: List<FrameCensus>? = null,
    var truncatedAtT: Double? = null,
    var trackSummaries: List<TrackSummary> = emptyList(),
    var tracksBuilt: Int = 0,
    var usedBallSeed: Boolean = false,
    var ballSeedFoundNothing: Boolean = false,
    var stitchExplains: List<String> = emptyList(),
) {
    /** Port of `DetectionTrace.FrameCensus`: what the shape gates threw away in one frame. */
    data class FrameCensus(
        val frame: Int,
        val t: Double,
        val blobs: Int,
        val tooSmall: Int,
        val tooLarge: Int,
        val tooElongated: Int,
        val diameterOutOfRange: Int,
        val passed: Int,
    )

    /** Port of `DetectionTrace.TrackSummary`: one candidate track the builder produced, summarised. */
    data class TrackSummary(
        val frames: Int,
        val startT: Double,
        val endT: Double,
        val speedPxS: Double,
        val straightness: Double,
        val selected: Boolean,
        val rejectedBecause: String,
        val points: List<Point>,
    ) {
        /** Port of `DetectionTrace.TrackSummary.Point`. Kept under the Swift's name, so inside this class it shadows the core [app.swinglab.core.Point]. */
        data class Point(val x: Double, val y: Double)
    }

    val hasSearchRegion: Boolean
        get() = searchedX0 != null && searchedY0 != null && searchedX1 != null && searchedY1 != null

    companion object {
        const val perFrameLimit = 24
        const val candidateLimit = 20_000
        const val trackSummaryLimit = 20
        const val trackPointLimit = 32
    }
}
