// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// What the round came to, shown once when it ends.
///
/// The split between what is shown and what is set aside is the whole point of
/// this screen. Mid-round the app records everything and argues about nothing;
/// here, once, the swings it will stand behind are separated from the ones it
/// will not. Putting a flagged reading in the same list as a clean one — same
/// type, same size, no mark — is precisely what `docs/BIOMECHANICS.md` forbids,
/// and a summary is where that temptation is strongest, because a longer list
/// looks like a better session.
struct SessionSummaryView: View {
    let summary: SessionSummary
    var onDone: () -> Void

    @State private var showFlagged = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if summary.isEmpty {
                            emptyState
                        } else {
                            headline
                            swingList
                            if !summary.flagged.isEmpty { flaggedSection }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone).foregroundStyle(Theme.yellow)
                }
            }
        }
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.session.mode.title.uppercased())
                .font(Theme.label(11)).tracking(1.3).foregroundStyle(Theme.steel)
            Text(minutesText)
                .font(.subheadline).foregroundStyle(Theme.steel)
        }
    }

    private var minutesText: String {
        let mins = Int((summary.session.duration / 60).rounded())
        let swings = summary.total
        return "\(swings) swing\(swings == 1 ? "" : "s") over \(max(1, mins)) min"
    }

    /// Deliberately not "0 swings". A round that produced nothing measurable is
    /// far more likely to be the app's failure than the hitter's, and saying so
    /// is both truer and the only thing that leads anywhere useful.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing measured this round")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Either the trigger never heard contact, or it did and no ball track survived. Both are recorded — open Swings and read the report on the most recent clip; it names the stage that failed.")
                .font(.subheadline).foregroundStyle(Theme.steel)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var headline: some View {
        HStack(spacing: 16) {
            MetricTile(label: "Best exit velo",
                       value: summary.bestExitVeloMph.map { String(format: "%.0f", $0) } ?? "—",
                       unit: "mph")
            MetricTile(label: "Median launch",
                       value: summary.medianLaunchAngleDeg.map { String(format: "%.0f", $0) } ?? "—",
                       unit: "°")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomLeading) {
            if !summary.confident.isEmpty {
                Text("\(summary.inLaunchWindow) of \(summary.confident.count) in the \(Int(SLA.slowpitchLaunchLo))–\(Int(SLA.slowpitchLaunchHi))° line-drive band")
                    .font(.caption2).foregroundStyle(Theme.steel)
                    .padding(.leading, 16).padding(.bottom, 6)
            }
        }
    }

    private var swingList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SWINGS WORTH KEEPING")
                .font(Theme.label(11)).tracking(1.3).foregroundStyle(Theme.steel)
            if summary.confident.isEmpty {
                Text("None this round. Every swing that measured carried a warning — they are below.")
                    .font(.caption).foregroundStyle(Theme.steel)
            }
            ForEach(summary.confident) { s in
                NavigationLink { SwingDetailView(swing: s) } label: { row(s) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var flaggedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showFlagged.toggle() }
            } label: {
                HStack {
                    Text("\(summary.flagged.count) SET ASIDE")
                        .font(Theme.label(11)).tracking(1.3)
                    Image(systemName: showFlagged ? "chevron.up" : "chevron.down")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(Theme.warn)
            }
            .buttonStyle(.plain)
            Text("Measured, but with something attached that says do not lean on it.")
                .font(.caption2).foregroundStyle(Theme.steel)
            if showFlagged {
                ForEach(summary.flagged) { s in
                    NavigationLink { SwingDetailView(swing: s) } label: { row(s, dim: true) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ s: SwingDTO, dim: Bool = false) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.0f mph   %+.0f°", s.exitVeloMph, s.launchAngleDeg))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(dim ? Theme.steel : .white)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text(s.capturedAt.formatted(date: .omitted, time: .standard))
                    if let smash = s.smashFactor {
                        Text("· smash \(String(format: "%.2f", smash))")
                    }
                    if s.trackedFrames > 0 { Text("· \(s.trackedFrames) fr") }
                }
                .font(.caption2).foregroundStyle(Theme.steel)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.steel)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
