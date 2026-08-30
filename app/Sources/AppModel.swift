// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import Combine
import Foundation
import QuartzCore
import SwiftUI

/// Ties capture, analysis and storage together.
@MainActor
final class AppModel: ObservableObject {

    let capture = CaptureController()
    let wizard = PlacementWizard()
    let store: SwingStoring

    @Published private(set) var swings: [SwingDTO] = []
    @Published var currentSetting: SwingSetting = .tee
    @Published private(set) var analysisProgress: Double?
    @Published private(set) var lastSwing: SwingDTO?
    /// Swings captured since the last arm. Shown on the HUD so a player can
    /// see the session is progressing without walking back to the phone.
    @Published private(set) var sessionSwingCount = 0
    @Published var banner: Banner?
    /// Stage-by-stage report from the last imported clip, kept whether the
    /// analysis succeeded or failed. The failures are the ones worth reading,
    /// which is why it is not attached to the swing record — a clip that
    /// produced no swing produces no record to attach it to.
    @Published var lastDiagnostics: String?
    /// The clip the last import ran on, kept whether it measured or not.
    ///
    /// Kept *especially* when it did not: a clip the pipeline could make
    /// nothing of is the one whose frames are worth looking at. Replaced on the
    /// next import, so at most one unreferenced file exists at a time.
    @Published var lastImportedClip: URL?
    @Published var settings = AppSettings.load() {
        didSet {
            settings.save()
            capture.requireHitterToTrigger = settings.requireHitter
            capture.visionOrientationOverride = settings.visionOrientation.orientation
            capture.triggerThresholdDb = settings.triggerDb
        }
    }

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        var id = UUID()
        var kind: Kind
        var text: String
    }

    var scoreboard: ValidationScoreboard { ValidationScoreboard.build(from: swings) }

    var isAnalyzing: Bool { analysisProgress != nil }

    init(store: SwingStoring) {
        self.store = store
        capture.onClip = { [weak self] output in
            self?.handleClip(output, autoTriggered: true)
        }
        capture.onError = { [weak self] message in
            self?.banner = Banner(kind: .error, text: message)
        }

        // NOT done here: republishing capture.objectWillChange and
        // wizard.objectWillChange into this object's own objectWillChange.
        //
        // It looks like the obvious fix for "SwiftUI observes AppModel, not
        // the objects hanging off it", and it works — by invalidating every
        // view in the app twenty times a second. The trigger meter publishes
        // at 10 Hz and the level sensor at 10 Hz, so every one of those ticks
        // re-evaluated the whole TabView: the capture HUD, the setup overlay,
        // and every other tab the user had visited, including ValidationView,
        // which rebuilds its scoreboard from every stored swing each time.
        // That is what made the setting menu feel laggy — it was competing
        // for a main thread already doing twenty full layout passes a second
        // next to a 240fps capture session.
        //
        // Instead, the two views that need live camera and placement state
        // hold them as `@ObservedObject` directly (see `CaptureScreen`), so a
        // 10 Hz reading invalidates the HUD and nothing else.

        // Field of view and frame width are only known once the capture
        // format has been chosen, and the plate scale check needs both.
        // Wired once here — wiring in startCapture() would stack a duplicate
        // subscription on every tab switch.
        capture.$fieldOfViewDeg
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fov in self?.wizard.fieldOfViewDeg = fov }
            .store(in: &cancellables)
        capture.$activeFormatDescription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] description in
                // "1920x1080 @ 240fps" -> 1920, 1080
                if let width = description.split(separator: "x").first.flatMap({ Double($0) }) {
                    self?.wizard.imageWidthPx = width
                }
                if let height = description.split(separator: "x").dropFirst().first
                    .flatMap({ Double($0.prefix(while: \.isNumber)) }) {
                    self?.wizard.imageHeightPx = height
                }
            }
            .store(in: &cancellables)

        capture.requireHitterToTrigger = settings.requireHitter
        capture.visionOrientationOverride = settings.visionOrientation.orientation
        capture.triggerThresholdDb = settings.triggerDb
        reload()
    }

    // MARK: - Session

    private var cancellables = Set<AnyCancellable>()

    func startCapture() {
        capture.configureAndStart()
    }

    func stopCapture() {
        capture.isArmed = false
        capture.stop()
    }

    func arm() {
        guard wizard.isArmingAllowed else {
            banner = Banner(kind: .warning,
                            text: wizard.topAdvisory?.text
                                ?? "Tap the ball in the picture to set the distance.")
            return
        }
        capture.isArmed = true
        armedAt = CACurrentMediaTime()
        sessionSwingCount = 0
        // Zero, not `capture.droppedFrameCount`. Arming resets that counter,
        // but asynchronously — `isArmed`'s didSet hops to the pipeline queue,
        // then the session queue, then back to main — so reading it here
        // latched the idle count from before arming. Every clip was then
        // compared against a baseline the counter had already dropped below,
        // and the .framesDropped flag stayed off through the drops it exists
        // to record.
        dropsAtClipStart = 0
        // Off-level is allowed now, so say so once rather than silently
        // recording a compromised reading.
        if let warning = wizard.advisories.first(where: { $0.level == .warning }) {
            banner = Banner(kind: .warning, text: warning.text + " Recording anyway — the swing will be flagged.")
        }
    }

    /// When the current armed stretch began, for the hitter-gate watchdog.
    private(set) var armedAt: CFTimeInterval = 0

    /// True when we have been armed a while and the pose gate has never once
    /// seen a person — almost certainly the gate failing rather than an empty
    /// field, and it would otherwise suppress every trigger in silence.
    var hitterGateLooksStuck: Bool {
        capture.isArmed && settings.requireHitter && armedAt > 0
            && capture.hitterGateNeverFired(since: armedAt)
    }

    /// Give up on the hitter requirement for this session. Swings captured
    /// afterwards carry `.hitterGateDisabled` so the looser gate is on record.
    func trustAudioTriggerForSession() {
        settings.requireHitter = false
        hitterGateDisabledForSession = true
        banner = Banner(kind: .info,
                        text: "Trigger will now fire on sound alone. Swings are flagged so you know.")
    }

    private(set) var hitterGateDisabledForSession = false

    func disarm() { capture.isArmed = false }

    /// Manual capture — the escape hatch when the audio trigger cannot hear
    /// contact. Recorded as such so gate G5 stays honest.
    func triggerManually() {
        capture.triggerManually()
        pendingManual = true
    }

    private var pendingManual = false
    /// Dropped-frame count when the current clip began, so the flag reflects
    /// drops during THIS clip rather than the whole session.
    private var dropsAtClipStart = 0

    // MARK: - Import

    /// Analyse a clip the app did not film.
    ///
    /// Worth having for a reason beyond convenience: it turns footage already
    /// on the phone into a **repeatable** test. Every detector change can be
    /// re-run against the same swings instead of requiring another trip to a
    /// field, and the diagnostic the analyser produces is the same one the live
    /// path produces, so a failure here explains a failure there.
    ///
    /// What survives the trip and what does not:
    ///  * Launch angle and exit velocity **do**. Both rest on the ball's own
    ///    apparent size, which travels with the footage.
    ///  * Camera distance, roll, tilt and the level reading **do not** — they
    ///    were never in the file. So no tilt correction is applied and no roll
    ///    is taken out.
    ///  * Contact time **does not**. There was no audio trigger, so the first
    ///    tracked point is treated as contact; the bat window is derived from
    ///    it rather than from the crack of the bat.
    ///
    /// All three absences arrive as `.importedClip` on the swing, rather than
    /// as numbers that look like every other swing's.
    func importClip(from picked: URL) {
        let needsScope = picked.startAccessingSecurityScopedResource()
        defer { if needsScope { picked.stopAccessingSecurityScopedResource() } }

        do {
            importCopiedClip(at: try ClipStore.importClip(from: picked))
        } catch {
            banner = Banner(kind: .error,
                            text: "Could not read that file: \(error.localizedDescription)")
        }
    }

    /// Analyse a clip already sitting in the store.
    ///
    /// The Photos path writes the original recording out of the library itself,
    /// so it arrives here already copied — there is nothing left to import,
    /// only to measure.
    func importCopiedClip(at stored: URL) {
        // Ask before spending minutes. A 272-second session file took thirteen
        // minutes to measure and produced ONE number off it, because only the
        // best track in a clip is measured and the rest are discarded in
        // silence. That cost was paid before the report explaining it could be
        // read — which is precisely backwards, so the warning moves in front
        // of the work.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let prompt = await Self.lengthWarning(for: stored) {
                self.longClipPrompt = prompt
            } else {
                self.beginAnalysis(of: stored)
            }
        }
    }

    /// A clip long enough that measuring it is minutes of work for one reading.
    struct LongClipPrompt: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var durationS: Double
        var estimatedS: Double

        var message: String {
            String(format: "This clip is %.0f seconds long — a session, not a swing. Measuring it will take roughly %.0f minutes, and only the single best track in the whole file is reported; every other swing in it is discarded without a word. Trimming it to the one swing first is faster and gives a better answer.",
                   durationS, max(1, estimatedS / 60).rounded())
        }
    }

    @Published var longClipPrompt: LongClipPrompt?

    /// Decide whether a clip is long enough to be worth asking about, from
    /// metadata alone — no decoding, so this costs nothing.
    ///
    /// The estimate is measured, not guessed: analysis runs at roughly 15 ms
    /// per decoded frame on the hardware this was first run on, and frames are
    /// duration times rate. That predicted 812 s for the clip that actually
    /// took 804 s, which is close enough to put a number in front of somebody.
    static func lengthWarning(for url: URL,
                              thresholdS: Double = 30) async -> LongClipPrompt? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration > thresholdS else { return nil }
        // Nominal is fine here: this is an estimate of how long a wait to warn
        // about, not a measurement anything is computed from.
        var rate = 30.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let nominal = try? await track.load(.nominalFrameRate), nominal > 1 {
            rate = Double(nominal)
        }
        let frames = duration * max(1, rate)
        return LongClipPrompt(url: url, durationS: duration,
                              estimatedS: frames * 0.015)
    }

    /// Measure a clip, having decided it is worth measuring.
    func beginAnalysis(of stored: URL) {
        // Stop the camera first. This is not tidiness — the capture session
        // holds the hardware video decoder, and an AVAssetReader that cannot
        // get one fails with "Operation Interrupted" after decoding zero
        // frames while still reporting the clip's metadata perfectly, because
        // metadata needs no decoder. Switching tabs deliberately leaves the
        // session running so the preview survives, which is exactly why this
        // has to be explicit here.
        let wasRunning = capture.status == .running
        if wasRunning { stopCapture() }

        let setting = currentSetting
        let detector = settings.detector
        var options = settings.analyzerOptions
        // Deliberately not seeded from the live camera: this clip was filmed by
        // something else, at some other angle, through some other lens. Using
        // the tripod's current tilt would correct a projection the footage
        // never had.
        options.rollDeg = 0
        // Tilt starts at zero because nothing in the file records it — but the
        // OPTICS are now assumed rather than zeroed. Zero field of view meant
        // zero focal length, which meant the tilt correction could not run at
        // all even once somebody supplied an angle. The horizon tool in "Play
        // with tracking overlaid" is how that angle gets supplied, and this is
        // what lets it do anything.
        options.tiltDeg = 0
        options.fieldOfViewDeg = settings.importFovDeg
        // The radius gates are pixel counts chosen for 1080p. A 720p slow-motion
        // clip — a real iPhone mode — shows the same ball at two thirds the
        // size, which walks it toward the minimum and can push it out entirely.
        // Scaled to the clip rather than changed in Settings, so the live
        // capture path keeps the values the reference implementation is pinned
        // to and only the import is adjusted.
        options.scaleDetectorRadiiToFrameWidth = true
        // Whatever the previous failed import left behind goes now, before this
        // one takes its place — otherwise the store grows a file per failure.
        if let previous = lastImportedClip,
           !swings.contains(where: { $0.clipFilename == previous.lastPathComponent }) {
            try? FileManager.default.removeItem(at: previous)
        }
        analysisProgress = 0
        lastDiagnostics = nil
        lastImportedClip = stored

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Wait for the camera to have actually let go. stopCapture() only
            // enqueues the stop; starting to decode before it lands is the
            // race this closes.
            await self.capture.quiesce()

            let diagnostics = ClipDiagnostics()
            var analysis: ClipAnalysis?
            var failure: String?
            do {
                analysis = try await ClipAnalyzer.analyze(
                    url: stored, contactTime: nil, options: options,
                    diagnostics: diagnostics,
                    progress: { p in
                        Task { @MainActor [weak self] in self?.analysisProgress = p }
                    })
            } catch {
                failure = error.localizedDescription
                diagnostics.failure = failure
            }
            let finalAnalysis = analysis
            let finalFailure = failure
            let report = diagnostics.report(detector: detector)
            await MainActor.run {
                self.lastDiagnostics = report
                self.finishImport(stored: stored, setting: setting,
                                  analysis: finalAnalysis, failure: finalFailure)
                // Back on, so returning to the Capture tab does not find a dead
                // preview and no explanation for it.
                if wasRunning { self.startCapture() }
            }
        }
    }

    /// Stamp `.ballUnconfirmed` when the chosen track cannot be stood behind
    /// as a struck ball.
    ///
    /// A hand-picked ball is exempt: the user resolved the ambiguity the
    /// pipeline could not, and second-guessing them would defeat the point of
    /// asking.
    private func confirmBall(_ analysis: ClipAnalysis, into dto: inout SwingDTO) {
        // Any previous verdict goes first, so re-analysing repeatedly cannot
        // stack a column of near-identical notes — and so a run that now finds
        // the ball leaves no trace of the one that did not.
        let kept = (dto.notes ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(Self.ballNotIdentifiedPrefix) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        dto.notes = kept.isEmpty ? nil : kept

        guard !analysis.trace.usedBallSeed else { return }
        guard let reason = TrackPlausibility.rejection(track: analysis.track,
                                                       launchAngleDeg: dto.launchAngleDeg,
                                                       flags: dto.flags) else { return }
        dto.captureFlags.append(.ballUnconfirmed)
        dto.notes = [dto.notes, Self.ballNotIdentifiedPrefix + reason]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private static let ballNotIdentifiedPrefix = "Ball not identified: "

    /// Write the ball track and the pose track beside the clip, and point the
    /// record at them.
    ///
    /// Shared because it was not. Only the live-capture path wrote these, so
    /// every IMPORTED swing was saved with no track file and no pose file at
    /// all — which is invisible everywhere except the one screen that needs
    /// them: "Play with tracking overlaid" opened on a perfectly good clip,
    /// with the ball plainly in shot, and reported "0 tracked frames / no body
    /// track". The detector had done its job; the evidence was simply never
    /// kept. Import is also the path most likely to be measuring footage
    /// somebody is suspicious of, so it is the last place to discard it.
    private func writeTracks(for analysis: ClipAnalysis,
                             clipName: String?,
                             setting: SwingSetting,
                             into dto: inout SwingDTO) {
        guard let clipName else { return }
        let base = (clipName as NSString).deletingPathExtension

        // The exact format `analyze_swing.py` reads, so any suspicious reading
        // can be re-run on the Mac.
        let csv = TrackCSV.serialize(
            track: analysis.track,
            fps: analysis.fps,
            meta: [("clip", clipName),
                   ("contact_time", String(format: "%.6f", analysis.contactTime)),
                   ("setting", setting.rawValue),
                   ("source", "SwingLab on-device")]
        )
        if let data = csv.data(using: .utf8) {
            let name = base + ".csv"
            try? data.write(to: ClipStore.trackURL(named: name), options: .atomic)
            dto.trackCSVFilename = name
        }

        // The pose track, beside it. Same reason the ball track is kept: when a
        // body number looks wrong, the frames it came from are the only way to
        // find out why. JSON rather than the CSV the Python reads — sla_common
        // has no pose stage, so there is nothing on the Mac to feed a CSV to.
        if !analysis.pose.isEmpty {
            let name = base + ".pose.json"
            if let data = try? JSONEncoder().encode(analysis.pose) {
                try? data.write(to: ClipStore.trackURL(named: name), options: .atomic)
                dto.poseFilename = name
            }
        }

        // The detector's raw opinion, written even when it is empty: "nothing
        // was found anywhere" and "no trace was kept" are different answers to
        // the question this file exists to settle, and an absent file cannot
        // say the first one.
        let traceName = base + ".trace.json"
        if let data = try? JSONEncoder().encode(analysis.trace) {
            try? data.write(to: ClipStore.trackURL(named: traceName), options: .atomic)
            dto.traceFilename = traceName
        }
    }

    private func finishImport(stored: URL, setting: SwingSetting,
                              analysis: ClipAnalysis?, failure: String?) {
        analysisProgress = nil
        guard let analysis else {
            // Kept, not deleted. A clip the pipeline made nothing of is exactly
            // the one whose frames are worth exporting, and deleting it here
            // would throw away the evidence at the moment it became useful.
            // The next import clears it.
            banner = Banner(kind: .warning,
                            text: failure ?? "Nothing measurable in that clip.")
            return
        }
        let name = ClipStore.fileUnderConvention(clip: stored, setting: setting)
        // Renamed into the store's convention, so point at where it now lives.
        lastImportedClip = name.map { ClipStore.clipURL(named: $0) } ?? stored
        var dto = SwingDTO(analysis: analysis, setting: setting,
                           clipFilename: name, autoTriggered: false)
        dto.captureFlags = [.importedClip]
        confirmBall(analysis, into: &dto)
        // Carried on the record so re-analysis uses the same lens the first
        // pass assumed, and so the horizon tool has a focal length to work
        // with. Assumed, not measured — hence the flag above.
        dto.cameraFovDeg = settings.importFovDeg
        writeTracks(for: analysis, clipName: name, setting: setting, into: &dto)
        do {
            try store.save(dto)
            reload()
            lastSwing = dto
            // The frame rate is in the banner on purpose. Exit velocity scales
            // linearly with it, so a clip that says 30 fps when it holds 240 is
            // an eight-fold error — obvious the moment the number is on screen,
            // invisible if it is not. Settings has an fps override for exactly
            // that case.
            if dto.captureFlags.contains(.ballUnconfirmed) {
                // Deliberately NOT quoting the numbers. Reading them out here
                // is what made a mis-tracked clip look like a measurement:
                // they are numbers about whatever the detector settled on, and
                // announcing them invites believing them.
                banner = Banner(kind: .warning, text: String(
                    format: "Imported at %.0f fps, but no struck ball could be identified — open the swing and tap \"Point at the ball\".",
                    dto.fps))
            } else {
                banner = Banner(kind: .info, text: String(
                    format: "Imported at %.0f fps — %.1f° at %.0f mph, %d frames tracked.",
                    dto.fps, dto.launchAngleDeg, dto.exitVeloMph, dto.trackedFrames))
            }
        } catch {
            banner = Banner(kind: .error,
                            text: "Measured it, but could not save: \(error.localizedDescription)")
        }
    }

    // MARK: - Clip handling

    func handleClip(_ output: ClipRecorder.Output, autoTriggered: Bool) {
        let wasManual = pendingManual
        pendingManual = false
        let setting = currentSetting
        let placement = wizard.placement
        let droppedDuringClip = capture.droppedFrameCount > dropsAtClipStart
        dropsAtClipStart = capture.droppedFrameCount
        var options = settings.analyzerOptions
        options.rollDeg = placement.rollDeg
        options.tiltDeg = placement.tiltDeg
        options.fieldOfViewDeg = placement.fovDeg
        options.visionOrientation = capture.visionOrientationForFrames
        options.trackBody = settings.trackBody

        analysisProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var analysis: ClipAnalysis?
            var failure: String?
            do {
                analysis = try await ClipAnalyzer.analyze(
                    url: output.url,
                    contactTime: output.contactOffset,
                    options: options,
                    progress: { p in
                        Task { @MainActor [weak self] in self?.analysisProgress = p }
                    }
                )
            } catch {
                failure = error.localizedDescription
            }
            let finalAnalysis = analysis
            let finalFailure = failure
            await MainActor.run {
                self.finishClip(output: output,
                                setting: setting,
                                placement: placement,
                                droppedFrames: droppedDuringClip,
                                analysis: finalAnalysis,
                                failure: finalFailure,
                                autoTriggered: autoTriggered && !wasManual)
            }
        }
    }

    private func finishClip(output: ClipRecorder.Output,
                            setting: SwingSetting,
                            placement: PlacementWizard.Placement,
                            droppedFrames: Bool,
                            analysis: ClipAnalysis?,
                            failure: String?,
                            autoTriggered: Bool) {
        analysisProgress = nil

        let clipName = settings.keepClips
            ? ClipStore.fileUnderConvention(clip: output.url, setting: setting)
            : nil
        if !settings.keepClips { try? FileManager.default.removeItem(at: output.url) }

        var dto: SwingDTO
        if let analysis {
            dto = SwingDTO(analysis: analysis, setting: setting,
                           clipFilename: clipName, autoTriggered: autoTriggered)
            confirmBall(analysis, into: &dto)
            writeTracks(for: analysis, clipName: clipName, setting: setting, into: &dto)
        } else {
            // A clip where tracking failed still counts — it is a G1 miss, and
            // dropping it would flatter the trackability number.
            dto = SwingDTO()
            dto.setting = setting
            dto.clipFilename = clipName
            dto.trackedFrames = 0
            dto.autoTriggered = autoTriggered
            dto.notes = failure
        }

        dto.cameraDistanceM = placement.distanceM
        dto.lensHeightM = placement.heightM
        dto.cameraRollDeg = placement.rollDeg
        dto.cameraTiltDeg = placement.tiltDeg
        dto.cameraFovDeg = placement.fovDeg > 0 ? placement.fovDeg : nil
        dto.visionOrientation = capture.visionOrientationForFrames
        dto.captureFlags = placement.captureFlags
            + (hitterGateDisabledForSession ? [.hitterGateDisabled] : [])
            + (droppedFrames ? [.framesDropped] : [])
        sessionSwingCount += 1

        do {
            try store.save(dto)
            reload()
            lastSwing = dto
            if let failure {
                banner = Banner(kind: .warning, text: "Clip saved but no ball track: \(failure)")
            }
        } catch {
            banner = Banner(kind: .error, text: "Could not save the swing: \(error.localizedDescription)")
        }
    }

    // MARK: - Editing and re-analysis

    func update(_ swing: SwingDTO) {
        do {
            try store.save(swing)
            reload()
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
    }

    func delete(_ swing: SwingDTO) {
        ClipStore.delete(clipNamed: swing.clipFilename)
        ClipStore.delete(trackNamed: swing.trackCSVFilename)
        ClipStore.delete(trackNamed: swing.poseFilename)
        ClipStore.delete(trackNamed: swing.traceFilename)
        try? store.delete(id: swing.id)
        reload()
    }

    /// Re-run the pipeline on a stored clip — after retuning colour ranges,
    /// or with the fallback detector forced.
    func reanalyze(_ swing: SwingDTO, forceFallback: Bool = false) {
        guard let clipName = swing.clipFilename else {
            banner = Banner(kind: .warning, text: "That swing has no clip to re-analyze.")
            return
        }
        let url = ClipStore.clipURL(named: clipName)
        var options = settings.analyzerOptions
        options.rollDeg = swing.cameraRollDeg ?? 0
        // Re-analysis has to use the optics and pose the clip was filmed with,
        // not whatever the phone is pointing at now.
        options.tiltDeg = swing.cameraTiltDeg ?? 0
        options.fieldOfViewDeg = swing.cameraFovDeg ?? 0
        options.visionOrientation = swing.visionOrientation
        // A hand-picked ball survives re-analysis — otherwise correcting the
        // tilt would silently throw the user's disambiguation away.
        if let t = swing.ballSeedT, let x = swing.ballSeedX, let y = swing.ballSeedY {
            options.ballSeed = (t: t, x: x, y: y)
        }
        options.trackBody = settings.trackBody
        options.forceFallbackDetector = forceFallback
        analysisProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await ClipAnalyzer.analyze(
                    url: url,
                    contactTime: swing.contactTime > 0 ? swing.contactTime : nil,
                    options: options,
                    progress: { p in
                        Task { @MainActor [weak self] in self?.analysisProgress = p }
                    })
                await MainActor.run {
                    var updated = SwingDTO(analysis: analysis,
                                           setting: swing.setting,
                                           clipFilename: clipName,
                                           autoTriggered: swing.autoTriggered)
                    // Preserve everything the pipeline does not produce.
                    updated.id = swing.id
                    updated.capturedAt = swing.capturedAt
                    updated.trackCSVFilename = swing.trackCSVFilename
                    updated.hangS = swing.hangS
                    updated.carryM = swing.carryM
                    updated.cameraDistanceM = swing.cameraDistanceM
                    updated.lensHeightM = swing.lensHeightM
                    updated.cameraRollDeg = swing.cameraRollDeg
                    updated.cameraTiltDeg = swing.cameraTiltDeg
                    updated.cameraFovDeg = swing.cameraFovDeg
                    updated.poseFilename = swing.poseFilename
                    updated.traceFilename = swing.traceFilename
                    updated.ballSeedT = swing.ballSeedT
                    updated.ballSeedX = swing.ballSeedX
                    updated.ballSeedY = swing.ballSeedY
                    updated.visionOrientationRaw = swing.visionOrientationRaw
                    // Recomputed, not carried: a re-analysis that finally
                    // found the ball must be able to CLEAR this, and one that
                    // still has not must not inherit a clean bill from before.
                    updated.captureFlags = swing.captureFlags.filter { $0 != .ballUnconfirmed }
                    updated.notes = swing.notes
                    self.confirmBall(analysis, into: &updated)
                    // Rewrite the track, pose and trace files to match the
                    // analysis that just ran. Re-analysis used to carry the
                    // FILENAMES forward and leave the files themselves
                    // untouched, so a corrected reading was displayed over the
                    // original track: the launch angle moved, the path on
                    // screen did not, and the review screen contradicted the
                    // number beside it. Anyone checking whether a fix had
                    // worked was reading stale evidence.
                    self.writeTracks(for: analysis, clipName: clipName,
                                     setting: swing.setting, into: &updated)
                    self.analysisProgress = nil
                    self.update(updated)
                    self.banner = AppModel.Banner(kind: .info, text: "Re-analyzed.")
                }
            } catch {
                await MainActor.run {
                    self.analysisProgress = nil
                    // A seed that found nothing keeps the swing exactly as it
                    // was rather than replacing it with a worse answer, and
                    // says which end of the pipeline to look at.
                    let kind: Banner.Kind =
                        (error as? ClipAnalysisError) == .noBallAtSeed ? .warning : .error
                    self.banner = AppModel.Banner(kind: kind, text: error.localizedDescription)
                }
            }
        }
    }

    func reload() {
        do {
            swings = try store.all()
        } catch {
            banner = Banner(kind: .error, text: "Could not read stored swings: \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    func exportAll() -> [URL] {
        var urls: [URL] = []
        let stamp = Self.stampFormatter.string(from: Date())
        if let u = try? CSVExport.write(CSVExport.summaryCSV(swings),
                                        filename: "summary_\(stamp).csv") { urls.append(u) }
        if let u = try? CSVExport.write(CSVExport.fullCSV(swings),
                                        filename: "swinglab_\(stamp).csv") { urls.append(u) }
        if let u = try? CSVExport.write(CSVExport.scoreboardText(scoreboard),
                                        filename: "validation_\(stamp).txt") { urls.append(u) }
        return urls
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
