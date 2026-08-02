// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import AVKit
import SwiftUI

/// One swing in full: replay with the tracked path drawn over it, every
/// measured number, and the hand-entered ground truth that feeds gate G3.
struct SwingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State var swing: SwingDTO

    @State private var player: AVPlayer?
    @State private var track: [BallObservation] = []
    @State private var videoSize: CGSize = .zero
    @State private var showOverlay = true
    @State private var hangText = ""
    @State private var carryText = ""
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        List {
            if swing.clipFilename != nil {
                Section { replay } header: { Text("Replay") }
            }
            Section("Measured") { measured }
            if swing.trackedFrames > 0 {
                Section("Scale cross-check") { scaleSection }
            }
            if let attack = swing.batAttackAngleDeg {
                Section("Bat") { batSection(attack) }
            }
            Section("Ground truth (gate G3)") { groundTruth }
            Section("Placement") { placement }
            Section { actions }
        }
        .navigationTitle(swing.clipFilename ?? "Swing")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.black)
        .task { await load() }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
    }

    // MARK: - Replay

    @ViewBuilder private var replay: some View {
        if let player {
            ZStack {
                VideoPlayer(player: player)
                    .aspectRatio(videoSize == .zero ? 16.0 / 9.0
                                 : videoSize.width / videoSize.height,
                                 contentMode: .fit)
                if showOverlay, videoSize != .zero {
                    GeometryReader { geo in
                        overlay(in: geo.size)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: 260)
            Toggle("Show tracked path", isOn: $showOverlay)
        } else {
            Text("Clip not found on this device.")
                .foregroundStyle(.secondary)
        }
    }

    /// The tracked ball path and the barrel path, mapped from image pixels
    /// into the view. Kept as a static overlay rather than animated to the
    /// playhead: at 240fps the whole flight is a fraction of a second, and the
    /// shape is what tells you whether the track is sane.
    private func overlay(in size: CGSize) -> some View {
        let scale = min(size.width / videoSize.width, size.height / videoSize.height)
        let offsetX = (size.width - videoSize.width * scale) / 2
        let offsetY = (size.height - videoSize.height * scale) / 2
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        return ZStack {
            if track.count >= 2 {
                Path { p in
                    p.move(to: map(track[0].x, track[0].y))
                    for o in track.dropFirst() { p.addLine(to: map(o.x, o.y)) }
                }
                .stroke(.red, lineWidth: 2)

                ForEach(Array(track.enumerated()), id: \.offset) { _, o in
                    Circle()
                        .stroke(.green, lineWidth: 1)
                        .frame(width: max(4, o.diameterPx * scale),
                               height: max(4, o.diameterPx * scale))
                        .position(map(o.x, o.y))
                }
            }
        }
    }

    // MARK: - Sections

    private var measured: some View {
        VStack(spacing: 12) {
            HStack {
                MetricTile(label: "Launch angle",
                           value: String(format: "%.1f", swing.launchAngleDeg), unit: "°")
                MetricTile(label: "Exit velo",
                           value: String(format: "%.1f", swing.exitVeloMph), unit: "mph")
            }
            ConfidenceRow(flags: swing.flags, captureFlags: swing.captureFlags)
            detail("Tracked frames", "\(swing.trackedFrames)")
            detail("Flight measured", String(format: "%.0f ms", swing.trackDurationS * 1000))
            detail("Fit residual", String(format: "%.2f px", swing.fitRmsPx))
            detail("Frame rate", String(format: "%.0f fps", swing.fps))
            detail("Found by", swing.usedVisionHint ? "Vision + reference detector" : "reference detector")
            detail("Triggered", swing.autoTriggered ? "automatically (audio)" : "manually")
            if let notes = swing.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var scaleSection: some View {
        VStack(spacing: 8) {
            detail("From ball size", String(format: "%.3f mm/px", swing.scaleBallMPerPx * 1000))
            detail("From gravity (drag-aware)",
                   swing.scaleGravityMPerPx.map { String(format: "%.3f mm/px", $0 * 1000) } ?? "not available")
            if let d = swing.scaleDisagreement {
                HStack {
                    Text("Disagreement").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", d * 100)).monospacedDigit()
                    GateBadge(passes: d <= SLA.scaleDisagreeTol)
                }
                .font(.callout)
            }
            Text("Two independent estimates of how many metres a pixel is worth. Agreement is what makes a number trustworthy without a radar gun; disagreement is why a reading gets flagged instead of quietly reported.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func batSection(_ attack: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                MetricTile(label: "Attack angle", value: String(format: "%.1f", attack), unit: "°")
                if let bs = swing.batSpeedMph {
                    MetricTile(label: "Bat speed", value: String(format: "%.1f", bs), unit: "mph")
                }
            }
            if let smash = swing.smashFactor {
                HStack {
                    Text("Smash factor").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", smash)).monospacedDigit()
                    Text(swing.smashQuality.label)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(smashColour)
                }
                .font(.callout)
            }
            if let u = swing.undercutIn {
                HStack {
                    Text("Contact").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.2f in", u)).monospacedDigit()
                    Text(swing.contactQuality.label)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(contactColour)
                }
                .font(.callout)
                Text("How far the barrel centre passed under (+) or over (−) the ball centre — measured tape-to-ball, so it reads true when contact happens near the tape. Slightly under (~½–1 in) puts backspin and carry on the ball; over it drives it into the ground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            detail("Frames on the barrel", swing.batFrames.map(String.init) ?? "—")
            Text("Bat speed is the barrel-tape speed at contact, converted with the same scale the exit-velocity reading uses. Smash factor is exit velocity ÷ bat speed — how flush the contact was; ~1.35+ is a well-struck ball. It's exact off a tee and approximate off live pitching, where the ball carries its own speed into the collision.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Attack angle and swing plane come from one side-on view over the few milliseconds before contact — indicative, not a true 3D swing plane (that needs two synced cameras, deferred to v2).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var smashColour: Color {
        switch swing.smashQuality {
        case .flush: return Theme.pass
        case .fair: return Theme.yellow
        case .poor: return Theme.fail
        case .unknown: return Theme.steel
        }
    }

    private var contactColour: Color {
        switch swing.contactQuality {
        case .centered, .underCarry: return Theme.pass
        case .topped, .underPopup: return Theme.warn
        case .implausible, .unknown: return Theme.steel
        }
    }

    private var groundTruth: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hang time")
                Spacer()
                TextField("s", text: $hangText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            HStack {
                Text("Carry, paced off")
                Spacer()
                TextField("ft", text: $carryText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Button("Save ground truth") { saveGroundTruth() }
                .buttonStyle(.bordered)

            if swing.hangS != nil || swing.carryFt != nil {
                let check = FlightModel.check(
                    metrics: metricsForFlight, hangS: swing.hangS, carryFt: swing.carryFt)
                Divider()
                detail("Model hang", String(format: "%.2f s", check.model.hangS))
                detail("Model carry", String(format: "%.0f ft", check.model.carryFt))
                if let err = check.hangErrorPct {
                    HStack {
                        Text("Hang error").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%+.1f%%", err)).monospacedDigit()
                        GateBadge(passes: check.hangPasses)
                    }.font(.callout)
                }
                if let err = check.carryErrorPct {
                    HStack {
                        Text("Carry error").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%+.1f%%", err)).monospacedDigit()
                        GateBadge(passes: check.carryPasses)
                    }.font(.callout)
                }
            }
            Text("Stopwatch the hang and pace off where it lands. The drag model turns the measured launch angle and exit velocity into a predicted carry — if they match, the numbers are real.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metricsForFlight: SwingMetrics {
        SwingMetrics(launchAngleDeg: swing.launchAngleDeg,
                     exitVeloMph: swing.exitVeloMph,
                     exitVeloMps: swing.exitVeloMps,
                     scaleBallMPerPx: swing.scaleBallMPerPx,
                     scaleGravityMPerPx: swing.scaleGravityMPerPx,
                     scaleDisagreement: swing.scaleDisagreement,
                     diameterDrift: swing.diameterDrift,
                     nFrames: swing.trackedFrames,
                     trackDurationS: swing.trackDurationS,
                     fitRmsPx: swing.fitRmsPx,
                     t0: swing.contactTime,
                     vxPxS: 0, vyPxS: 0,
                     flags: swing.flags)
    }

    private var placement: some View {
        VStack(spacing: 8) {
            detail("Setting", swing.setting.displayName)
            detail("Camera distance", swing.cameraDistanceFt.map { String(format: "%.1f ft", $0) } ?? "—")
            detail("Lens height", swing.lensHeightFt.map { String(format: "%.1f ft", $0) } ?? "—")
            detail("Roll correction", swing.cameraRollDeg.map { String(format: "%+.2f°", $0) } ?? "—")
            detail("Diameter drift", String(format: "%+.1f%%", swing.diameterDrift * 100))
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                model.reanalyze(swing)
            } label: {
                Label("Re-analyze with current settings", systemImage: "arrow.clockwise")
            }
            Button {
                model.reanalyze(swing, forceFallback: true)
            } label: {
                Label("Re-analyze without Vision", systemImage: "eye.slash")
            }
            Button {
                var urls: [URL] = []
                if let clip = swing.clipFilename { urls.append(ClipStore.clipURL(named: clip)) }
                if let csv = swing.trackCSVFilename { urls.append(ClipStore.trackURL(named: csv)) }
                shareURLs = urls
                showShare = !urls.isEmpty
            } label: {
                Label("Share clip and track CSV", systemImage: "square.and.arrow.up")
            }
            Text("The track CSV is in the format analyze_swing.py reads, so a suspicious reading can be re-run on the Mac against the reference implementation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: - Loading

    private func load() async {
        hangText = swing.hangS.map { String(format: "%.2f", $0) } ?? ""
        carryText = swing.carryFt.map { String(format: "%.0f", $0) } ?? ""

        if let name = swing.trackCSVFilename,
           let text = try? String(contentsOf: ClipStore.trackURL(named: name), encoding: .utf8) {
            track = TrackCSV.parse(text).track
        }

        guard let clip = swing.clipFilename else { return }
        let url = ClipStore.clipURL(named: clip)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await videoTrack.load(.naturalSize) {
            videoSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        player = AVPlayer(url: url)
    }

    private func saveGroundTruth() {
        var updated = swing
        updated.hangS = Double(hangText.trimmingCharacters(in: .whitespaces))
        updated.carryFt = Double(carryText.trimmingCharacters(in: .whitespaces))
        swing = updated
        model.update(updated)
    }
}
