// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Charts
import SwiftUI

struct TrendsView: View {
    /// Shown as a sheet from the start screen and as a tab inside a round.
    /// A sheet needs a way out and a tab must not have one — this is set by
    /// the caller rather than read from the environment, because a screen
    /// PUSHED inside a sheet also counts as presented, and would then offer a
    /// Done button that closed the sheet it was pushed from.
    var isModal = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var setting: SwingSetting?
    @State private var highConfidenceOnly = true

    private var swings: [SwingDTO] {
        model.swings
            .filter { $0.trackedFrames > 0 }
            .filter { setting == nil || $0.setting == setting }
            .filter { !highConfidenceOnly || $0.highConfidence }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if swings.count < 2 {
                    ContentUnavailableView(
                        "Not enough swings",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Trends need at least two tracked swings. Turn off the high-confidence filter to include flagged readings.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Trends")
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.bold)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All settings") { setting = nil }
                        ForEach(SwingSetting.allCases) { s in
                            Button(s.displayName) { setting = s }
                        }
                    } label: {
                        Label(setting?.displayName ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private var content: some View {
        List {
            Section {
                Toggle("High-confidence swings only", isOn: $highConfidenceOnly)
                Text("Flagged readings can be off by a lot. Including them makes the trend noisier, not richer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Exit velocity") {
                Chart(swings) { swing in
                    PointMark(x: .value("Swing", swing.capturedAt),
                              y: .value(model.settings.speedUnit.suffix, model.settings.speedUnit.fromMph(swing.exitVeloMph)))
                    .foregroundStyle(.blue)
                }
                .frame(height: 180)
                stats(swings.map { model.settings.speedUnit.fromMph($0.exitVeloMph) },
                      unit: model.settings.speedUnit.suffix)
            }

            Section("Launch angle") {
                Chart(swings) { swing in
                    PointMark(x: .value("Swing", swing.capturedAt),
                              y: .value("degrees", swing.launchAngleDeg))
                    .foregroundStyle(.green)
                }
                .frame(height: 180)
                stats(swings.map(\.launchAngleDeg), unit: "°")
            }

            Section("Launch angle vs exit velocity") {
                Chart(swings) { swing in
                    PointMark(x: .value("Launch angle", swing.launchAngleDeg),
                              y: .value("Exit velo", model.settings.speedUnit.fromMph(swing.exitVeloMph)))
                    .foregroundStyle(by: .value("Setting", swing.setting.rawValue))
                }
                .frame(height: 220)
                Text("The shape most worth watching: how hard you hit it against how well you launched it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stats(_ values: [Double], unit: String) -> some View {
        let mean = values.reduce(0, +) / Double(values.count)
        let sd: Double = {
            guard values.count >= 2 else { return 0 }
            let ss = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            return (ss / Double(values.count - 1)).squareRoot()
        }()
        return HStack {
            Text(String(format: "mean %.1f %@", mean, unit))
            Spacer()
            Text(String(format: "sd %.2f %@", sd, unit))
            Spacer()
            Text(String(format: "best %.1f %@", values.max() ?? 0, unit))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
