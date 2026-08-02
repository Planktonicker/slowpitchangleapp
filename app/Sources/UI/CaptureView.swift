// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// The field screen.
///
/// It owns the app's **only** `CameraPreview`; setup draws over it rather than
/// creating a second one, because two preview layers cannot share a session.
///
/// The HUD is a broadcast score bug (see `CaptureHUD.swift`): one state signal
/// at one fixed address, one primary action, and an empty ribbon when nothing
/// is wrong. The middle band of the frame is kept clear in every state — that
/// is where the hitter and the ball are, and it is what the user is judging.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSetup = false
    @State private var showStatus = false
    @State private var permissionDenied = false
    @State private var measuring = false
    @State private var lastResult: BallMeasureResult?
    /// Where the last measurement tap landed, in screen coordinates. Screen
    /// rather than normalised camera coords: under a fill crop the two do not
    /// map by a simple scale, and the marker must sit under the finger.
    @State private var tapViewPoint: CGPoint?
    @State private var foundBall = false

    @AppStorage("swinglab.hasCompletedFirstSetup") private var hasCompletedFirstSetup = false

    /// Strict precedence. A HUD that reports the wrong state is worse than a
    /// cluttered one, so this lives in exactly one place.
    private var hudState: HUDState {
        if model.capture.interruptionMessage != nil { return .interrupted }
        if model.capture.isRecordingClip { return .recording }
        if model.analysisProgress != nil { return .analysing }
        if model.capture.isArmed { return .armed }
        if model.capture.status != .running { return .starting }
        if model.wizard.scaleSource == .none { return .needsSetup }
        return .ready
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(controller: model.capture, onTap: handleTap)
                    .ignoresSafeArea()

                tapMarker

                if showSetup {
                    SetupOverlay(measuring: $measuring,
                                 lastResult: $lastResult,
                                 onClose: { closeSetup() },
                                 onArm: { model.arm(); closeSetup() })
                        .environmentObject(model)
                } else {
                    hud
                }
            }
            .navigationBarHidden(true)
            .task { await begin() }
            .onChange(of: scenePhase) { _, phase in
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
            .sheet(isPresented: $showStatus) { StatusSheet().environmentObject(model) }
            .alert("Camera and microphone access needed", isPresented: $permissionDenied) {
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

    // MARK: - HUD

    /// Same structure in both orientations: ribbon at the top, clear band in
    /// the middle, bug bottom-left and action bottom-right. Portrait simply has
    /// less width for the bottom row, so the pieces stack instead.
    private var hud: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                ExceptionRibbon(chips: exceptionChips,
                                setting: model.currentSetting.displayName,
                                onChipTap: { showStatus = true },
                                settingMenu: AnyView(settingMenu))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .background(
                        LinearGradient(colors: [.black.opacity(0.8), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            // Horizontal as well as top: in landscape the
                            // Dynamic Island insets the safe area at the sides,
                            // so a top-only bleed leaves the fade stopping
                            // short of both screen edges.
                            .ignoresSafeArea(edges: [.top, .horizontal])
                    )

                // The clear band. Only the result and the escape banner may
                // enter it, and both clear themselves.
                ZStack {
                    Color.clear
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if let swing = model.lastSwing, hudState != .recording {
                            lastSwingCard(swing)
                                .frame(maxWidth: isLandscape ? 460 : .infinity)
                        }
                        if model.hitterGateLooksStuck { hitterGateEscape }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }

                if hudState != .starting && hudState != .needsSetup {
                    SeamMeter(db: model.capture.triggerLevelDb,
                              thresholdDb: model.settings.triggerDb)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                bottomRow(isLandscape: isLandscape)
                    .padding(.horizontal, 16)
                    // Just enough to sit off the tab bar. The TabView already
                    // insets its content for the floating bar, so the earlier
                    // 64pt clearance was stacked on top of that inset and
                    // stranded the controls halfway up the screen.
                    .padding(.bottom, 8)
            }
        }
    }

    private func bottomRow(isLandscape: Bool) -> some View {
        // Landscape has room for bug and action side by side. Portrait does
        // not — squeezing them together is what turned the primary button into
        // "1 · SE…" — so there the action gets its own full-width row.
        Group {
            if isLandscape {
                HStack(alignment: .bottom, spacing: 12) {
                    bug
                    Spacer(minLength: 0)
                    actionCluster.frame(width: 300)
                }
            } else {
                VStack(spacing: 10) {
                    bug.frame(maxWidth: .infinity, alignment: .leading)
                    actionCluster
                }
            }
        }
    }

    private var bug: some View {
        ScoreBug(state: hudState,
                 label: bugLabel,
                 value: bugValue,
                 qualifier: bugQualifier,
                 subline: "\(model.sessionSwingCount) swings",
                 onTap: { showStatus = true })
    }

    private var actionCluster: some View {
        HStack(spacing: 10) {
            if let icon = contextAction {
                Button(action: icon.action) {
                    VStack(spacing: 3) {
                        Image(systemName: icon.symbol).font(.system(size: 20, weight: .bold))
                        Text(icon.caption).font(Theme.label(9)).tracking(0.6)
                    }
                    .frame(width: 56, height: 74)
                }
                .buttonStyle(OutlineButtonStyle())
                .frame(width: 56)
                .disabled(icon.disabled)
            }
            primaryButton.frame(height: 74)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch hudState {
        case .starting:
            Button {} label: { Text("Starting camera…") }
                .buttonStyle(SlabButtonStyle(fill: Theme.surface, textColor: Theme.steel,
                                             size: 15, verticalPadding: 24))
                .disabled(true)
        case .interrupted:
            Button { model.startCapture() } label: { Text("Retry") }
                .buttonStyle(SlabButtonStyle(size: 19, verticalPadding: 24))
        case .needsSetup:
            Button { openSetup() } label: { Text("1 · Set up camera") }
                .buttonStyle(SlabButtonStyle(size: 17, verticalPadding: 24))
        case .ready:
            Button { model.arm() } label: { Text("2 · Arm") }
                .buttonStyle(SlabButtonStyle(size: 21, verticalPadding: 24))
        case .armed, .analysing:
            Button { model.disarm() } label: { Text("Stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white,
                                             size: 21, verticalPadding: 24))
        case .recording:
            Button {} label: { Text("Stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white,
                                             size: 21, verticalPadding: 24))
                .disabled(true)
        }
    }

    private var contextAction: (symbol: String, caption: String, disabled: Bool, action: () -> Void)? {
        switch hudState {
        case .starting, .needsSetup, .interrupted:
            return nil   // exactly one control when there is exactly one thing to do
        case .ready:
            return ("viewfinder", "FRAME", false, { openSetup() })
        case .armed, .recording, .analysing:
            return ("bolt.fill", "MANUAL", model.capture.isRecordingClip,
                    { model.triggerManually() })
        }
    }

    // MARK: - Bug content

    private var bugLabel: String {
        switch hudState {
        case .ready: return "Metres"
        case .needsSetup: return ""
        case .analysing: return "Percent"
        default: return "Status"
        }
    }

    private var bugValue: String {
        switch hudState {
        case .needsSetup:
            // Short and imperative. The full advisory is long and turned the
            // bug into a paragraph, which is not what a glanceable readout is.
            return "Tap the ball"
        case .ready:
            if let m = model.wizard.derivedDistanceM { return String(format: "%.1f", m) }
            return "SET"
        case .analysing:
            return "\(Int((model.analysisProgress ?? 0) * 100))"
        case .interrupted:
            return "—"
        default:
            return "—"
        }
    }

    private var bugQualifier: (text: String, color: Color)? {
        guard hudState == .ready, model.wizard.derivedDistanceM != nil else { return nil }
        if model.wizard.isDistanceIdeal { return ("good", Theme.pass) }
        if model.wizard.isDistanceAcceptable { return ("ok", Theme.yellow) }
        return ("move", Theme.warn)
    }

    // MARK: - Exceptions (rendered only when abnormal)

    private var exceptionChips: [(text: String, symbol: String, color: Color)] {
        var out: [(String, String, Color)] = []
        if model.capture.interruptionMessage != nil {
            out.append(("Camera paused", "exclamationmark.triangle.fill", Theme.fail))
        }
        if model.capture.droppedFrameCount > 0 {
            out.append(("\(model.capture.droppedFrameCount) dropped",
                        "exclamationmark.triangle.fill", Theme.warn))
        }
        if model.capture.suppressedTriggerCount > 0 {
            out.append(("\(model.capture.suppressedTriggerCount) ignored",
                        "bolt.slash.fill", Theme.warn))
        }
        if model.settings.requireHitter, model.capture.isArmed, !model.capture.hitterPresent {
            out.append(("No hitter", "person.slash.fill", Theme.warn))
        }
        if model.capture.status == .running, model.capture.fps < SLA.targetFPS - 1 {
            out.append(("\(Int(model.capture.fps)) fps", "speedometer", Theme.fail))
        }
        return out
    }

    private var settingMenu: some View {
        Menu {
            ForEach(SwingSetting.allCases) { setting in
                Button(setting.displayName) { model.currentSetting = setting }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.currentSetting.displayName.uppercased())
                    .font(Theme.label(11))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .black))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.75), in: Capsule())
            .foregroundStyle(Theme.yellow)
            .frame(height: 44)
        }
    }

    // MARK: - Result and escape

    private func lastSwingCard(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                MetricTile(label: "Launch",
                           value: String(format: "%.1f", swing.launchAngleDeg), unit: "°")
                MetricTile(label: "Exit velo",
                           value: model.settings.speedUnit.format(mph: swing.exitVeloMph),
                           unit: model.settings.speedUnit.suffix)
                if let bs = swing.batSpeedMph {
                    MetricTile(label: "Bat",
                               value: model.settings.speedUnit.format(mph: bs, decimals: 0),
                               unit: model.settings.speedUnit.suffix, tint: .white)
                }
            }
            if swing.trackedFrames == 0 {
                StatChip(text: "No ball track in that clip", color: Theme.warn)
            } else {
                ConfidenceRow(flags: swing.flags, captureFlags: swing.captureFlags)
            }
            if let progress = model.analysisProgress {
                ProgressView(value: progress).tint(Theme.yellow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.yellow.opacity(0.6), lineWidth: 1.5))
    }

    @ViewBuilder private var hitterGateEscape: some View {
        VStack(spacing: 6) {
            Text("No hitter detected since arming — hits may be getting ignored.")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.warn)
                .multilineTextAlignment(.center)
            Button("Trust the audio trigger") { model.trustAudioTriggerForSession() }
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(10)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tap

    private func handleTap(_ devicePoint: CGPoint, _ viewPoint: CGPoint) {
        // Measuring is allowed whenever there is no scale yet — not only while
        // the setup panel is open. The HUD says "tap the ball in the picture",
        // and it has to be true wherever that text is on screen.
        guard showSetup || model.wizard.scaleSource == .none else {
            model.capture.lockExposureAndFocus(at: devicePoint)
            return
        }
        if !model.capture.wantsLiveMeasurement {
            // Frames are only converted for measurement on demand; the first
            // tap after landing on the screen arms that and asks again.
            model.capture.wantsLiveMeasurement = true
        }
        tapViewPoint = viewPoint
        foundBall = false
        measuring = true
        model.capture.lockExposureAndFocus(at: devicePoint)
        model.capture.measure(atDevicePoint: devicePoint,
                              detector: model.settings.detector) { result in
            measuring = false
            lastResult = result
            if case .found(let m) = result {
                model.wizard.applyBallMeasurement(diameterPx: m.diameterPx,
                                                  atX: m.x, atY: m.y)
                foundBall = true
            }
        }
    }

    /// Confirms where the tap landed — the fastest way to see the app is
    /// looking where you pointed. Positioned in raw screen coordinates, in a
    /// full-bleed space matching the preview view the gesture came from.
    @ViewBuilder private var tapMarker: some View {
        if let point = tapViewPoint, showSetup || model.wizard.scaleSource == .none {
            GeometryReader { _ in
                Circle()
                    .strokeBorder(foundBall ? Theme.pass : Theme.warn, lineWidth: 2.5)
                    .frame(width: 46, height: 46)
                    .position(point)
                    .animation(.easeOut(duration: 0.15), value: foundBall)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Lifecycle

    private func begin() async {
        guard await CaptureController.requestPermissions() else {
            permissionDenied = true
            return
        }
        model.startCapture()
        model.wizard.startSensors()
        if !hasCompletedFirstSetup { openSetup() }
    }

    private func openSetup() {
        showSetup = true
        model.capture.wantsLiveMeasurement = true
    }

    private func closeSetup() {
        showSetup = false
        model.capture.wantsLiveMeasurement = false
        hasCompletedFirstSetup = true
    }
}

/// Everything demoted off the HUD. Nothing is deleted — dropped frames and
/// ignored triggers corrupt or lose measurements, so they stay one tap away.
struct StatusSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Camera") {
                    row("Format", model.capture.activeFormatDescription.isEmpty
                        ? "starting…" : model.capture.activeFormatDescription)
                    row("Frame rate", String(format: "%.0f fps", model.capture.fps))
                    row("Field of view", String(format: "%.0f°", model.capture.fieldOfViewDeg))
                    row("Exposure", model.capture.exposureLocked ? "locked" : "auto")
                    if let interruption = model.capture.interruptionMessage {
                        Text(interruption).foregroundStyle(Theme.warn)
                    }
                }
                Section {
                    row("Dropped frames", "\(model.capture.droppedFrameCount)")
                    Text("Every measurement assumes a constant frame interval. Dropped frames break that, so any swing captured while this was climbing is flagged.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Timing") }

                Section {
                    row("Contact level", String(format: "%.0f dB", max(0, model.capture.triggerLevelDb)))
                    row("Threshold", String(format: "%.0f dB", model.settings.triggerDb))
                    row("Ignored — no hitter", "\(model.capture.suppressedTriggerCount)")
                    Text("Clap near the phone: the bar above the buttons should jump past the notch. If it does not, the trigger will not hear contact either — use Manual.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Trigger") }

                Section("Placement") {
                    row("Distance", model.wizard.derivedDistanceM.map { Fmt.m($0) } ?? "—")
                    row("Scale source", model.wizard.scaleSource.rawValue)
                    row("Roll", model.wizard.level.hasReading
                        ? String(format: "%+.1f°", model.wizard.level.rollDeg) : "unknown")
                    row("Tilt", model.wizard.level.hasReading
                        ? String(format: "%+.1f°", model.wizard.level.tiltDeg) : "unknown")
                    ForEach(model.wizard.advisories.indices, id: \.self) { i in
                        Text(model.wizard.advisories[i].text)
                            .font(.caption)
                            .foregroundStyle(model.wizard.advisories[i].level == .blocking
                                             ? Theme.warn : .secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.black)
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
