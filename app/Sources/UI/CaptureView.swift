// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// The field screen: preview, arm/disarm, and the last swing's numbers big
/// enough to read from the batter's box.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSetup = false
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: model.capture.session)
                    .ignoresSafeArea()
                    .onTapGesture { model.capture.lockExposureAndFocus() }

                VStack(spacing: 10) {
                    topBar
                    if let interruption = model.capture.interruptionMessage {
                        StatChip(text: interruption, color: Theme.warn, filled: true)
                    }
                    Spacer()
                    if let swing = model.lastSwing { lastSwingCard(swing) }
                    if let progress = model.analysisProgress { analysisBar(progress) }
                    controlBar
                }
                .padding(12)
            }
            .navigationBarHidden(true)
            .task { await begin() }
            .onDisappear { model.stopCapture() }
            .sheet(isPresented: $showSetup) {
                SetupView().environmentObject(model)
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
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.capture.activeFormatDescription.isEmpty
                     ? "STARTING CAMERA…" : model.capture.activeFormatDescription)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 5) {
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
                    StatChip(text: "\(model.capture.suppressedTriggerCount) noises ignored (no hitter)",
                             color: Theme.steel)
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
                .tint(Theme.yellow)
                .font(.system(size: 13, weight: .bold))

                triggerMeter
            }
        }
        .padding(10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Live contact-impulse level against the trigger threshold — the same
    /// measurement `check_audio_trigger.py` makes, so a venue can be judged
    /// before a single swing.
    private var triggerMeter: some View {
        let db = model.capture.triggerLevelDb
        let fraction = max(0, min(1, db / max(1, model.settings.triggerDb * 1.5)))
        return VStack(alignment: .trailing, spacing: 3) {
            Text(String(format: "%.0f dB", max(0, db)))
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 110, height: 6)
                Capsule()
                    .fill(db >= model.settings.triggerDb ? Theme.pass : Theme.yellow)
                    .frame(width: 110 * fraction, height: 6)
            }
        }
    }

    private func lastSwingCard(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                MetricTile(label: "Launch",
                           value: String(format: "%.1f", swing.launchAngleDeg),
                           unit: "°")
                MetricTile(label: "Exit velo",
                           value: String(format: "%.1f", swing.exitVeloMph),
                           unit: "mph")
                if let attack = swing.batAttackAngleDeg {
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
                    ConfidenceRow(flags: swing.flags)
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
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button {
                showSetup = true
            } label: {
                Text("Set up")
            }
            .buttonStyle(OutlineButtonStyle())
            .frame(width: 96)

            Button {
                model.capture.isArmed ? model.disarm() : model.arm()
            } label: {
                Text(model.capture.isArmed ? "● Armed" : "Arm")
            }
            .buttonStyle(SlabButtonStyle(fill: model.capture.isArmed ? Theme.fail : Theme.yellow,
                                         textColor: model.capture.isArmed ? .white : .black))
            .disabled(model.capture.isRecordingClip)

            Button {
                model.triggerManually()
            } label: {
                Text("Manual")
            }
            .buttonStyle(OutlineButtonStyle())
            .frame(width: 96)
            .disabled(model.capture.isRecordingClip)
        }
    }
}
