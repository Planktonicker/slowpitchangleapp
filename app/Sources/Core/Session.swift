// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// One round of hitting, from walking up to the plate to walking away.
///
/// The app used to have no such thing: it armed, it recorded, and every swing
/// landed in one undifferentiated history. That is fine for validation work and
/// wrong for a hitter, who thinks in rounds — "how did I do just now" is a
/// question about the last twenty minutes, not about every swing ever taken.
///
/// A session also gives the honest-measurement rule somewhere to land. Mid-round
/// the app should not be arguing about confidence; it should be recording. The
/// argument belongs at the end, once, where the swings worth standing behind can
/// be separated from the ones that are not — see `SessionSummary`.
struct Session: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var mode: SessionMode = .live
    var startedAt: Date = Date()
    var endedAt: Date?

    var isOpen: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Rebuild a finished round from the swings that carry its id.
    ///
    /// Rounds are **derived, not stored**, and that is the whole design. A
    /// parallel table of sessions is a second copy of the same fact, and the
    /// two go out of step the first time somebody deletes a swing: the round
    /// still claims twelve, eleven exist, and nothing reconciles them. Here the
    /// round IS its swings — delete one and the round shrinks, delete them all
    /// and the round is gone, which is the honest answer to "what happened to
    /// that round" in every case.
    ///
    /// It also means no schema migration to make finished rounds reopenable:
    /// every swing already carries the id.
    ///
    /// What is lost is the round's true clock. `startedAt` becomes the first
    /// swing rather than the moment ARM was pressed, so a round reads as the
    /// span of the hitting rather than of the standing about. That is arguably
    /// the more useful number and is certainly not a worse one.
    static func derived(id: UUID, from swings: [SwingDTO]) -> Session? {
        let mine = swings.filter { $0.sessionID == id }.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = mine.first, let last = mine.last else { return nil }
        return Session(id: id,
                       mode: dominantMode(of: mine),
                       startedAt: first.capturedAt,
                       endedAt: last.capturedAt)
    }

    /// Every finished round in the store, newest first.
    static func allDerived(from swings: [SwingDTO]) -> [Session] {
        let ids = Set(swings.compactMap(\.sessionID))
        return ids.compactMap { derived(id: $0, from: swings) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// The mode a round was, read back from what its swings were recorded as.
    ///
    /// Most common rather than first: the setting can be changed mid-round from
    /// the capture screen, and one swing relabelled for a validation run should
    /// not rename the whole round.
    private static func dominantMode(of swings: [SwingDTO]) -> SessionMode {
        var tally: [SessionMode: Int] = [:]
        for s in swings { tally[SessionMode(setting: s.setting), default: 0] += 1 }
        return tally.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue
        }?.key ?? .live
    }
}

/// How the ball is being delivered. This is the first thing the app asks,
/// because it is the one thing it cannot work out for itself and it changes
/// what the analysis should expect.
///
/// A deliberately short list. `SwingSetting` carries seven cases, but four of
/// them exist for the validation protocol — "tee, repeatability", "cage through
/// net", "fly ball, ground truth" — and putting those in front of a hitter on a
/// field is asking them to answer a question about a document they have not
/// read. Those stay reachable from Settings; this is the field list.
enum SessionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, toss, tee

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live pitching"
        case .toss: return "Soft toss"
        case .tee:  return "Tee"
        }
    }

    var blurb: String {
        switch self {
        case .live: return "Someone is pitching to you."
        case .toss: return "Someone is tossing the ball in."
        case .tee:  return "The ball starts still."
        }
    }

    var symbol: String {
        switch self {
        case .live: return "figure.baseball"
        case .toss: return "hand.raised"
        case .tee:  return "cone"
        }
    }

    /// Back the other way, for rebuilding a finished round from its swings.
    ///
    /// The four validation settings have no field mode of their own — they are
    /// not offered on the start screen — so they fold into the nearest one. A
    /// round is being named here, not a measurement described; each swing keeps
    /// its own exact `SwingSetting` either way.
    init(setting: SwingSetting) {
        switch setting {
        case .tee, .teeid: self = .tee
        case .toss:        self = .toss
        case .live, .cage, .net, .fly: self = .live
        }
    }

    /// The stored `SwingSetting`, so sessions and the validation protocol keep
    /// using one vocabulary and clips still drop into `spike/batch_run.py`.
    var swingSetting: SwingSetting {
        switch self {
        case .live: return .live
        case .toss: return .toss
        case .tee:  return .tee
        }
    }

}

/// What a finished round comes to.
///
/// Built at the end rather than accumulated during, so that a swing whose
/// analysis lands late still counts, and so the confident/withheld split is
/// decided once against a complete set instead of drifting as clips arrive.
struct SessionSummary: Identifiable, Equatable, Sendable {
    /// The round's own id — the summary IS the round, so `.sheet(item:)` keys
    /// off it directly rather than needing a wrapper.
    var id: UUID { session.id }
    var session: Session
    /// Swings the app will stand behind: clean measurement, taken in conditions
    /// worth trusting. These are what the hitter is shown.
    var confident: [SwingDTO]
    /// Measured, but with something attached that says do not lean on it.
    /// Reachable, never mixed in with the others — that mixing is exactly what
    /// `docs/BIOMECHANICS.md` forbids.
    var flagged: [SwingDTO]

    var total: Int { confident.count + flagged.count }

    var bestExitVeloMph: Double? { confident.map(\.exitVeloMph).max() }

    var medianLaunchAngleDeg: Double? {
        let xs = confident.map(\.launchAngleDeg).sorted()
        guard !xs.isEmpty else { return nil }
        return xs[xs.count / 2]
    }

    /// Swings whose launch angle sat in the slow-pitch line-drive band.
    ///
    /// Counted against the band from `sla_common.py`, which is coaching
    /// guidance rather than a measured population norm — there are no published
    /// slow-pitch swing-kinematics norms to score against. Shown as a count,
    /// never as a grade.
    var inLaunchWindow: Int {
        confident.filter {
            $0.launchAngleDeg >= SLA.slowpitchLaunchLo
                && $0.launchAngleDeg <= SLA.slowpitchLaunchHi
        }.count
    }

    /// Nothing to show and a reason why. The empty state carries the whole
    /// message when a round produced no usable swing, which on unproven
    /// footage is a likely outcome and must not read as "you hit nothing".
    var isEmpty: Bool { total == 0 }

    static func build(session: Session, swings: [SwingDTO]) -> SessionSummary {
        let mine = swings
            .filter { $0.sessionID == session.id }
            .sorted { $0.capturedAt < $1.capturedAt }
        return SessionSummary(session: session,
                              confident: mine.filter(\.highConfidence),
                              flagged: mine.filter { !$0.highConfidence })
    }
}
