// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// Pick three frames out of a clip and get them off the phone.
///
/// A scrubber rather than three automatic picks, because the useful frames are
/// the ones only the person who filmed it can find: the ball sitting where it
/// gets tapped, one mid-flight, one with the hitter in shot. The detector
/// cannot locate them — if it could, none of this would be needed.
///
/// Three evenly spaced times are pre-loaded so there is always something to
/// send, and each can be replaced by scrubbing to a better one.
struct FramePickerView: View {
    let clipURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var durationS: Double = 0
    @State private var scrubS: Double = 0
    @State private var preview: UIImage?
    @State private var picks: [Double] = []
    @State private var exported: [URL] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showShare = false

    /// Reused across scrubs. Building one per seek is the difference between a
    /// slider that tracks the finger and one that stutters.
    @State private var generator: AVAssetImageGenerator?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    guidance
                    previewImage
                    scrubber
                    pickList
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Theme.fail)
                    }
                }
                .padding()
            }
            .background(Theme.black)
            .navigationTitle("Export frames")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { exportBar }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
            .task { await load() }
            .sheet(isPresented: $showShare) { ShareSheet(items: exported) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Three frames worth having")
                .font(Theme.label(13)).foregroundStyle(Theme.yellow)
            Text("1 · the ball sitting where you would tap it, at filming distance\n2 · the ball mid-flight, blurred, against the real background\n3 · the hitter in shot")
                .font(.caption).foregroundStyle(.secondary)
            Text("Full resolution PNG, so the colour is exactly what the camera recorded. A screenshot is screen-sized and re-compressed, which moves the very hues being measured.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var previewImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Theme.surface)
            if let preview {
                Image(uiImage: preview)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().tint(Theme.yellow)
            }
        }
        .frame(height: 220)
    }

    @State private var previewRefresh: Task<Void, Never>?

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: $scrubS, in: 0...max(0.01, durationS))
                .tint(Theme.yellow)
                // Debounced from the VALUE, not from a parallel drag gesture.
                // The gesture needed 10 pt of travel to register, so a small
                // nudge — or any accessibility adjustment — moved the time
                // readout while the picture stayed on the previous frame, and
                // "Use current" banked a time whose frame was never shown, on
                // the tool that exists to pick exact frames. Cancel-and-restart
                // keeps it to one decode per pause instead of one per tick.
                .onChange(of: scrubS) { _, _ in
                    previewRefresh?.cancel()
                    previewRefresh = Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { return }
                        await refreshPreview()
                    }
                }
            HStack {
                Text(String(format: "%.2f s", scrubS))
                Spacer()
                Text(String(format: "of %.1f s", durationS))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Step −1 frame") { step(-1) }
                Button("Step +1 frame") { step(+1) }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .tint(Theme.yellow)
        }
    }

    private var pickList: some View {
        VStack(spacing: 8) {
            ForEach(Array(picks.enumerated()), id: \.offset) { i, t in
                HStack {
                    Text("Frame \(i + 1)").font(Theme.label(12))
                    Spacer()
                    Text(String(format: "%.2f s", t))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Use current") { picks[i] = scrubS }
                        .font(.caption).buttonStyle(.bordered).tint(Theme.yellow)
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var exportBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await exportAll() }
            } label: {
                Text(busy ? "Exporting…" : "Export \(picks.count) frames")
            }
            .buttonStyle(SlabButtonStyle(size: 16))
            .disabled(busy || picks.isEmpty)

            if !exported.isEmpty {
                Button {
                    showShare = true
                } label: {
                    Label("Share \(exported.count) PNGs", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Work

    private func load() async {
        durationS = await FrameExporter.duration(of: clipURL)
        picks = FrameExporter.defaultTimes(durationS: durationS)
        scrubS = picks.first ?? 0

        // Through the shared factory, so the exact-seek contract lives in
        // one place instead of being a convention every screen re-types.
        let g = FrameExporter.exactSeekGenerator(for: AVURLAsset(url: clipURL))
        // The preview only has to be looked at, so it is capped — decoding a
        // full 1080p frame for a thumbnail on every scrub is wasted work. The
        // exported files are not capped.
        g.maximumSize = CGSize(width: 900, height: 900)
        generator = g
        await refreshPreview()
    }

    /// One frame at 240fps, or a sensible nudge when the rate is unknown.
    private func step(_ direction: Double) {
        scrubS = min(max(0, scrubS + direction / 240.0), durationS)
        Task { await refreshPreview() }
    }

    private func refreshPreview() async {
        guard let generator else { return }
        let time = CMTime(seconds: scrubS, preferredTimescale: 600)
        do {
            let cg = try await generator.image(at: time).image
            preview = UIImage(cgImage: cg)
            error = nil
        } catch {
            // Worth saying rather than showing a blank box: on this app the
            // usual cause is the camera still holding the hardware decoder.
            self.error = "Could not decode that frame: \(error.localizedDescription)"
        }
    }

    private func exportAll() async {
        busy = true
        defer { busy = false }
        FrameExporter.clearPreviousFrames()
        do {
            let name = clipURL.deletingPathExtension().lastPathComponent
            exported = try await FrameExporter.extract(from: clipURL, at: picks,
                                                       namePrefix: name)
            error = exported.isEmpty ? "Nothing was exported." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
