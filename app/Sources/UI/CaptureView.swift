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
/// A thin shell on purpose. Everything lives in `CaptureScreen`, which takes
/// the camera and the placement wizard as `@ObservedObject`s instead of
/// reaching them through `AppModel`. That is what keeps a 10 Hz trigger-meter
/// reading from invalidating every tab in the app — see the comment in
/// `AppModel.init`.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        CaptureScreen(model: model, capture: model.capture, wizard: model.wizard)
    }
}

/// The HUD is a broadcast score bug (see `CaptureHUD.swift`): one state signal
/// at one fixed address, one primary action, and an empty ribbon when nothing
/// is wrong. The middle band of the frame is kept clear in every state — that
/// is where the hitter and the ball are, and it is what the user is judging.
struct CaptureScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureController
    @ObservedObject var wizard: PlacementWizard

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
        if capture.interruptionMessage != nil { return .interrupted }
        if capture.isRecordingClip { return .recording }
        // Armed outranks analysing. Analysis is background work on the last
        // swing — the camera is still armed and still listening, so saying
        // WORKING would misreport what the app is doing, and it also replaced
        // the STOP button's meaning. Progress shows on the swing card instead.
        if capture.isArmed { return .armed }
        if model.analysisProgress != nil { return .analysing }
        if capture.status != .running { return .starting }
        if wizard.scaleSource == .none { return .needsSetup }
        return .ready
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(controller: capture, onTap: handleTap)
                    .ignoresSafeArea()

                tapMarker

                if showSetup {
                    SetupOverlay(capture: capture,
                                 wizard: wizard,
                                 measuring: $measuring,
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
                    wizard.stopSensors()
                case .active:
                    if capture.status != .running { model.startCapture() }
                    wizard.startSensors()
                default:
                    break
                }
            }
            .sheet(isPresented: $showStatus) {
                StatusSheet(capture: capture, wizard: wizard).environmentObject(model)
            }
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
                                onChipTap: { showStatus = true },
                                trailing: AnyView(persistentControls))
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
                    SeamMeter(db: capture.triggerLevelDb,
                              thresholdDb: model.settings.triggerDb)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
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

    /// Height of the bottom controls. One constant, used by the bug, the
    /// context button and the primary slab, because three separately-tuned
    /// heights is how a row stops looking like a row.
    private static let controlHeight: CGFloat = 60

    private func bottomRow(isLandscape: Bool) -> some View {
        // Landscape has room for bug and action side by side. Portrait does
        // not — squeezing them together is what turned the primary button into
        // "1 · SE…" — so there the action gets its own full-width row.
        Group {
            if isLandscape {
                HStack(alignment: .bottom, spacing: 12) {
                    bug
                    Spacer(minLength: 0)
                    actionCluster.frame(width: 264)
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
                 height: Self.controlHeight,
                 onTap: { showStatus = true })
    }

    private var actionCluster: some View {
        HStack(spacing: 10) {
            if let icon = contextAction {
                Button(action: icon.action) {
                    VStack(spacing: 2) {
                        Image(systemName: icon.symbol).font(.system(size: 17, weight: .bold))
                        Text(icon.caption).font(Theme.label(9)).tracking(0.5)
                    }
                    .frame(width: 52)
                }
                .buttonStyle(OutlineButtonStyle(verticalPadding: 0, cornerRadius: 14,
                                                minHeight: Self.controlHeight))
                .frame(width: 52)
                .disabled(icon.disabled)
            }
            primaryButton
        }
        // Nothing in this row may grow taller than the row. Left to itself a
        // control with a flexible height takes the whole screen in portrait.
        .frame(height: Self.controlHeight)
    }

    @ViewBuilder private var primaryButton: some View {
        switch hudState {
        case .starting:
            Button {} label: { Text("Starting camera…") }
                .buttonStyle(SlabButtonStyle(fill: Theme.surface, textColor: Theme.steel,
                                             size: 14, verticalPadding: 0, minHeight: Self.controlHeight))
                .disabled(true)
        case .interrupted:
            Button { model.startCapture() } label: { Text("Retry") }
                .buttonStyle(SlabButtonStyle(size: 17, verticalPadding: 0, minHeight: Self.controlHeight))
        case .needsSetup:
            Button { openSetup() } label: { Text("1 · Set up camera") }
                .buttonStyle(SlabButtonStyle(size: 15, verticalPadding: 0, minHeight: Self.controlHeight))
        case .ready:
            Button { model.arm() } label: { Text("2 · Arm") }
                .buttonStyle(SlabButtonStyle(size: 19, verticalPadding: 0, minHeight: Self.controlHeight))
        case .armed:
            Button { model.disarm() } label: { Text("Stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white,
                                             size: 19, verticalPadding: 0, minHeight: Self.controlHeight))
        case .analysing:
            Button {} label: { Text("Measuring…") }
                .buttonStyle(SlabButtonStyle(fill: Theme.surface, textColor: Theme.steel,
                                             size: 15, verticalPadding: 0, minHeight: Self.controlHeight))
                .disabled(true)
        case .recording:
            Button {} label: { Text("Stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white,
                                             size: 19, verticalPadding: 0, minHeight: Self.controlHeight))
                .disabled(true)
        }
    }

    private var contextAction: (symbol: String, caption: String, disabled: Bool, action: () -> Void)? {
        switch hudState {
        case .starting, .needsSetup, .interrupted:
            return nil   // exactly one control when there is exactly one thing to do
        case .ready:
            return ("viewfinder", "FRAME", false, { openSetup() })
        case .analysing:
            return nil   // not armed, so there is nothing to trigger manually
        case .armed, .recording:
            return ("bolt.fill", "MANUAL", capture.isRecordingClip,
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
            if let m = wizard.derivedDistanceM { return String(format: "%.1f", m) }
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
        guard hudState == .ready, wizard.derivedDistanceM != nil else { return nil }
        if wizard.isDistanceIdeal { return ("good", Theme.pass) }
        if wizard.isDistanceAcceptable { return ("ok", Theme.yellow) }
        return ("move", Theme.warn)
    }

    // MARK: - Exceptions (rendered only when abnormal)

    private var exceptionChips: [(text: String, symbol: String, color: Color)] {
        var out: [(String, String, Color)] = []
        if capture.interruptionMessage != nil {
            out.append(("Camera paused", "exclamationmark.triangle.fill", Theme.fail))
        }
        if capture.droppedFrameCount > 0 {
            out.append(("\(capture.droppedFrameCount) dropped",
                        "exclamationmark.triangle.fill", Theme.warn))
        }
        if capture.suppressedTriggerCount > 0 {
            out.append(("\(capture.suppressedTriggerCount) ignored",
                        "bolt.slash.fill", Theme.warn))
        }
        if model.settings.requireHitter, capture.isArmed, !capture.hitterPresent {
            out.append(("No hitter", "person.slash.fill", Theme.warn))
        }
        if capture.status == .running, capture.fps < SLA.targetFPS - 1 {
            out.append(("\(Int(capture.fps)) fps", "speedometer", Theme.fail))
        }
        return out
    }

    /// The controls that must exist in every state, at one fixed address.
    ///
    /// Setup lives here rather than only in the bottom row. The bottom row's
    /// secondary button is FRAME when ready and MANUAL once armed, so arming —
    /// or an analysis that is still running — used to take away the only route
    /// back to setup, and the screen became a dead end.
    private var persistentControls: some View {
        HStack(spacing: 8) {
            Button { openSetup() } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 15, weight: .heavy))
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.75), in: Circle())
                    .foregroundStyle(Theme.yellow)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set up the camera")

            settingMenu
        }
    }

    /// A plain button and a confirmation dialog rather than a `Menu`.
    ///
    /// `Menu` re-evaluates its label and its content closure on every
    /// invalidation of the enclosing view, which is what made switching
    /// setting feel laggy while the HUD was rebuilding underneath it. A
    /// dialog is presented once and is nobody's child.
    private var settingMenu: some View {
        Button {
            showSettingPicker = true
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
        .buttonStyle(.plain)
        .confirmationDialog("Which setting?", isPresented: $showSettingPicker,
                            titleVisibility: .visible) {
            ForEach(SwingSetting.allCases) { setting in
                Button(setting.displayName) { model.currentSetting = setting }
            }
        }
    }

    @State private var showSettingPicker = false

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
        guard showSetup || wizard.scaleSource == .none else {
            capture.lockExposureAndFocus(at: devicePoint)
            return
        }
        if !capture.wantsLiveMeasurement {
            // Frames are only converted for measurement on demand; the first
            // tap after landing on the screen arms that and asks again.
            capture.wantsLiveMeasurement = true
        }
        tapViewPoint = viewPoint
        foundBall = false
        measuring = true
        capture.lockExposureAndFocus(at: devicePoint)
        capture.measure(atDevicePoint: devicePoint,
                        detector: model.settings.detector) { result in
            measuring = false
            lastResult = result
            if case .found(let m) = result {
                wizard.applyBallMeasurement(diameterPx: m.diameterPx,
                                            atX: m.x, atY: m.y)
                foundBall = true
            }
        }
    }

    /// Confirms where the tap landed — the fastest way to see the app is
    /// looking where you pointed. Positioned in raw screen coordinates, in a
    /// full-bleed space matching the preview view the gesture came from.
    @ViewBuilder private var tapMarker: some View {
        if let point = tapViewPoint, showSetup || wizard.scaleSource == .none {
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
        wizard.startSensors()
        if !hasCompletedFirstSetup { openSetup() }
    }

    private func openSetup() {
        showSetup = true
        capture.wantsLiveMeasurement = true
    }

    private func closeSetup() {
        showSetup = false
        capture.wantsLiveMeasurement = false
        hasCompletedFirstSetup = true
    }
}

