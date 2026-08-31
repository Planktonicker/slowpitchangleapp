// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Two steps: listen to the venue, then hit into it.
///
/// The result screen shows the two measured numbers as well as the threshold,
/// because the threshold on its own is unfalsifiable — "18 dB" tells the user
/// nothing about whether to trust it, while "background peaked at 10, your
/// quietest hit was 24" tells them exactly how much room there is.
struct TriggerCalibrationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var capture: CaptureController
    @StateObject private var session = TriggerCalibration()
    @Environment(\.dismiss) private var dismiss

    /// Drives the countdown and banks a hit when the room goes quiet, which the
    /// level stream alone cannot do — it stops changing.
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                meter
                Group {
                    switch session.phase {
                    case .idle:            intro
                    case .background(let remaining): listening(remaining)
                    case .hits(let n):     hitting(n)
                    case .done(let r):     results(r)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.black)
            .navigationTitle("Calibrate the trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { session.cancel(); dismiss() }
                }
            }
            .onReceive(tick) { _ in session.tick() }
            .onChange(of: capture.triggerLevelDb) { _, db in session.ingest(db: db) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var meter: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f dB", max(0, session.currentDb)))
                .font(Theme.numeral(44))
                .monospacedDigit()
                .foregroundStyle(Theme.yellow)
            SeamMeter(db: session.currentDb, thresholdDb: model.settings.triggerDb)
            Text("Level above this room's own background")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Text("The default 20 dB is a starting point, not a threshold for any particular place. A quiet garden needs less; a cage needs more. Two steps and it will pick one from what this venue actually sounds like.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start — stay quiet") { session.startBackground() }
                .buttonStyle(SlabButtonStyle(size: 17))
        }
    }

    private func listening(_ remaining: Double) -> some View {
        VStack(spacing: 10) {
            Text("Listening…").font(Theme.label(16)).foregroundStyle(Theme.yellow)
            Text(String(format: "%.0f", max(0, remaining.rounded(.up))))
                .font(Theme.numeral(52)).monospacedDigit()
            Text("Leave it running and don't hit anything. It is looking for the loudest the background gets, not the average — one passing car is what causes a false trigger.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func hitting(_ recorded: Int) -> some View {
        VStack(spacing: 12) {
            Text("Now hit \(TriggerCalibration.hitsWanted) balls")
                .font(Theme.label(16)).foregroundStyle(Theme.yellow)
            HStack(spacing: 8) {
                ForEach(0..<TriggerCalibration.hitsWanted, id: \.self) { i in
                    Circle()
                        .fill(i < recorded ? Theme.pass : Color.white.opacity(0.18))
                        .frame(width: 16, height: 16)
                }
            }
            Text("Normal swings, not your hardest — the threshold is set from the quietest one, so a soft hit here is worth more than a good one.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if recorded > 0 {
                Button("Use \(recorded) and finish") { session.finishEarly() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private func results(_ r: TriggerCalibration.Result) -> some View {
        VStack(spacing: 14) {
            StatChip(text: r.verdict.label, color: colour(r.verdict), filled: true)

            HStack(spacing: 14) {
                MetricTile(label: "Background", value: String(format: "%.0f", r.backgroundPeakDb),
                           unit: "dB", tint: .white)
                MetricTile(label: "Quietest hit", value: String(format: "%.0f", r.quietestHitDb),
                           unit: "dB", tint: .white)
                MetricTile(label: "Threshold", value: String(format: "%.0f", r.thresholdDb),
                           unit: "dB")
            }

            Text(r.verdict.advice)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button("Use \(Int(r.thresholdDb.rounded())) dB") {
                    model.settings.triggerDb = r.thresholdDb
                    dismiss()
                }
                .buttonStyle(SlabButtonStyle(size: 17))
                Button("Measure again") { session.startBackground() }
                    .buttonStyle(OutlineButtonStyle())
            }

            Text(String(format: "%d hits recorded, loudest %.0f dB. Separation %.0f dB.",
                        r.hitCount, r.loudestHitDb, r.separationDb))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func colour(_ v: TriggerCalibrationVerdict) -> Color {
        switch v {
        case .good: return Theme.pass
        case .marginal: return Theme.warn
        case .unusable: return Theme.fail
        }
    }
}
