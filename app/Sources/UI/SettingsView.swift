import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ball colour") {
                    hsvEditor(title: "Lower bound",
                              bounds: $model.settings.detector.hsvLo)
                    hsvEditor(title: "Upper bound",
                              bounds: $model.settings.detector.hsvHi)
                    Text("OpenCV HSV convention (H 0-179), identical to track_ball.py's --hsv-lo/--hsv-hi. A range tuned on the Mac can be typed straight in here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Ball size") {
                    stepper("Minimum radius", value: $model.settings.detector.minRadiusPx,
                            range: 2...30, step: 0.5, unit: "px")
                    stepper("Maximum radius", value: $model.settings.detector.maxRadiusPx,
                            range: 10...120, step: 1, unit: "px")
                }

                Section("Trigger") {
                    stepper("Threshold over noise floor", value: $model.settings.triggerDb,
                            range: 6...30, step: 1, unit: "dB")
                    stepper("Pre-roll", value: $model.settings.preRollS,
                            range: 0.25...2.0, step: 0.25, unit: "s")
                    stepper("Post-roll", value: $model.settings.postRollS,
                            range: 0.5...3.0, step: 0.25, unit: "s")
                    Text("Pre-roll has to cover the bat's approach — that footage is what the attack angle is measured from.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Analysis") {
                    Toggle("Track the bat", isOn: $model.settings.trackBat)
                    Toggle("Skip Vision, use the reference detector only",
                           isOn: $model.settings.forceFallbackDetector)
                    Picker("Hit direction", selection: $model.settings.direction) {
                        ForEach(TrackBuilder.Direction.allCases, id: \.self) { d in
                            Text(d.rawValue.capitalized).tag(d)
                        }
                    }
                    Text("Direction only matters when an inbound pitch is also in frame. Auto takes the fastest track.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Storage") {
                    Toggle("Keep clips after analysis", isOn: $model.settings.keepClips)
                    HStack {
                        Text("Clips on device")
                        Spacer()
                        Text(byteText(ClipStore.totalClipBytes()))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("Keeping clips is what makes a suspicious reading recoverable — the Python pipeline can be pointed at the same footage. 240fps fills a phone quickly, so watch this number.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Reference") {
                    LabeledContent("Ball diameter",
                                   value: String(format: "%.2f in", SLA.ballDiameterM * 39.3701))
                    LabeledContent("Ball mass", value: String(format: "%.0f g", SLA.ballMassKg * 1000))
                    LabeledContent("Drag Cd", value: String(format: "%.2f", SLA.dragCd))
                    LabeledContent("Scale tolerance",
                                   value: String(format: "%.0f%%", SLA.scaleDisagreeTol * 100))
                    Text("These match spike/sla_common.py, and the unit tests fail if they drift apart.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset settings to defaults") {
                        model.settings = AppSettings()
                    }
                    Button("Delete all swings", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete every stored swing and clip?",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    for swing in model.swings { model.delete(swing) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the measurements and the footage behind them. Export first if the session has not been copied off the phone.")
            }
        }
    }

    private func hsvEditor(title: String, bounds: Binding<HSVBounds>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            slider("H", bounds.h, range: 0...179)
            slider("S", bounds.s, range: 0...255)
            slider("V", bounds.v, range: 0...255)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).frame(width: 16)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))")
                .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }

    private func stepper(_ label: String, value: Binding<Double>,
                         range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(formatted(value.wrappedValue)) \(unit)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func formatted(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
