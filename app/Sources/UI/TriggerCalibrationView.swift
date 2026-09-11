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
            Text(String(format: "Level above this room's own background, over %.0f kHz",
                        SLA.triggerHighPassHz / 1000))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Text(String(format: "The default %.0f dB is a starting point, not a threshold for any particular place. A quiet garden needs less; a cage needs more. Two steps and it will pick one from what this venue actually sounds like.", SLA.triggerDb))
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
            Text("Done — or hit \(TriggerCalibration.hitsWanted) balls to check it")
                .font(Theme.label(16)).foregroundStyle(Theme.yellow)
            HStack(spacing: 8) {
                ForEach(0..<TriggerCalibration.hitsWanted, id: \.self) { i in
                    Circle()
                        .fill(i < recorded ? Theme.pass : Color.white.opacity(0.18))
                        .frame(width: 16, height: 16)
                }
            }
            Text(recorded == 0
                 ? "The threshold is already set from what this venue sounds like, and you can stop here. Hitting a few tells it how much room there is between the noise and a real hit — worth doing if somebody can hit for you, and not worth waiting for if nobody can."
                 : "Normal swings, not your hardest — the threshold is set from the quietest one, so a soft hit here is worth more than a good one.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Two buttons rather than one with a switched style: `ButtonStyle`
            // has no type-erased box in the standard library, and inventing one
            // to save four lines is not a trade worth making.
            if recorded == 0 {
                Button("Done — nobody to hit") { session.finishEarly() }
                    .buttonStyle(SlabButtonStyle(size: 17))
            } else {
                Button("Use \(recorded) and finish") { session.finishEarly() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private func results(_ r: TriggerCalibration.Result) -> some View {
        VStack(spacing: 14) {
            if let verdict = r.verdict {
                StatChip(text: verdict.label, color: colour(verdict), filled: true)
            } else {
                StatChip(text: "Listened only", color: Theme.steel, filled: false)
            }

            HStack(spacing: 14) {
                MetricTile(label: "Background", value: String(format: "%.0f", r.backgroundPeakDb),
                           unit: "dB", tint: .white)
                if let quietest = r.quietestHitDb {
                    MetricTile(label: "Quietest hit", value: String(format: "%.0f", quietest),
                               unit: "dB", tint: .white)
                }
                MetricTile(label: "Threshold", value: String(format: "%.0f", r.thresholdDb),
                           unit: "dB")
            }

            Text(r.verdict?.advice
                 ?? "Set from the venue's own background, with nobody hitting. That is a threshold, not a verdict: whether this place has room between its noise and a real hit takes a few hits to know, and can be measured any time somebody can hit for you.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button("Use \(Int(r.thresholdDb.rounded())) dB") {
                    model.settings.triggerDb = r.thresholdDb
                    // Stamp the band it was measured in. A threshold without
                    // one cannot be told from a default, and a threshold from
                    // another band is worse than a default — see
                    // `AppSettings.triggerCalibratedBandHz`.
                    model.settings.triggerCalibratedBandHz = SLA.triggerHighPassHz
                    dismiss()
                }
                .buttonStyle(SlabButtonStyle(size: 17))
                Button("Measure again") { session.startBackground() }
                    .buttonStyle(OutlineButtonStyle())
            }

            if let loudest = r.loudestHitDb, let sep = r.separationDb {
                Text(String(format: "%d hits recorded, loudest %.0f dB. Separation %.0f dB.",
                            r.hitCount, loudest, sep))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(String(format: "Background measured over %.0f s. Nothing was hit.",
                            TriggerCalibration.backgroundListenS))
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
