// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: SwingSetting?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var showImporter = false
    @State private var showPhotoPicker = false
    @State private var showDiagnostics = false

    private var visible: [SwingDTO] {
        guard let filter else { return model.swings }
        return model.swings.filter { $0.setting == filter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.swings.isEmpty {
                    ContentUnavailableView {
                        Label("No swings yet", systemImage: "figure.baseball")
                    } description: {
                        Text("Set the camera up on the Capture tab, arm it, and hit. Clips are kept so anything that looks wrong can be re-run later.")
                    } actions: {
                        Button("Import from Photos") { showPhotoPicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Swings")
            .scrollContentBackground(.hidden)
            .background(Theme.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Photos first, and it is not a preference. The
                        // document picker cannot reach the original recording:
                        // it renders slow motion down to 30fps on the way out,
                        // and a 240fps clip measured as 30fps is wrong by a
                        // factor of eight with nothing downstream able to tell.
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("From Photos (keeps 240fps)", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(model.analysisProgress != nil)
                }
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
            // `.movie` rather than `.video`: `.video` also matches things with
            // no video track worth reading, and every failure here costs a
            // whole analysis pass to discover.
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.importClip(from: url) }
                case .failure(let error):
                    model.banner = AppModel.Banner(kind: .error, text: error.localizedDescription)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoClipPicker { result in
                    switch result {
                    case .success(let url): model.importCopiedClip(at: url)
                    case .failure(let error):
                        model.banner = AppModel.Banner(kind: .error,
                                                       text: error.localizedDescription)
                    }
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .bottom) { importProgress }
            .onChange(of: model.lastDiagnostics) { _, report in
                // Opened automatically. A report nobody looks at is the same as
                // no report, and the moment it is worth reading is the moment
                // the import just finished — especially when it found nothing.
                showDiagnostics = report != nil
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(report: model.lastDiagnostics ?? "",
                                clipURL: model.lastImportedClip)
            }
        }
    }

    /// Import is slow — three decode passes over a 240fps clip — and it happens
    /// on a screen with nothing else moving, so without this the app looks
    /// frozen and the user picks a second file on top of the first.
    @ViewBuilder private var importProgress: some View {
        if let progress = model.analysisProgress {
            VStack(spacing: 6) {
                Text("Measuring the clip…")
                    .font(.system(size: 13, weight: .bold))
                ProgressView(value: progress).tint(Theme.yellow)
                Text("Three passes at 240 fps. A few seconds per second of footage.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding()
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
                // Resolve rows before deleting anything: `visible` is a
                // computed filter, so deleting inside the loop shifts every
                // later index onto the wrong swing.
                let doomed = offsets.map { visible[$0] }
                for swing in doomed { model.delete(swing) }
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
                    Text("\(model.settings.speedUnit.format(mph: swing.exitVeloMph)) \(model.settings.speedUnit.suffix)")
                    Text("\(swing.trackedFrames)f")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
                ConfidenceRow(flags: swing.flags, captureFlags: swing.captureFlags)
            }
        }
        .padding(.vertical, 2)
    }
}
