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
    /// Seeded from the list, then kept in step with the store.
    ///
    /// `@State` alone made this a snapshot taken when the screen opened, so a
    /// re-analysis — which replaces the record in the store — left the detail
    /// view and everything it presents showing the numbers from before. The
    /// `onChange` below is what makes "Point at the ball" visibly do anything.
    @State var swing: SwingDTO

    @State private var player: AVPlayer?
    @State private var track: [BallObservation] = []
    @State private var videoSize: CGSize = .zero
    @State private var showOverlay = true
    @State private var showReview = false
    /// The video track's rotation. Without it the overlay is drawn in
    /// encoded-buffer space over a picture the player has already turned — see
    /// `VideoOverlayGeometry`.
    @State private var videoTransform: CGAffineTransform = .identity
    @State private var hangText = ""
    @State private var carryText = ""
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        List {
            if swing.captureFlags.contains(.ballUnconfirmed) {
                Section { unconfirmedBallNotice }
            }
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
            if let body = swing.body, body.hasAnything {
                Section("Body") { bodySection(body) }
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
        // Re-analysis replaces the stored record; pick the new one up and
        // re-read the track files it just rewrote.
        .onChange(of: model.swings) { _, swings in
            guard let fresh = swings.first(where: { $0.id == swing.id }),
                  fresh != swing else { return }
            swing = fresh
            Task { await load() }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        .fullScreenCover(isPresented: $showReview) { TrackReviewView(swing: swing) }
    }

    /// Said at the top, in full, before any number is shown.
    ///
    /// The measured values are still on the screen below — they are the
    /// evidence for what went wrong, and hiding them would make this harder to
    /// debug, not safer. What changes is that they are no longer presented as
    /// a swing.
    private var unconfirmedBallNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No struck ball identified", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.warn)
            Text("The numbers below describe whatever the detector settled on in this clip, not the swing. Treat them as a diagnostic, not a measurement.")
                .font(.callout).foregroundStyle(Theme.steel)
            if let notes = swing.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(Theme.steel)
            }
            Button {
                showReview = true
            } label: {
                Label("Open the clip and point at the ball", systemImage: "hand.tap")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(Theme.pass)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Replay

    @ViewBuilder private var replay: some View {
        if let player {
            ZStack {
                VideoPlayer(player: player)
                    .aspectRatio(displayAspect, contentMode: .fit)
                if showOverlay, videoSize != .zero {
                    GeometryReader { geo in
                        overlay(in: geo.size)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: 260)
            Toggle("Show tracked path", isOn: $showOverlay)
            // The inline strip shows the path; it cannot show WHEN each point
            // was found, or whether the hitter was ever seen. Both are what
            // somebody asking "why did this fail" actually needs.
            Button {
                showReview = true
            } label: {
                Label("Play with tracking overlaid", systemImage: "figure.stand.line.dotted.figure.stand")
            }
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
        // Shared with the full-screen review, and correct for rotated clips.
        // This used to letterbox the NATURAL size and ignore the preferred
        // transform, so on any portrait-shot import — which is most imported
        // footage — the path was drawn ninety degrees out over footage that
        // was fine, which reads as a broken tracker.
        let scale = VideoOverlayGeometry.scale(natural: videoSize,
                                               transform: videoTransform, in: size)
        func map(_ x: Double, _ y: Double) -> CGPoint {
            VideoOverlayGeometry.viewPoint(bufferPoint: CGPoint(x: x, y: y),
                                           natural: videoSize,
                                           transform: videoTransform, in: size)
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
                        .frame(width: max(4, o.diameterPx * Double(scale)),
                               height: max(4, o.diameterPx * Double(scale)))
                        .position(map(o.x, o.y))
                }
            }
        }
    }

    /// Aspect of the picture as shown, which for a rotated clip is not the
    /// aspect of the encoded frame.
    private var displayAspect: CGFloat {
        guard videoSize != .zero else { return 16.0 / 9.0 }
        let d = VideoOverlayGeometry.displaySize(natural: videoSize, transform: videoTransform)
        guard d.height > 0 else { return 16.0 / 9.0 }
        return d.width / d.height
    }

    // MARK: - Sections

    private var measured: some View {
        VStack(spacing: 12) {
            HStack {
                MetricTile(label: "Launch angle",
                           value: String(format: "%.1f", swing.launchAngleDeg), unit: "°")
                MetricTile(label: "Exit velo",
                           value: model.settings.speedUnit.format(mph: swing.exitVeloMph),
                           unit: model.settings.speedUnit.suffix)
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
            detail("From ball size", Fmt.mmPerPx(swing.scaleBallMPerPx))
            detail("From gravity (drag-aware)",
                   swing.scaleGravityMPerPx.map { Fmt.mmPerPx($0) } ?? "not available")
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

    /// Sagittal-plane measurements only.
    ///
    /// The closing note is not decoration. Every swing app in this space shows
    /// hip-shoulder separation, and a user who does not see it here will assume
    /// it was forgotten rather than deliberately withheld — so the screen says
    /// which questions this camera can answer and which it cannot.
    private func bodySection(_ body: BodyMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let stride = body.strideM {
                    MetricTile(label: "Stride", value: String(format: "%.0f", stride * 100),
                               unit: "cm", tint: .white)
                }
                if let head = body.headDriftM {
                    MetricTile(label: "Head move", value: String(format: "%.0f", head * 100),
                               unit: "cm", tint: .white)
                }
            }
            HStack {
                if let shift = body.weightShiftM {
                    MetricTile(label: "Weight shift", value: String(format: "%.0f", shift * 100),
                               unit: "cm", tint: .white)
                }
                if let knee = body.frontKneeDeg {
                    MetricTile(label: "Front knee", value: String(format: "%.0f", knee),
                               unit: "°", tint: .white)
                }
            }
            if let tilt = body.spineTiltDeg {
                detail("Spine tilt at contact", String(format: "%.0f°", tilt))
            }
            if body.coverage < 0.8 {
                StatChip(text: String(format: "Hitter seen in %.0f%% of frames",
                                      body.coverage * 100),
                         color: Theme.warn)
            }
            Text("Sagittal-plane only — what a side-on camera measures within a few degrees of a motion-capture lab. No hip–shoulder separation, X-factor or torque: rotation about the vertical axis is viewed nearly edge-on from here, and torque needs segment masses and ground forces no camera can see. Compare these to your own numbers over time; there are no published slow-pitch norms to score them against.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func batSection(_ attack: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                MetricTile(label: "Attack angle", value: String(format: "%.1f", attack), unit: "°")
                if let bs = swing.batSpeedMph {
                    MetricTile(label: "Bat speed",
                               value: model.settings.speedUnit.format(mph: bs),
                               unit: model.settings.speedUnit.suffix)
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
            if let u = swing.undercutMm {
                HStack {
                    Text("Contact").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.0f mm", u)).monospacedDigit()
                    Text(swing.contactQuality.label)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(contactColour)
                }
                .font(.callout)
                Text("How far the barrel centre passed under (+) or over (−) the ball centre — measured tape-to-ball, so it reads true when contact happens near the tape. Slightly under (~10–25 mm) puts backspin and carry on the ball; over it drives it into the ground.")
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
                TextField("m", text: $carryText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Button("Save ground truth") { saveGroundTruth() }
                .buttonStyle(.bordered)

            if swing.hangS != nil || swing.carryM != nil {
                let check = FlightModel.check(
                    metrics: metricsForFlight, hangS: swing.hangS, carryM: swing.carryM)
                Divider()
                detail("Model hang", String(format: "%.2f s", check.model.hangS))
                detail("Model carry", Fmt.m(check.model.carryM))
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
            Text("Stopwatch the hang and pace off where it lands (about 0.9 m per big step). The drag model turns the measured launch angle and exit velocity into a predicted carry — if they match, the numbers are real.")
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
            detail("Camera distance", swing.cameraDistanceM.map { Fmt.m($0) } ?? "—")
            detail("Lens height", swing.lensHeightM.map { Fmt.m($0, decimals: 2) } ?? "—")
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
        carryText = swing.carryM.map { String(format: "%.1f", $0) } ?? ""

        if let name = swing.trackCSVFilename,
           let text = try? String(contentsOf: ClipStore.trackURL(named: name), encoding: .utf8) {
            track = TrackCSV.parse(text).track
        }

        guard let clip = swing.clipFilename else { return }
        let url = ClipStore.clipURL(named: clip)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await videoTrack.load(.naturalSize) {
                videoSize = CGSize(width: abs(size.width), height: abs(size.height))
            }
            if let t = try? await videoTrack.load(.preferredTransform) {
                videoTransform = t
            }
        }
        player = AVPlayer(url: url)
    }

    private func saveGroundTruth() {
        var updated = swing
        updated.hangS = Double(hangText.trimmingCharacters(in: .whitespaces))
        updated.carryM = Double(carryText.trimmingCharacters(in: .whitespaces))
        swing = updated
        model.update(updated)
    }
}
