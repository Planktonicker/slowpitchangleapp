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

    /// Cap on stored candidates. Ten thousand is far more than a real swing
    /// produces and small enough to write and read without thinking about it.
    static let candidateLimit = 10_000

    var hasSearchRegion: Bool {
        searchedX0 != nil && searchedY0 != nil && searchedX1 != nil && searchedY1 != nil
    }
}
