// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// The Phase 0 go/no-go scoreboard, computed from swings on the device.
///
/// Port of the scoreboard in `spike/batch_run.py`, against the thresholds in
/// `docs/VALIDATION.md`. The point of having it here is that the decision can
/// be made standing on the field rather than after a round trip to the Mac —
/// and the numbers it prints are the ones VALIDATION.md asks for.
struct ValidationScoreboard {

    struct G1Row: Identifiable {
        var setting: SwingSetting
        var tracked: Int
        var total: Int
        var threshold: Double?
        var id: String { setting.rawValue }
        var fraction: Double { total > 0 ? Double(tracked) / Double(total) : 0 }
        var passes: Bool? {
            guard let t = threshold, total > 0 else { return nil }
            return fraction >= t
        }
    }

    struct G3Row: Identifiable {
        var id: UUID
        var label: String
        var hangErrorPct: Double?
        var carryErrorPct: Double?
        var hangPasses: Bool?
        var carryPasses: Bool?
    }

    var g1: [G1Row] = []
    var g2MedianPct: Double?
    var g2Count: Int = 0
    var g3: [G3Row] = []
    var g4EvSd: Double?
    var g4LaSd: Double?
    var g4Count: Int = 0
    var g5AutoTriggered: Int = 0
    var g5Total: Int = 0

    var g2Passes: Bool? { g2MedianPct.map { $0 <= SLA.scaleDisagreeTol * 100 } }
    var g4EvPasses: Bool? { g4EvSd.map { $0 <= 3.0 } }
    var g4LaPasses: Bool? { g4LaSd.map { $0 <= 3.0 } }
    var g5Fraction: Double? { g5Total > 0 ? Double(g5AutoTriggered) / Double(g5Total) : nil }
    var g5Passes: Bool? { g5Fraction.map { $0 >= 0.90 } }

    func g1Passes(_ setting: SwingSetting) -> Bool? {
        g1.first { $0.setting == setting }?.passes
    }

    /// The decision rule at the bottom of `docs/VALIDATION.md`.
    enum Verdict: String {
        case go = "GO"
        case goOutdoorOnly = "GO — outdoor only"
        case noGo = "NO-GO"
        case notEnoughData = "Not enough data yet"
    }

    var verdict: Verdict {
        guard let teeG1 = g1Passes(.tee), let g2 = g2Passes,
              let evOK = g4EvPasses, let laOK = g4LaPasses else {
            return .notEnoughData
        }
        // "G1(tee) fails -> full stop" — no other result can rescue it.
        if !teeG1 { return .noGo }
        guard g2, evOK, laOK else { return .noGo }
        // Cage failing demotes it to capture+replay; the outdoor path proceeds.
        if let cage = g1Passes(.cage), !cage { return .goOutdoorOnly }
        return .go
    }

    var verdictExplanation: String {
        switch verdict {
        case .notEnoughData:
            return "Needs outdoor tee clips, at least three teeid_ swings, and enough tracked flight for the gravity cross-check."
        case .noGo:
            if g1Passes(.tee) == false {
                return "Outdoor tee trackability failed. Per the decision rule this is a full stop — rethink capture (shorter distance, brighter ball, cleaner background) before any more app work."
            }
            return "Trackability holds but the accuracy gates do not. Check scale agreement and repeatability before trusting any number."
        case .goOutdoorOnly:
            return "Outdoor path is good. The cage did not reach 70% trackability, so it is capture-and-replay only — a documented limitation, not a blocker."
        case .go:
            return "All three deciding gates pass. Phases 1-2 are cleared."
        }
    }

    /// Through-the-net clips are expected to fail and are not a blocker; they
    /// exist so the failure is documented rather than discovered later.
    static func build(from swings: [SwingDTO]) -> ValidationScoreboard {
        var board = ValidationScoreboard()

        // G1 — trackability, per setting.
        for setting in SwingSetting.allCases {
            let rows = swings.filter { $0.setting == setting }
            guard !rows.isEmpty else { continue }
            board.g1.append(G1Row(setting: setting,
                                  tracked: rows.filter(\.meetsG1).count,
                                  total: rows.count,
                                  threshold: setting.g1Threshold))
        }

        // G2 — median scale disagreement across outdoor clips that produced a
        // gravity cross-check at all.
        let disagreements = swings
            .filter { $0.setting.isOutdoor }
            .compactMap { $0.scaleDisagreement }
            .map { $0 * 100 }
        board.g2Count = disagreements.count
        if !disagreements.isEmpty {
            let sorted = disagreements.sorted()
            let n = sorted.count
            board.g2MedianPct = n % 2 == 1
                ? sorted[n / 2]
                : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }

        // G3 — fly balls with hand-measured hang time and carry.
        for swing in swings where swing.hangS != nil || swing.carryFt != nil {
            let check = FlightModel.check(
                metrics: SwingMetrics(launchAngleDeg: swing.launchAngleDeg,
                                      exitVeloMph: swing.exitVeloMph,
                                      exitVeloMps: swing.exitVeloMps,
                                      scaleBallMPerPx: swing.scaleBallMPerPx,
                                      scaleGravityMPerPx: swing.scaleGravityMPerPx,
                                      scaleDisagreement: swing.scaleDisagreement,
                                      diameterDrift: swing.diameterDrift,
                                      nFrames: swing.trackedFrames,
                                      trackDurationS: swing.trackDurationS,
                                      fitRmsPx: swing.fitRmsPx,
                                      t0: swing.contactTime,
                                      vxPxS: 0, vyPxS: 0,
                                      flags: swing.flags),
                hangS: swing.hangS,
                carryFt: swing.carryFt)
            board.g3.append(G3Row(id: swing.id,
                                  label: swing.clipFilename ?? "swing",
                                  hangErrorPct: check.hangErrorPct,
                                  carryErrorPct: check.carryErrorPct,
                                  hangPasses: check.hangPasses,
                                  carryPasses: check.carryPasses))
        }

        // G4 — repeatability over the five identical-intent tee swings.
        let ident = swings.filter { $0.setting == .teeid && $0.trackedFrames > 0 }
        board.g4Count = ident.count
        if ident.count >= 3 {
            board.g4EvSd = sampleStdDev(ident.map(\.exitVeloMph))
            board.g4LaSd = sampleStdDev(ident.map(\.launchAngleDeg))
        }

        // G5 — how often the audio trigger fired on its own.
        board.g5Total = swings.count
        board.g5AutoTriggered = swings.filter(\.autoTriggered).count

        return board
    }

    /// Sample standard deviation (ddof = 1), matching `np.std(..., ddof=1)`.
    private static func sampleStdDev(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let ss = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