/// Everything demoted off the HUD. Nothing is deleted — dropped frames and
/// ignored triggers corrupt or lose measurements, so they stay one tap away.
struct StatusSheet: View {
    @EnvironmentObject private var model: AppModel
    /// Observed directly. Every number on this sheet is a live camera or
    /// placement reading, and AppModel no longer republishes their changes —
    /// reaching them through `model` would render the sheet once and freeze
    /// it, which is worse than not having it.
    @ObservedObject var capture: CaptureController
    @ObservedObject var wizard: PlacementWizard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Camera") {
                    row("Format", capture.activeFormatDescription.isEmpty
                        ? "starting…" : capture.activeFormatDescription)
                    row("Frame rate", String(format: "%.0f fps", capture.fps))
                    row("Field of view", String(format: "%.0f°", capture.fieldOfViewDeg))
                    row("Exposure", capture.exposureLocked ? "locked" : "auto")
                    if let interruption = capture.interruptionMessage {
                        Text(interruption).foregroundStyle(Theme.warn)
                    }
                }
                Section {
                    row("Dropped frames", "\(capture.droppedFrameCount)")
                    Text("Every measurement assumes a constant frame interval. Dropped frames break that, so any swing captured while this was climbing is flagged.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Timing") }

                Section {
                    row("Contact level", String(format: "%.0f dB", max(0, capture.triggerLevelDb)))
                    row("Threshold", String(format: "%.0f dB", model.settings.triggerDb))
                    row("Ignored — no hitter", "\(capture.suppressedTriggerCount)")
                    Text("Clap near the phone: the bar above the buttons should jump past the notch. If it does not, the trigger will not hear contact either — use Manual.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Trigger") }

                Section("Placement") {
                    row("Distance", wizard.derivedDistanceM.map { Fmt.m($0) } ?? "—")
                    row("Scale source", wizard.scaleSource.rawValue)
                    row("Roll", wizard.level.hasReading
                        ? String(format: "%+.1f°", wizard.level.rollDeg) : "unknown")
                    row("Tilt", wizard.level.hasReading
                        ? String(format: "%+.1f°", wizard.level.tiltDeg) : "unknown")
                    ForEach(wizard.advisories.indices, id: \.self) { i in
                        Text(wizard.advisories[i].text)
                            .font(.caption)
                            .foregroundStyle(wizard.advisories[i].level == .blocking
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
