// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: SwingSetting?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    private var visible: [SwingDTO] {
        guard let filter else { return model.swings }
        return model.swings.filter { $0.setting == filter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.swings.isEmpty {
                    ContentUnavailableView(
                        "No swings yet",
                        systemImage: "figure.baseball",
                        description: Text("Set the camera up on the Capture tab, arm it, and hit. Clips are kept so anything that looks wrong can be re-run later.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Swings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareURLs = model.exportAll()
                        showShare = !shareURLs.isEmpty
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.swings.isEmpty)
                }
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All settings") { filter = nil }
            Divider()
            ForEach(SwingSetting.allCases) { setting in
                let count = model.swings.filter { $0.setting == setting }.count
                Button("\(setting.displayName) (\(count))") { filter = setting }
                    .disabled(count == 0)
            }
        } label: {
            Label(filter?.displayName ?? "All", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var list: some View {
        List {
            ForEach(visible) { swing in
                NavigationLink {
                    SwingDetailView(swing: swing)
                } label: {
                    row(swing)
                }
            }
            .onDelete { offsets in
                for index in offsets { model.delete(visible[index]) }
            }
        }
    }

    private func row(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(swing.clipFilename ?? swing.setting.rawValue)
                    .font(.headline.monospaced())
                Spacer()
                Text(swing.capturedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if swing.trackedFrames == 0 {
                Label("no track", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 16) {
                    Text(String(format: "%.1f°", swing.launchAngleDeg))
                    Text(String(format: "%.1f mph", swing.exitVeloMph))
                    Text("\(swing.trackedFrames)f")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
                ConfidenceRow(flags: swing.flags)
            }
        }
        .padding(.vertical, 2)
    }
}
