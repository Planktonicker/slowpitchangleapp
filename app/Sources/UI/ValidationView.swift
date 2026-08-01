// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// `docs/VALIDATION.md`, computed live from what has been captured.
///
/// The whole point of Phase 0 is the go/no-go call, and it is much easier to
/// make while still standing at the field with the tripod up.
struct ValidationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    private var board: ValidationScoreboard { model.scoreboard }

    var body: some View {
        NavigationStack {
            List {
                verdictSection
                g1Section
                g2Section
                g3Section
                g4Section
                g5Section
            }
            .navigationTitle("Validation")
            .scrollContentBackground(.hidden)
            .background(Theme.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = try? CSVExport.write(
                            CSVExport.scoreboardText(board),
                            filename: "validation_scoreboard.txt") {
                            shareURLs = [url]
                            showShare = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        }
    }

    private var verdictSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(board.verdict.rawValue)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(verdictColour)
                Text(board.verdictExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Verdict")
        } footer: {
            Text("Decision rule from docs/VALIDATION.md: outdoor tee trackability, scale agreement and repeatability decide it. A cage failure demotes the cage; through-the-net failing is expected and blocks nothing.")
        }
    }

    private var verdictColour: Color {
        switch board.verdict {
        case .go: return .green
        case .goOutdoorOnly: return .yellow
        case .noGo: return .red
        case .notEnoughData: return .secondary
        }
    }

    private var g1Section: some View {
        Section {
            if board.g1.isEmpty {
                Text("No swings captured yet.").foregroundStyle(.secondary)
            }
            ForEach(board.g1) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.setting.displayName).font(.callout)
                        Text(row.setting.blurb).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(row.tracked)/\(row.total)")
                        .font(.callout.monospacedDigit())
                    Text(String(format: "%.0f%%", row.fraction * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    GateBadge(passes: row.passes)
                }
            }
        } header: {
            Text("G1 — trackability")
        } footer: {
            Text("A clip counts when the ball was tracked for 12 or more frames after contact. Clips where tracking failed are counted too — leaving them out would flatter this number.")
        }
    }

    private var g2Section: some View {
        Section {
            HStack {
                Text("Median disagreement")
                Spacer()
                Text(board.g2MedianPct.map { String(format: "%.1f%%", $0) } ?? "—")
                    .monospacedDigit()
                GateBadge(passes: board.g2Passes)
            }
            Text("\(board.g2Count) outdoor clips produced a gravity cross-check.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("G2 — scale agreement")
        } footer: {
            Text("Ball-size scale against drag-aware gravity scale. Tolerance 8%. This is the check that stands in for a radar gun.")
        }
    }

    private var g3Section: some View {
        Section {
            if board.g3.isEmpty {
                Text("Enter hang time and paced carry on a fly ball to fill this in.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(board.g3) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label).font(.callout.monospaced())
                    HStack {
                        Text("hang \(row.hangErrorPct.map { String(format: "%+.1f%%", $0) } ?? "—")")
                        GateBadge(passes: row.hangPasses)
                        Spacer()
                        Text("carry \(row.carryErrorPct.map { String(format: "%+.1f%%", $0) } ?? "—")")
                        GateBadge(passes: row.carryPasses)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        } header: {
            Text("G3 — fly-ball physics")
        } footer: {
            Text("Tolerances ±15% on hang and ±20% on carry. Failing G3 does not stop the project; it means exit velocity is labelled relative until resolved.")
        }
    }

    private var g4Section: some View {
        Section {
            HStack {
                Text("Exit velocity spread")
                Spacer()
                Text(board.g4EvSd.map { String(format: "%.2f mph", $0) } ?? "—").monospacedDigit()
                GateBadge(passes: board.g4EvPasses)
            }
            HStack {
                Text("Launch angle spread")
                Spacer()
                Text(board.g4LaSd.map { String(format: "%.2f°", $0) } ?? "—").monospacedDigit()
                GateBadge(passes: board.g4LaPasses)
            }
            Text("\(board.g4Count) identical-intent tee swings recorded (need at least 3, ideally 5).")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("G4 — repeatability")
        } footer: {
            Text("Five swings where you try to hit the same mid-height line drive, captured under the \"Tee (repeatability)\" setting. Thresholds: 3 mph and 3°.")
        }
    }

    private var g5Section: some View {
        Section {
            HStack {
                Text("Auto-triggered")
                Spacer()
                Text("\(board.g5AutoTriggered)/\(board.g5Total)").monospacedDigit()
                GateBadge(passes: board.g5Passes)
            }
        } header: {
            Text("G5 — audio trigger")
        } footer: {
            Text("The app fires on the same 15 dB-over-floor impulse check_audio_trigger.py measures, so how often it triggered by itself is the G5 number. Needs 90%.")
        }
    }
}
