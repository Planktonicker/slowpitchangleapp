// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// The field screen: preview, setup, arm/disarm, and the last swing's numbers
/// big enough to read from the batter's box.
///
/// It owns the app's **only** `CameraPreview`; setup draws over it rather than
/// creating a second one. Two preview layers cannot share a session.
///
/// Two deliberate layouts. Filming happens in landscape — the phone is mounted
/// sideways on the tripod — so landscape is the primary design: status rail
/// down the left, controls down the right, nothing covering the hitting zone
/// in the middle of the frame. Portrait is for checking the phone in hand.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSetup = false
    @State private var permissionDenied = false
    @State private var measuring = false
    @State private var lastResult: BallMeasureResult?
    /// Where the detector actually found the ball, in camera coordinates, so
    /// the reticle can be drawn back over it.
    @State private var reticlePoint: CGPoint?
    @State private var tapPoint: CGPoint?
    @State private var suppressionToast: String?

    @AppStorage("swinglab.hasCompletedFirstSetup") private var hasCompletedFirstSetup = false

    /// Which step the user is on. Derived, never stored — the screen should
    /// always be able to answer "what now?" from the actual state.
    private enum Step {
        case starting, measure, ready, armed

        var index: Int {
            switch self {
            case .starting, .measure: return 1
            case .ready: return 2
            case .armed: return 3
            }
        }
    }

    private var step: Step {
        if model.capture.isArmed { return .armed }
        if model.capture.status != .running { return .starting }
        if model.wizard.scaleSource == .none { return .measure }
        return .ready
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                ZStack {
                    Color.black.ignoresSafeArea()
                    CameraPreview(controller: model.capture, onTap: handleTap)
                        .ignoresSafeArea()

                    reticle

                    if showSetup {
                        SetupOverlay(measuring: $measuring,
                                     lastResult: $lastResult,
                                     onClose: { closeSetup() },
                                     onArm: { model.arm(); closeSetup() })
                            .environmentObject(model)
                    } else if isLandscape {
                        landscapeOverlay
                    } else {
                        portraitOverlay
                    }

                    if model.capture.isRecordingClip { recordingBar }
                }
            }
            .navigationBarHidden(true)
            .task { await begin() }
            .onChange(of: scenePhase) { _, phase in
                // Paired lifecycle. The old `.onDisappear { stopCapture() }`
                // fired on every tab switch, tearing down a 240fps session and
                // silently disarming, and never fired a matching start.
                switch phase {
                case .background:
                    model.stopCapture()
                    model.wizard.stopSensors()
                case .active:
                    if model.capture.status != .running { model.startCapture() }
                    model.wizard.startSensors()
                default:
                    break
                }
            }
            .onChange(of: showSetup) { _, open in
                model.capture.wantsLiveMeasurement = open
            }
            .alert("Camera and microphone access needed",
                   isPresented: $permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("SwingLab films at 240fps and listens for bat-on-ball contact. Both stay on this device.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func begin() async {
        guard await CaptureController.requestPermissions() else {
            permissionDenied = true
            return
        }
        model.startCapture()
        model.wizard.startSensors()
        // First run drops straight into setup: the required order is not
        // discoverable otherwise, and the previous build's biggest complaint
        // was not knowing what to do first.
        if !hasCompletedFirstSetup {
            showSetup = true
            model.capture.wantsLiveMeasurement = true
        }
    }

    private func closeSetup() {
        showSetup = false
        model.capture.wantsLiveMeasurement = false
        hasCompletedFirstSetup = true
    }

    // MARK: - Tap to measure

    private func handleTap(_ devicePoint: CGPoint) {
        guard showSetup else {
            // Outside setup a tap is the AE/AF lock, now aimed at what was
            // actually touched rather than the centre of the frame.
            model.capture.lockExposureAndFocus(at: devicePoint)
            return
        }
        tapPoint = devicePoint
        reticlePoint = nil
        measuring = true
        model.capture.lockExposureAndFocus(at: devicePoint)
        model.capture.measure(atDevicePoint: devicePoint,
                              detector: model.settings.detector) { result in
            measuring = false
            lastResult = result
            if case .found(let measurement) = result {
                model.wizard.applyBallMeasurement(diameterPx: measurement.diameterPx)
                reticlePoint = devicePoint
            }
        }
    }

    /// Draws where the user tapped and, on success, that the ball was found —
    /// the fastest way to confirm the tap is landing where it looks like it is.
    @ViewBuilder private var reticle: some View {
        if showSetup, let point = tapPoint {
            GeometryReader { geo in
                // Camera points are normalised in the buffer's own orientation;
                // for the preview's `.resizeAspect` fit this is close enough
                // for a confirmation marker.
                let p = CGPoint(x: point.x * geo.size.width,
                                y: point.y * geo.size.height)
                Circle()
                    .strokeBorder(reticlePoint == nil ? Theme.warn : Theme.pass,
                                  lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .position(p)
                    .animation(.easeOut(duration: 0.15), value: reticlePoint != nil)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Layouts

    private var portraitOverlay: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                stepStrip
                HStack(alignment: .top, spacing: 12) {
                    statusColumn
                    Spacer(minLength: 12)
                    sessionColumn
                }
            }
            .padding(12)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

            interruptionChip
            Spacer()
            resultStack
            hitterGateEscape
            controlRow
        }
        .padding(14)
    }

    private var landscapeOverlay: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    stepStrip
                    statusColumn
                }
                .padding(12)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                interruptionChip
                Spacer()
                resultStack
                    .frame(maxWidth: 440, alignment: .leading)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 12) {
                sessionColumn
                    .padding(12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                Spacer()
                hitterGateEscape
                controlColumn
                    .frame(width: 210)
            }
        }
        .padding(14)
    }

    // MARK: - Shared pieces

    /// The required order, always on screen. Everything about the old layout
    /// pointed at ARM, which was the last step, so it failed with a banner.
    private var stepStrip: some View {
        HStack(spacing: 6) {
            stepPill(1, "Frame")
            stepPill(2, "Distance")
            stepPill(3, "Arm")
        }
    }

    private func stepPill(_ n: Int, _ title: String) -> some View {
        let current = step.index
        let done = n < current
        let active = n == current
        return HStack(spacing: 4) {
            Text(done ? "✓" : "\(n)")
                .font(.system(size: 9, weight: .black, design: .rounded))
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(0.8)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((active ? Theme.yellow : Theme.steel).opacity(active ? 0.9 : 0.18),
                    in: Capsule())
        .foregroundStyle(active ? .black : (done ? Theme.pass : Theme.steel))
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.capture.activeFormatDescription.isEmpty
                 ? "STARTING CAMERA…" : model.capture.activeFormatDescription)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 6) {
                if model.settings.requireHitter {
                    StatChip(text: model.capture.hitterPresent ? "Hitter in frame" : "No hitter",
                             color: model.capture.hitterPresent ? Theme.pass : Theme.steel)
                }
                if model.capture.exposureLocked {
                    StatChip(text: "AE/AF locked", color: Theme.pass)
                }
            }
            if model.capture.droppedFrameCount > 0 {
                // Dropped frames corrupt the constant frame interval every
                // measurement rests on, so this is never hidden.
                StatChip(text: "\(model.capture.droppedFrameCount) dropped frames",
                         color: Theme.warn)
            }
            if model.capture.suppressedTriggerCount > 0 {
                StatChip(text: "\(model.capture.suppressedTriggerCount) hits ignored — no hitter seen",
                         color: Theme.warn)
            }
        }
    }

    private var sessionColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("SETTING")
                    .font(Theme.label(9)).tracking(1.2)
                    .foregroundStyle(Theme.steel)
                Picker("Setting", selection: $model.currentSetting) {
                    ForEach(SwingSetting.allCases) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.yellow)
                .font(.system(size: 13, weight: .bold))
            }
            triggerMeter
        }
    }

    @ViewBuilder private var interruptionChip: some View {
        if let interruption = model.capture.interruptionMessage {
            StatChip(text: interruption, color: Theme.warn, filled: true)
        }
    }

    /// Offered only when the pose gate has clearly stopped working — armed a
    /// while and it has never once seen a person. Without this the gate can
    /// silently swallow an entire session, which is exactly what happened.
    @ViewBuilder private var hitterGateEscape: some View {
        if model.hitterGateLooksStuck {
            VStack(spacing: 6) {
                Text("No hitter has been detected since arming. Hits may be getting ignored.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                Button("Trust the audio trigger") { model.trustAudioTriggerForSession() }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(10)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var recordingBar: some View {
        VStack {
            Text("● RECORDING")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Theme.fail)
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var resultStack: some View {
        if let swing = model.lastSwing { lastSwingCard(swing) }
        if let progress = model.analysisProgress { analysisBar(progress) }
    }

    /// Live contact-impulse level against the trigger threshold — the same
    /// measurement `check_audio_trigger.py` makes, so a venue can be judged
    /// before a single swing.
    private var triggerMeter: some View {
        let db = model.capture.triggerLevelDb
        let fraction = max(0, min(1, db / max(1, model.settings.triggerDb * 1.5)))
        return VStack(alignment: .trailing, spacing: 3) {
            Text("CONTACT LEVEL")
                .font(Theme.label(9)).tracking(1.2)
                .foregroundStyle(Theme.steel)
            Text(String(format: "%.0f dB", max(0, db)))
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 110, height: 6)
                Capsule()
                    .fill(db >= model.settings.triggerDb ? Theme.pass : Theme.yellow)
                    .frame(width: 110 * fraction, height: 6)
            }
            Text("clap to test")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.steel)
        }
    }

    private func lastSwingCard(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                MetricTile(label: "Launch",
                           value: String(format: "%.1f", swing.launchAngleDeg),
                           unit: "°")
                MetricTile(label: "Exit velo",
                           value: String(format: "%.1f", swing.exitVeloMph),
                           unit: "mph")
                if let bs = swing.batSpeedMph {
                    MetricTile(label: "Bat",
                               value: String(format: "%.0f", bs),
                               unit: "mph",
                               tint: .white)
                } else if let attack = swing.batAttackAngleDeg {
                    MetricTile(label: "Attack",
                               value: String(format: "%.1f", attack),
                               unit: "°",
                               tint: .white)
                }
            }
            if swing.trackedFrames == 0 {
                StatChip(text: "No ball track in that clip", color: Theme.warn)
            } else {
                HStack(spacing: 8) {
                    Text("\(swing.trackedFrames) frames")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.steel)
                    ConfidenceRow(flags: swing.flags, captureFlags: swing.captureFlags)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.yellow.opacity(0.6), lineWidth: 1.5))
    }

    private func analysisBar(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ANALYZING SWING…")
                .font(Theme.label(11)).tracking(1.5)
                .foregroundStyle(Theme.yellow)
            ProgressView(value: progress)
                .tint(Theme.yellow)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls
    //
    // Exactly one big yellow slab is on screen at a time, and it is always the
    // correct next action. Previously ARM was the visually dominant button on
    // arrival even though it was the last of five steps, so the obvious thing
    // to press was guaranteed to fail.

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .starting:
            Button {} label: { Text("Starting camera…") }
                .buttonStyle(SlabButtonStyle(fill: Theme.surface, textColor: Theme.steel))
                .disabled(true)
        case .measure:
            Button { openSetup() } label: { Text("1 · Set up camera") }
                .buttonStyle(SlabButtonStyle())
        case .ready:
            Button { model.arm() } label: { Text("Arm") }
                .buttonStyle(SlabButtonStyle())
                .disabled(model.capture.isRecordingClip)
        case .armed:
            Button { model.disarm() } label: { Text("● Armed — tap to stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white))
                .disabled(model.capture.isRecordingClip)
        }
    }

    private func openSetup() {
        showSetup = true
        model.capture.wantsLiveMeasurement = true
    }

    @ViewBuilder private var advisoryLine: some View {
        if step == .ready || step == .measure, let advice = model.wizard.topAdvisory {
            Text(advice.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(advice.level == .blocking ? Theme.warn : Theme.steel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupButton: some View {
        Button { openSetup() } label: { Text("Set up") }
            .buttonStyle(OutlineButtonStyle())
    }

    private var manualButton: some View {
        Button { model.triggerManually() } label: { Text("Manual") }
            .buttonStyle(OutlineButtonStyle())
            .disabled(model.capture.isRecordingClip)
    }

    private var controlRow: some View {
        VStack(spacing: 8) {
            advisoryLine
            primaryButton
            HStack(spacing: 10) {
                setupButton
                manualButton
            }
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 8) {
            advisoryLine
            primaryButton
            HStack(spacing: 8) {
                setupButton
                manualButton
            }
        }
    }
}
