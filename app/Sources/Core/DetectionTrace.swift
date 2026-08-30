// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// What the detector saw, as opposed to what it concluded.
///
/// The track alone cannot answer the only question anybody asks of a failed
/// measurement — "the ball is RIGHT THERE, why did it not find it?" — because
/// a track is what survived, and every interesting failure is about what did
/// not. Three different things produce an identical empty result:
///
///  1. The pixels were never examined, because they fell outside the region
///     the search was restricted to.
///  2. They were examined and rejected by the colour or shape gates.
///  3. They were accepted as a candidate and then discarded, by the corridor
///     filter or by track building preferring a different chain.
///
/// Those want three different fixes, and telling them apart from the outside
/// is impossible. So the searched region and every candidate are kept, and the
/// review screen draws them: a marker where a candidate was found but not
/// used, and an outline around what was actually looked at.
struct DetectionTrace: Codable, Sendable, Equatable {

    /// Every candidate that passed the colour and shape gates, before the
    /// corridor filter and before track building — the detector's raw opinion.
    var candidates: [BallObservation] = []

    /// The region searched, in buffer pixels. `nil` means the whole frame was
    /// searched, which is the fallback path.
    var searchedX0: Int?
    var searchedY0: Int?
    var searchedX1: Int?
    var searchedY1: Int?

    /// Set when `candidates` was cut short. A clip that produces hundreds of
    /// thousands of candidates is itself the finding — it means the colour
    /// window is matching scenery — and writing all of them helps nobody.
    var truncated = false

    /// Caps on stored candidates.
    ///
    /// Two of them, because the failure modes differ. The per-frame cap stops
    /// one grassy frame from flooding the file with hundreds of near-identical
    /// clutter blobs — nobody reviews the 300th ring on a single frame, and
    /// past a couple of dozen the finding is "the colour window is matching
    /// scenery", which the diagnostics already state in words. The total cap
    /// bounds the file. Both being hit is recorded, because a truncated trace
    /// must say "not saved past here" rather than let an empty frame read as
    /// "nothing was detected".
    static let perFrameLimit = 24
    static let candidateLimit = 20_000

    /// Time of the last candidate that was actually stored, when truncation
    /// cut recording short. Before this instant an empty frame means nothing
    /// was found; after it, it means nothing was SAVED.
    var truncatedAtT: Double?

    /// One candidate track the builder produced, summarised.
    ///
    /// The track alone answers "what was measured". These answer the question
    /// that actually gets asked when a measurement is wrong — "the ball IS
    /// being tracked, why wasn't it chosen?" — which nothing in the app could
    /// answer, because every track except the winner was discarded before
    /// anyone could look at it. Twice now a plausible cause has been fixed on
    /// reasoning alone and turned out not to be the cause; this is what stops
    /// the third guess.
    struct TrackSummary: Codable, Sendable, Equatable {
        struct Point: Codable, Sendable, Equatable { var x: Double; var y: Double }
        var frames: Int
        var startT: Double
        var endT: Double
        /// Net displacement over elapsed time — the number selection scores on.
        var speedPxS: Double
        /// Net displacement over distance walked. Below the threshold this is
        /// clutter that never travelled.
        var straightness: Double
        /// Whether this is the track the measurement came from.
        var selected: Bool
        /// Why it lost, in the selector's own terms. Empty for the winner.
        var rejectedBecause: String
        /// Subsampled polyline, enough to see the shape.
        var points: [Point]
    }

    /// Every candidate track worth drawing, best-scoring first. Capped: past a
    /// couple of dozen the picture is noise, and the ones that matter are the
    /// fastest few plus whichever won.
    var trackSummaries: [TrackSummary] = []
    static let trackSummaryLimit = 20
    static let trackPointLimit = 32

    /// How many tracks the builder produced in total, before this list was cut
    /// down. A large number with nothing following the ball is a different
    /// finding from a small number.
    var tracksBuilt = 0

    /// For the fastest few chains that did NOT join each other: which stitch
    /// gate refused, with the measured value against its limit. One line per
    /// ordered pair, e.g. "0.795s -> 0.824s  gap 29ms: direction differs 63
    /// deg (limit 40)". This exists because a screenshot showed three
    /// fragments of one flight staying apart and nothing on screen could say
    /// WHY — and the difference between "gap too long", "endpoints too
    /// ragged" and "tolerance too tight" is the difference between three
    /// different fixes.
    var stitchExplains: [String] = []

    var hasSearchRegion: Bool {
        searchedX0 != nil && searchedY0 != nil && searchedX1 != nil && searchedY1 != nil
    }
}
