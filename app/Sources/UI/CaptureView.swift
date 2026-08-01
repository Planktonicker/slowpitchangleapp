import AVFoundation
import SwiftUI

/// The field screen: preview, arm/disarm, and the last swing's numbers.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showWizard = false
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: model.capture.session)
                    .ignoresSafeArea()
                    .onTapGesture { model.capture.lockExposureAndFocus() }

                VStack {
                    topBar
                    Spacer()
                    if let swing = model.lastSwing { lastSwingCard(swing) }
                    if let progress = model.analysisProgress { analysisBar(progress) }
                    controlBar
                }
                .padding()
            }
            .navigationBarHidden(true)
            .task { await begin() }
            .onDisappear { model.stopCapture() }
            .sheet(isPresented: $showWizard) {
                WizardView().environmentObject(model)
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
    }

    private func begin() async {
        guard await CaptureController.requestPermissions() else {
            permissionDenied = true
            return
        }
        model.startCapture()
        model.wizard.startSensors()
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.capture.activeFormatDescription.isEmpty
                     ? "starting camera…" : model.capture.activeFormatDescription)
                    .font(.caption.monospaced())
                if model.capture.droppedFrameCount > 0 {
                    // Dropped frames corrupt the constant frame interval every
                    // measurement rests on, so this is never hidden.
                    Label("\(model.capture.droppedFrameCount) dropped frames",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if model.capture.exposureLocked {
                    Label("AE/AF locked", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Setting", selection: $model.currentSetting) {
                    ForEach(SwingSetting.allCases) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)

                triggerMeter
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Live contact-impulse level against the trigger threshold — the same
    /// measurement `check_audio_trigger.py` makes, so a venue can be judged
    /// before a single swing.
    private var triggerMeter: some View {
        let db = model.capture.triggerLevelDb
        let fraction = max(0, min(1, db / max(1, model.settings.triggerDb * 1.5)))
        return VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.0f dB over floor", max(0, db)))
                .font(.caption2.monospacedDigit())
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 110, height: 5)
                Capsule()
                    .fill(db >= model.settings.triggerDb ? Color.green : Color.yellow)
                    .frame(width: 110 * fraction, height: 5)
            }
        }
    }

    private func lastSwingCard(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MetricTile(label: "Launch angle",
                           value: String(format: "%.1f", swing.launchAngleDeg),
                           unit: "°")
                MetricTile(label: "Exit velo",
                           value: String(format: "%.1f", swing.exitVeloMph),
                           unit: "mph")
                if let attack = swing.batAttackAngleDeg {
                    MetricTile(label: "Attack angle",
                               value: String(format: "%.1f", attack),
                               unit: "°",
                               tint: .secondary)
                }
            }
            if swing.trackedFrames == 0 {
                Label("No ball track in that clip", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack {
                    Text("\(swing.trackedFrames) frames")
                        .font(.caption).foregroundStyle(.secondary)
                    ConfidenceRow(flags: swing.flags)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func analysisBar(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Analyzing swing…").font(.caption)
            ProgressView(value: progress)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                showWizard = true
            } label: {
                Label("Placement", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                model.capture.isArmed ? model.disarm() : model.arm()
            } label: {
                Label(model.capture.isArmed ? "Armed" : "Arm",
                      systemImage: model.capture.isArmed ? "record.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.capture.isArmed ? .red : .accentColor)
            .disabled(model.capture.isRecordingClip)

            Button {
                model.triggerManually()
            } label: {
                Label("Manual", systemImage: "hand.tap")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.capture.isRecordingClip)
        }
        .padding(10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .tint(.white)
    }
}
