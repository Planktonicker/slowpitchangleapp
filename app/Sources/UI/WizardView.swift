// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Guided placement. Arming stays blocked until every check passes.
struct WizardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var wizard: PlacementWizard { model.wizard }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                Divider()
                content
                Divider()
                footer
            }
            .navigationTitle(wizard.step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        wizard.distance.stop()
                        dismiss()
                    }
                }
            }
            .onAppear { wizard.startSensors() }
            .onDisappear { wizard.distance.stop() }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(PlacementWizard.Step.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= wizard.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: 4)
            }
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        switch wizard.step {
        case .level:      levelStep
        case .distance:   distanceStep
        case .plateScale: plateStep
        case .ready:      readyStep
        }
    }

    // MARK: - Step 1: level

    private var levelStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Stand the tripod perpendicular to the line of play, on the hitter's open side, with the lens at about contact height.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                bubble

                VStack(spacing: 10) {
                    readout("Horizon roll",
                            String(format: "%+.1f°", wizard.level.rollDeg),
                            ok: wizard.level.isRollOK)
                    readout("Up/down tilt",
                            String(format: "%+.1f°", wizard.level.tiltDeg),
                            ok: wizard.level.isTiltOK)
                }

                Text("Roll is corrected in the maths, so a small error is survivable. Tilt is not — a camera pointing up or down turns the flight into a projection and breaks the link between vertical pixels and vertical metres.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Zero here") { wizard.level.zeroHere() }
                        .buttonStyle(.bordered)
                    Button("Clear zero") { wizard.level.clearZero() }
                        .buttonStyle(.bordered)
                }
                if !wizard.level.isAvailable {
                    Label("No motion sensor available on this device.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }

    /// Bubble level: the dot drifts with roll and tilt, and turns green in
    /// tolerance.
    private var bubble: some View {
        let roll = wizard.level.rollDeg
        let tilt = wizard.level.tiltDeg
        let clamp = { (v: Double, limit: Double) in max(-1, min(1, v / limit)) }
        return ZStack {
            Circle().stroke(.secondary.opacity(0.4), lineWidth: 2)
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 1).frame(width: 40, height: 40)
            Circle()
                .fill(wizard.level.isLevel ? Color.green : Color.orange)
                .frame(width: 24, height: 24)
                .offset(x: clamp(roll, 10) * 70, y: clamp(tilt, 10) * 70)
                .animation(.easeOut(duration: 0.12), value: roll)
                .animation(.easeOut(duration: 0.12), value: tilt)
        }
        .frame(width: 180, height: 180)
    }

    // MARK: - Step 2: distance

    private var distanceStep: some View {
        VStack(spacing: 0) {
            if wizard.useManualDistance || !ARDistanceSensor.isSupported {
                manualDistance
            } else {
                ZStack(alignment: .center) {
                    ARPreview(session: wizard.distance.session)
                    // Aim reticle: the raycast leaves the middle of the frame.
                    Image(systemName: "plus")
                        .font(.title)
                        .foregroundStyle(.yellow)
                }
                .frame(maxHeight: .infinity)
            }

            VStack(spacing: 10) {
                if let message = wizard.distance.trackingMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                readout("Distance to plate",
                        wizard.effectiveDistanceFt.map { String(format: "%.1f ft", $0) } ?? "—",
                        ok: wizard.isDistanceOK)
                readout("Lens height",
                        wizard.distance.heightFt.map { String(format: "%.1f ft", $0) } ?? "—",
                        ok: wizard.distance.isHeightOK)
                Text("Aim the cross at the plate or tee. The protocol wants 15-20 ft — prefer 20 so more of the flight stays in frame.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enter distance by hand", isOn: Binding(
                    get: { wizard.useManualDistance },
                    set: { on in
                        wizard.useManualDistance = on
                        on ? wizard.distance.stop() : wizard.distance.start()
                    }))
                    .font(.callout)
            }
            .padding()
        }
    }

    private var manualDistance: some View {
        VStack(spacing: 12) {
            Text(String(format: "%.1f ft", wizard.manualDistanceFt))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Slider(value: Binding(get: { wizard.manualDistanceFt },
                                  set: { wizard.manualDistanceFt = $0 }),
                   in: 10...30, step: 0.5)
            Text("Measure it with the tape and type it in. It is used to predict how big the plate should look, so a guess here weakens the next check.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    // MARK: - Step 3: plate scale

    private var plateStep: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    CameraPreview(session: model.capture.session)
                    PlateMarkers(start: Binding(get: { wizard.plateStart },
                                                set: { wizard.plateStart = $0 }),
                                 end: Binding(get: { wizard.plateEnd },
                                              set: { wizard.plateEnd = $0 }),
                                 size: geo.size)
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Text("Drag the two handles onto the ends of home plate's front edge — the 17 inch one facing the pitcher.")
                    .font(.caption).foregroundStyle(.secondary)
                readout("Predicted scale",
                        wizard.predictedPxPerM.map { String(format: "%.0f px/m", $0) } ?? "—",
                        ok: wizard.predictedPxPerM != nil)
                readout("Measured off the plate",
                        wizard.measuredPxPerM.map { String(format: "%.0f px/m", $0) } ?? "—",
                        ok: wizard.measuredPxPerM != nil)
                readout("Disagreement",
                        wizard.plateScaleDisagreement.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                        ok: wizard.isPlateScaleOK)
                Text("This is a third scale estimate, independent of the ball and of gravity, available before you hit anything. If it disagrees, the distance or the framing is wrong.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Skip (no plate at this location)", isOn: Binding(
                    get: { wizard.plateCheckSkipped },
                    set: { wizard.plateCheckSkipped = $0 }))
                    .font(.callout)
            }
            .padding()
        }
    }

    // MARK: - Step 4: ready

    private var readyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if wizard.isArmingAllowed {
                    Label("Placement checks pass", systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(.green)
                } else {
                    Label(wizard.blockingReason ?? "Checks incomplete",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                }

                summaryRow("Horizon roll", String(format: "%+.1f°", wizard.level.rollDeg))
                summaryRow("Applied as correction", String(format: "%+.1f°", wizard.level.rollDeg))
                summaryRow("Up/down tilt", String(format: "%+.1f°", wizard.level.tiltDeg))
                summaryRow("Distance",
                           wizard.effectiveDistanceFt.map { String(format: "%.1f ft", $0) } ?? "—")
                summaryRow("Lens height",
                           wizard.distance.heightFt.map { String(format: "%.1f ft", $0) } ?? "—")
                summaryRow("Plate scale disagreement",
                           wizard.plateScaleDisagreement.map { String(format: "%.1f%%", $0 * 100) } ?? "skipped")

                Text("These are stamped onto every swing captured from here, so a session filmed from a different spot is never silently mixed with this one.")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    model.capture.lockExposureAndFocus()
                } label: {
                    Label("Lock focus and exposure", systemImage: "lock")
                }
                .buttonStyle(.bordered)

                Text("Lock AE/AF on the hitting zone before each round. Without it a passing cloud changes exposure and the ball smears differently swing to swing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            Button("Back") { wizard.back() }
                .buttonStyle(.bordered)
                .disabled(wizard.step == .level)
            Spacer()
            if wizard.step == .ready {
                Button("Arm") {
                    model.arm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!wizard.isArmingAllowed)
            } else {
                Button("Next") { wizard.advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func readout(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout.monospacedDigit().weight(.medium))
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Two draggable handles and the line between them, in normalized coords.
struct PlateMarkers: View {
    @Binding var start: CGPoint
    @Binding var end: CGPoint
    var size: CGSize

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: point(start))
                path.addLine(to: point(end))
            }
            .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

            handle($start)
            handle($end)
        }
    }

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func handle(_ binding: Binding<CGPoint>) -> some View {
        Circle()
            .strokeBorder(.yellow, lineWidth: 3)
            .background(Circle().fill(.yellow.opacity(0.25)))
            .frame(width: 34, height: 34)
            .position(point(binding.wrappedValue))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        binding.wrappedValue = CGPoint(
                            x: max(0, min(1, value.location.x / size.width)),
                            y: max(0, min(1, value.location.y / size.height))
                        )
                    }
            )
    }
}
