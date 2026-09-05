// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Rounds you have already hit, and the way back into one.
///
/// These are not stored records — they are rebuilt from the swings that carry
/// each round's id (see `Session.derived`). That is deliberate: a stored table
/// of rounds is a second copy of the same fact, and it goes out of step the
/// first time a swing is deleted. Here a round IS its swings, so it can never
/// claim a count that is not there.
///
/// Which also means an empty round does not appear. A round that recorded
/// nothing left nothing behind to rebuild it from, and there is nothing to
/// reopen — the honest answer, rather than a row with a zero on it.
struct RoundsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var viewing: SessionSummary?
    /// Rounds a swipe has proposed deleting, held until the dialog answers.
    @State private var doomed: [Session] = []

    private var confirmingDelete: Binding<Bool> {
        Binding(get: { !doomed.isEmpty }, set: { if !$0 { doomed = [] } })
    }

    private var doomedTitle: String {
        guard let first = doomed.first else { return "Delete round?" }
        if doomed.count > 1 { return "Delete \(doomed.count) rounds?" }
        let n = model.swingCount(inRound: first.id)
        return "Delete this round and its \(n) swing\(n == 1 ? "" : "s")?"
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.pastRounds.isEmpty {
                    ContentUnavailableView {
                        Label("No finished rounds", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("A round appears here once it has a swing in it. Rounds are rebuilt from their swings, so one that recorded nothing leaves nothing to come back to.")
                    }
                } else {
                    List {
                        ForEach(model.pastRounds) { round in
                            row(round)
                        }
                        .onDelete { offsets in
                            // Resolve the rounds before deleting: pastRounds is
                            // derived from the swings, so the first delete
                            // rebuilds it and every later index points
                            // somewhere else.
                            doomed = offsets.map { model.pastRounds[$0] }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.black)
                    .confirmationDialog(doomedTitle, isPresented: confirmingDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            for round in doomed { model.deleteRound(id: round.id) }
                            doomed = []
                        }
                        Button("Keep", role: .cancel) { doomed = [] }
                    } message: {
                        Text("A round is its swings — deleting it deletes them and their clips. Nothing here is recoverable afterwards.")
                    }
                }
            }
            .navigationTitle("Past rounds")
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
            .sheet(item: $viewing) { summary in
                SessionSummaryView(summary: summary) { viewing = nil }
                    .environmentObject(model)
            }
            // The summary sheet can reopen a round too. When it does, this
            // screen has to get out of the way — otherwise a live capture
            // session is running underneath a list of finished ones.
            .onChange(of: model.isInSession) { _, inSession in
                if inSession { dismiss() }
            }
        }
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
    }

    private func row(_ round: Session) -> some View {
        let summary = model.summary(for: round)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(round.mode.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(round.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.steel)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(summary.total)")
                        .font(Theme.numeral(22)).foregroundStyle(Theme.yellow)
                    Text(summary.total == 1 ? "swing" : "swings")
                        .font(Theme.label(9)).foregroundStyle(Theme.steel)
                }
            }
            // The same split the summary makes, in one line. A round that is
            // all set-aside readings should say so here rather than looking
            // like a good one until it is opened.
            Text(summary.flagged.isEmpty
                 ? "\(summary.confident.count) worth keeping"
                 : "\(summary.confident.count) worth keeping · \(summary.flagged.count) set aside")
                .font(.caption)
                .foregroundStyle(summary.confident.isEmpty ? Theme.warn : Theme.steel)

            HStack(spacing: 10) {
                Button("Open") { viewing = summary }
                    .buttonStyle(OutlineButtonStyle(verticalPadding: 8))
                Button("Hit into it again") { reopen(round) }
                    .buttonStyle(SlabButtonStyle(size: 13, verticalPadding: 8))
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.surface)
    }

    private func reopen(_ round: Session) {
        model.reopenSession(round)
        dismiss()
    }
}
