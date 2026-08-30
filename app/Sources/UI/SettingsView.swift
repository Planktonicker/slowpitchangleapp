// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showTriggerCalibration = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ball colour") {
                    hsvEditor(title: "Lower bound",
                              bounds: $model.settings.detector.hsvLo)
                    hsvEditor(title: "Upper bound",
                              bounds: $model.settings.detector.hsvHi)
                    Text("OpenCV HSV convention (H 0-179), identical to track_ball.py's --hsv-lo/--hsv-hi. The defaults reject grass, which shares the ball's hue but not its saturation — if a venue still finds the lawn instead of the ball, raise the lower S before touching anything else.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Ball size") {
                    stepper("Minimum radius", value: $model.settings.detector.minRadiusPx,
                            range: 2...30, step: 0.5, unit: "px")
                    stepper("Maximum radius", value: $model.settings.detector.maxRadiusPx,
                            range: 10...250, step: 1, unit: "px")
                    Text("Raise the maximum if you film close in — a ball a few feet from the lens can be well over 120 px across, and anything bigger than this is thrown away.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Trigger") {
                    Toggle("Only trigger with a person in frame", isOn: $model.settings.requireHitter)
                    Text("Uses on-device body-pose detection to ignore bangs and rattles when nobody is at the plate. Suppressed noises are counted on the capture screen. Manual capture always works.")
                        .font(.caption).foregroundStyle(.secondary)
                    stepper("Threshold over noise floor", value: $model.settings.triggerDb,
                            range: 6...30, step: 1, unit: "dB")
                    Button("Calibrate at this venue") { showTriggerCalibration = true }
                    Text("15 dB is the pass/fail gate the validation uses, not a good working threshold for any particular place — too high for a quiet garden, too low for a cage. Calibrating listens to the background, records a few real hits, and puts the number between them. It also says when no threshold can work here, which is worth knowing before a session rather than after.")
                        .font(.caption).foregroundStyle(.secondary)
                    stepper("Pre-roll", value: $model.settings.preRollS,
                            range: 0.25...SLA.maxPreRollS, step: 0.25, unit: "s")
                    stepper("Post-roll", value: $model.settings.postRollS,
                            range: 0.5...3.0, step: 0.25, unit: "s")
                    Text("Pre-roll covers the swing, not just the barrel: load and stride are what the body numbers are measured from, and the incoming pitch is what confirms the contact instant — the pitch and hit paths cross within a few milliseconds of each other, which is tighter than the audio gets. Post-roll only has to outlast the ball's time in frame, which on real clips is under a fifth of a second; past that it is 240 frames a second of an empty field.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Analysis") {
                    // No "track the bat" switch. The bat is tracked whenever
                    // tape is on it and reported only when it was, which is a
                    // question the app can answer for itself — see
                    // `ClipAnalyzer`. Asking the hitter to remember a toggle
                    // buys nothing and silently costs them the bat panel on
                    // every clip they forget it.
                    Toggle("Track the hitter's body", isOn: $model.settings.trackBody)
                    Text("Adds stride, head movement, weight shift, front-knee angle and spine tilt — the sagittal-plane measurements a side-on camera makes honestly. It is a third pass over each clip, so turn it off if the phone is running hot.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Skip Vision, use the reference detector only",
                           isOn: $model.settings.forceFallbackDetector)
                    Picker("Hit direction", selection: $model.settings.direction) {
                        ForEach(TrackBuilder.Direction.allCases, id: \.self) { d in
                            Text(d.rawValue.capitalized).tag(d)
                        }
                    }
                    Text("Which way the HIT ball crosses the frame. It matters because an inbound slow-pitch is a perfectly good track — straight, and fast enough to clear every other filter — that happens to cross the frame the other way. \"Auto\" works it out from which side the hitter stands on in the setup screen, so check that toggle is right before overriding this by hand.")
                        .font(.caption).foregroundStyle(.secondary)
                    // A free number, not a menu of four. Real footage is not
                    // limited to the round rates a picker can list — the first
                    // clip this app was given was 198.94 fps, which no preset
                    // could express, and picking "200" from a list would have
                    // been a half-percent error presented as a choice.
                    Toggle("Override imported clip frame rate", isOn: Binding(
                        get: { model.settings.fpsOverride != nil },
                        set: { model.settings.fpsOverride = $0 ? 240 : nil }))
                    if model.settings.fpsOverride != nil {
                        HStack {
                            Text("Frames per second")
                            Spacer()
                            TextField("240", value: Binding(
                                get: { model.settings.fpsOverride ?? 240 },
                                set: { model.settings.fpsOverride = max(1, min(1000, $0)) }),
                                      format: .number.precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                        }
                    }
                    stepper("Imported clip lens (FOV)", value: $model.settings.importFovDeg,
                            range: 40...120, step: 1, unit: "°")
                    Text("A clip this app filmed knows its own lens. One from the stock Camera app does not, and without a field of view there is no focal length — which means camera tilt cannot be undone at all, since the correction needs both. 68° is the main wide camera on recent iPhones; use about 100° for the 0.5× ultra-wide and about 40° for the 2× or 3×. Getting it roughly right is what matters.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Leave this OFF. The frame rate is measured from the clip's own frame timing, which is right for any rate — 240, 200, 198.94 — and does not care what the file's metadata claims. Turn it on only if a diagnostics report shows a measured rate you know to be wrong, which means the footage was re-timed after recording. Exit velocity scales directly with frame rate, so a wrong number here is a wrong speed by exactly the same factor.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Units") {
                    Picker("Speed", selection: $model.settings.speedUnit) {
                        ForEach(SpeedUnit.allCases, id: \.self) { u in
                            Text(u.displayName).tag(u)
                        }
                    }
                    Text("Distances, sizes and offsets are always metric. Speed is offered in both because every published exit-velocity and bat-speed benchmark for the sport is in mph.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Camera orientation") {
                    Picker("Vision orientation", selection: $model.settings.visionOrientation) {
                        ForEach(VisionOrientationSetting.allCases, id: \.self) { o in
                            Text(o.displayName).tag(o)
                        }
                    }
                    Text("Which way is up in the frames the hitter-detector sees. Auto follows the phone and is almost always right — change it only if \"Hitter in frame\" never lights up with someone clearly in shot.")
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
                    LabeledContent("Ball diameter", value: Fmt.cm(SLA.ballDiameterM))
                    LabeledContent("Ball mass", value: String(format: "%.0f g", SLA.ballMassKg * 1000))
                    LabeledContent("Drag Cd", value: String(format: "%.2f", SLA.dragCd))
                    LabeledContent("Scale tolerance",
                                   value: String(format: "%.0f%%", SLA.scaleDisagreeTol * 100))
                    Text("These match spike/sla_common.py, and the unit tests fail if they drift apart.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset settings to defaults") {
                        let before = model.settings
                        model.settings = AppSettings()
                        // Say what happened. A silent reset is indistinguishable
                        // from a broken button — especially when the settings
                        // were already at defaults, which is exactly the state
                        // an app update used to leave them in.
                        model.banner = AppModel.Banner(
                            kind: .info,
                            text: before == model.settings
                                ? "Settings were already at their defaults — nothing changed. Existing swings keep their old numbers; re-import a clip to measure it with these."
                                : "Settings reset. Existing swings keep the numbers they were measured with — re-import a clip to measure it again.")
                    }
                    Button("Delete all swings", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showTriggerCalibration) {
                TriggerCalibrationView(capture: model.capture).environmentObject(model)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.black)
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
