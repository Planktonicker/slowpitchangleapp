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
    /// Inline playback rate. `VideoPlayer`'s own controls do not offer one —
    /// AVPlayerViewController has a speed menu, the SwiftUI wrapper shows a
    /// reduced set without it — so at 240fps the flight was over before it
    /// registered. Same default as the review screen.
    @State private var inlineSpeed: Float = 0.25
    /// Hoisted out of the body. An array literal of `Float` inside a large
    /// SwiftUI body is one of the reliable ways to make the type checker take
    /// minutes over a file that used to compile in seconds.
    private static let speeds: [Float] = [0.1, 0.25, 0.5, 1.0]
    @State private var track: [BallObservation] = []
    @State private var videoSize: CGSize = .zero
    @State private var showOverlay = true
    @State private var showReview = false
    /// The video track's rotation. Without it the overlay is drawn in
    /// encoded-buffer space over a picture the player has already turned — see
    /// `VideoOverlayGeometry`.
    @State private var videoTransform: CGAffineTransform = .identity
    // Optional Doubles bound with .number formatting, NOT strings parsed with
    // Double(String): the decimal pad produces a comma in most non-US locales,
    // Double("1,5") is nil, and Save silently wiped previously saved ground
    // truth with no error either way.
    @State private var hangEntry: Double?
    @State private var carryEntry: Double?
    /// What is on top, if anything. One optional instead of three booleans —
    /// see the note on the `.sheet` modifier.
    enum DetailSheet: Identifiable {
        case share([URL])
        case note(SwingRead.Note)
        case report(String)

        var id: String {
            switch self {
            case .share(let urls): return "share:" + urls.map(\.lastPathComponent).joined(separator: ",")
            case .note(let n):     return "note:" + n.id
            case .report:          return "report"
            }
        }
    }
    @State private var sheet: DetailSheet?
    @State private var showDetail = false
    @State private var exporting: Double?
    @State private var exportError: String?

    var body: some View {
        List {
            if swing.captureFlags.contains(.ballUnconfirmed) {
                Section { unconfirmedBallNotice }
            }
            if swing.clipFilename != nil {
                Section { replay } header: { Text("Replay") }
            }
            Section("Measured") { measured }
            if let read = contactRead {
                Section("Contact") { contactSection(read) }
            }
            if let body = swing.body, body.hasAnything {
                Section("Body") { bodySection(body) }
            }
            // Everything below is diagnostics, and it is collapsed rather than
            // deleted. A hitter does not need millimetres per pixel; the person
            // working out why a reading looks wrong needs nothing else, and
            // deleting the evidence to tidy the screen would leave a flag on
            // the confidence row with no way to find out what caused it.
            Section {
                DisclosureGroup("Measurement detail", isExpanded: $showDetail) {
                    measurementDetail
                }
                .tint(Theme.steel)
            }
            if model.isInSession { Section("Round") { roundMembership } }
            Section {
                actions
            } footer: {
                Text("\"Export everything\" is the clip, ball track, pose track, the detector's full candidate trace and the stage-by-stage report — the whole evidence set for one swing. The track CSV is the format analyze_swing.py reads, so a suspicious reading can be re-run on the Mac against the reference implementation.")
            }
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
        // ONE sheet modifier, switching on what to show.
        //
        // There were three stacked on this view — share, body note, report —
        // and SwiftUI does not reliably honour that: the later ones win and the
        // earlier ones silently do nothing. Share was first, so adding the
        // body-note card broke "Export everything for this swing" without
        // touching a line of it. The button ran, the files were found, and no
        // sheet ever appeared.
        .sheet(item: $sheet) { which in
            switch which {
            case .share(let urls):
                ShareSheet(items: urls)
            case .note(let note):
                BodyNoteCard(note: note) { sheet = nil }
            case .report(let text):
                DiagnosticsView(report: text,
                                clipURL: swing.clipFilename.map { ClipStore.clipURL(named: $0) })
            }
        }
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
            HStack(spacing: 8) {
                Text("SPEED").font(.caption2).foregroundStyle(.secondary)
                ForEach(Self.speeds, id: \.self) { s in
                    Button {
                        inlineSpeed = s
                        // Only while playing: setting `rate` on a paused
                        // player starts it, and a speed button is not a play
                        // button.
                        if player.timeControlStatus == .playing { player.rate = s }
                    } label: {
                        Text(s == 1.0 ? "1×" : String(format: "%g×", Double(s)))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(inlineSpeed == s ? Theme.yellow.opacity(0.25) : .clear,
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                inlineSpeed == s ? Theme.yellow : Theme.steel.opacity(0.5),
                                lineWidth: 1))
                            .foregroundStyle(inlineSpeed == s ? Theme.yellow : Theme.steel)
                    }
                    .buttonStyle(.plain)
                }
            }
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
            if let notes = swing.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// The diagnostics, behind one disclosure. Same content as the four
    /// sections this replaced — how the track was measured, whether the two
    /// independent scales agree, where the camera was, and the ground-truth
    /// entry that gate G3 needs.
    private var measurementDetail: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                detail("Tracked frames", "\(swing.trackedFrames)")
                detail("Flight measured", String(format: "%.0f ms", swing.trackDurationS * 1000))
                detail("Fit residual", String(format: "%.2f px", swing.fitRmsPx))
                detail("Frame rate", String(format: "%.0f fps", swing.fps))
                detail("Found by", swing.usedVisionHint ? "Vision + reference detector" : "reference detector")
                detail("Triggered", swing.autoTriggered ? "automatically (audio)" : "manually")
            }
            if swing.trackedFrames > 0 {
                Divider()
                sectionLabel("Scale cross-check")
                scaleSection
            }
            Divider()
            sectionLabel("Placement")
            placement
            Divider()
            sectionLabel("Ground truth (gate G3)")
            groundTruth
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.label(10)).tracking(1.2)
            .foregroundStyle(Theme.steel)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // What the numbers mean, in order, before the caveat about what
            // this camera cannot see. A hitter cannot act on "stride 41 cm";
            // they can act on what a stride the hips did not follow means.
            ForEach(SwingRead.body(body)) { note in
                Button { sheet = .note(note) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(note.title)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            if note.isConvention {
                                Text("COACHING")
                                    .font(Theme.label(8)).tracking(0.8)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Theme.surface, in: Capsule())
                                    .foregroundStyle(Theme.steel)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "info.circle")
                                .font(.caption).foregroundStyle(Theme.steel)
                        }
                        // Two lines here, all of it in the card. The list was
                        // cutting explanations mid-sentence — "A long stride
                        // the hips do not fol…" — which is worse than not
                        // showing them, because a truncated reason reads as a
                        // complete one that stopped making sense.
                        Text(note.text)
                            .font(.callout).foregroundStyle(Theme.steel)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Anything marked COACHING is convention or physics, not something this app measured you against — there are no published slow-pitch norms to score a swing on. What these are genuinely good for is watching your own numbers move.")
                .font(.caption2).foregroundStyle(Theme.steel.opacity(0.85))
            Text("Sagittal-plane only — what a side-on camera measures within a few degrees of a motion-capture lab. No hip–shoulder separation, X-factor or torque: rotation about the vertical axis is viewed nearly edge-on from here, and torque needs segment masses and ground forces no camera can see. Compare these to your own numbers over time; there are no published slow-pitch norms to score them against.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contactRead: SwingRead.Contact? {
        SwingRead.contact(smash: swing.smashFactor,
                          quality: swing.smashQuality,
                          contactQuality: swing.contactQuality,
                          undercutMm: swing.undercutMm,
                          launchAngleDeg: swing.launchAngleDeg)
    }

    /// What happened at the collision, said in a sentence before any number.
    ///
    /// The order is the point. "Flush, and under the ball — the one that
    /// carries" is what somebody can act on; 1.38 and +18 mm are the evidence
    /// for it. Leading with the numbers makes the reader do the interpretation,
    /// and the interpretation is the part the app is actually able to help with.
    private func contactSection(_ read: SwingRead.Contact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(read.headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(read.why)
                .font(.callout).foregroundStyle(Theme.steel)
            if let tryThis = read.tryThis {
                Label(tryThis, systemImage: "arrow.turn.down.right")
                    .font(.callout)
                    .foregroundStyle(Theme.yellow)
            }
            if let attack = swing.batAttackAngleDeg {
                Divider()
                batSection(attack)
            }
        }
        .padding(.vertical, 2)
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
                TextField("s", value: $hangEntry, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            HStack {
                Text("Carry, paced off")
                Spacer()
                TextField("m", value: $carryEntry, format: .number.precision(.fractionLength(0...1)))
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

    /// Whether this swing counts toward the round in progress.
    ///
    /// A round is a grouping the hitter makes, not a fact about the footage —
    /// so it has to be editable. Without this the only way to fix a swing that
    /// landed in the wrong round, or in none, was to delete it and re-import.
    @ViewBuilder private var roundMembership: some View {
        if swing.sessionID == model.session?.id {
            HStack {
                Label("In this round", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.pass)
                Spacer()
                // `.borderless`, or the whole row becomes this button's tap
                // target and merely looking at the row removes the swing.
                Button("Remove") { model.removeFromSession(swing) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.steel)
            }
            .font(.callout)
        } else {
            Button {
                model.addToCurrentSession(swing)
            } label: {
                Label("Add to this round", systemImage: "plus.circle")
            }
            Text(swing.sessionID == nil
                 ? "This swing belongs to no round. Adding it counts it in the summary when the round ends."
                 : "This swing belongs to an earlier round. Adding it moves it into this one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Each action is its OWN row.
    ///
    /// They used to sit in one VStack inside one Section, which in a List is a
    /// single row containing four buttons — and a row has one tap target, so
    /// pressing any of them ran whichever one SwiftUI decided the row meant.
    /// Every button on this screen did the same thing, which is the most
    /// confusing kind of broken: it looks like four choices and behaves like
    /// one. A Section whose children are the buttons themselves gives each its
    /// own row and its own tap.
    @ViewBuilder private var actions: some View {
        Button { model.reanalyze(swing) } label: {
            Label("Re-analyze with current settings", systemImage: "arrow.clockwise")
        }
        Button { model.reanalyze(swing, forceFallback: true) } label: {
            Label("Re-analyze without Vision", systemImage: "eye.slash")
        }
        // The artefact that leaves the phone. A raw 240fps clip plays in a
        // third of a second and shows nothing; this is the version a coach can
        // actually watch.
        if swing.clipFilename != nil {
            if let progress = exporting {
                HStack {
                    ProgressView(value: progress).tint(Theme.yellow)
                    Text("\(Int(progress * 100))%")
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.steel)
                }
            } else {
                Button { exportSlowMo() } label: {
                    Label("Export slow-motion with overlay", systemImage: "film")
                }
            }
        }
        // The report for THIS swing, not for the last import. It used to be
        // reachable only from the history screen's menu and only ever showed
        // the most recent imported clip — so during a live session the one
        // screen that names the failing stage described a different swing.
        if swing.diagnosticsFilename != nil {
            Button { openReport() } label: {
                Label("Analysis report", systemImage: "doc.text.magnifyingglass")
            }
        }
        // Everything about this one swing, in one share. The pieces were always
        // on the phone and each needed a different screen to get at; asking
        // somebody to assemble five files from four screens is how a bug report
        // ends up being a screenshot instead, and a screenshot is the one form
        // of evidence that cannot be re-run.
        Button { shareAuditBundle() } label: {
            Label("Export everything for this swing", systemImage: "shippingbox")
        }
        if let exportError {
            Text(exportError).font(.caption).foregroundStyle(Theme.fail)
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
        hangEntry = swing.hangS
        carryEntry = swing.carryM

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

    private func openReport() {
        guard let name = swing.diagnosticsFilename,
              let text = try? String(contentsOf: ClipStore.trackURL(named: name),
                                     encoding: .utf8) else {
            exportError = "The report for this swing is no longer on disk."
            return
        }
        sheet = .report(text)
    }

    /// Every file this swing produced, in one share sheet.
    ///
    /// Missing pieces are skipped rather than reported: a swing with no pose
    /// track is a swing the body pass was off for, which the record already
    /// says, and a share sheet is the wrong place to learn it.
    private func shareAuditBundle() {
        var urls: [URL] = []
        if let clip = swing.clipFilename {
            let u = ClipStore.clipURL(named: clip)
            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
        }
        for name in [swing.trackCSVFilename, swing.poseFilename,
                     swing.traceFilename, swing.diagnosticsFilename] {
            guard let name else { continue }
            let u = ClipStore.trackURL(named: name)
            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
        }
        guard !urls.isEmpty else {
            // Name what is missing rather than shrugging. "Nothing to export"
            // is the same sentence whether the clip was never kept, the
            // analysis wrote no track, or storage was cleared — and those want
            // three different responses.
            var why: [String] = []
            if swing.clipFilename == nil { why.append("no clip was kept (Settings → Storage)") }
            if swing.trackCSVFilename == nil { why.append("no ball track — nothing was measured") }
            exportError = why.isEmpty
                ? "The files for this swing are recorded but missing from disk — storage was probably cleared."
                : "Nothing to export: " + why.joined(separator: "; ") + "."
            return
        }
        exportError = nil
        sheet = .share(urls)
    }

    /// Render the overlay into a shareable file.
    ///
    /// The pose track is re-read from disk rather than kept in memory: it is
    /// only needed at this moment, and holding every joint of every frame alive
    /// for the whole time a detail screen is open costs more than reading it
    /// back once.
    private func exportSlowMo() {
        guard let clip = swing.clipFilename else { return }
        let url = ClipStore.clipURL(named: clip)
        guard FileManager.default.fileExists(atPath: url.path) else {
            exportError = "The clip file is gone — it was not kept, or storage was cleared."
            return
        }
        exportError = nil
        exporting = 0

        var pose: [PoseObservation] = []
        if let name = swing.poseFilename,
           let data = try? Data(contentsOf: ClipStore.trackURL(named: name)) {
            pose = (try? JSONDecoder().decode([PoseObservation].self, from: data)) ?? []
        }

        var options = OverlayVideoExporter.Options()
        options.caption = SwingRead.exportCaption(launchAngleDeg: swing.launchAngleDeg,
                                                  exitVeloMph: swing.exitVeloMph,
                                                  smash: swing.smashFactor,
                                                  unit: model.settings.speedUnit)
        let batPath = swing.batPathPx
        let observations = track
        let contact = swing.contactTime

        Task {
            do {
                // Through the decoder-contention retry: exporting mid-round
                // decodes the clip while the 240fps session may hold the
                // hardware decoder, and dying with "cannot read" when a
                // one-shot camera pause fixes it would be a poor trade.
                let out = try await model.runFreeingDecoderIfNeeded {
                    try await OverlayVideoExporter.export(
                        clip: url, track: observations, pose: pose, batPath: batPath,
                        contactTime: contact, options: options,
                        progress: { p in Task { @MainActor in exporting = p } })
                }
                await MainActor.run {
                    exporting = nil
                    sheet = .share([out])
                }
            } catch {
                await MainActor.run {
                    exporting = nil
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func saveGroundTruth() {
        var updated = swing
        updated.hangS = hangEntry
        updated.carryM = carryEntry
        swing = updated
        model.update(updated)
    }
}
