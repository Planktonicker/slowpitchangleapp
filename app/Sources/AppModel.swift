// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

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
        options.tiltDeg = 0
        options.fieldOfViewDeg = 0
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
        do {
            try store.save(dto)
            reload()
            lastSwing = dto
            // The frame rate is in the banner on purpose. Exit velocity scales
            // linearly with it, so a clip that says 30 fps when it holds 240 is
            // an eight-fold error — obvious the moment the number is on screen,
            // invisible if it is not. Settings has an fps override for exactly
            // that case.
            banner = Banner(kind: .info, text: String(
                format: "Imported at %.0f fps — %.1f° at %.0f mph, %d frames tracked.",
                dto.fps, dto.launchAngleDeg, dto.exitVeloMph, dto.trackedFrames))
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
            // Write the track in the exact format `analyze_swing.py` reads, so
            // any suspicious reading can be re-run on the Mac.
            if let clipName {
                let trackName = (clipName as NSString).deletingPathExtension + ".csv"
                let csv = TrackCSV.serialize(
                    track: analysis.track,
                    fps: analysis.fps,
                    meta: [("clip", clipName),
                           ("contact_time", String(format: "%.6f", analysis.contactTime)),
                           ("setting", setting.rawValue),
                           ("source", "SwingLab on-device")]
                )
                if let data = csv.data(using: .utf8) {
                    try? data.write(to: ClipStore.trackURL(named: trackName), options: .atomic)
                    dto.trackCSVFilename = trackName
                }

                // The pose track, beside it. Same reason the ball track is
                // kept: when a body number looks wrong, the frames it came
                // from are the only way to find out why. JSON rather than the
                // CSV the Python reads — sla_common has no pose stage, so
                // there is nothing on the Mac to feed a CSV to yet.
                if !analysis.pose.isEmpty {
                    let poseName = (clipName as NSString).deletingPathExtension + ".pose.json"
                    if let data = try? JSONEncoder().encode(analysis.pose) {
                        try? data.write(to: ClipStore.trackURL(named: poseName), options: .atomic)
                        dto.poseFilename = poseName
                    }
                }
            }
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
                    updated.visionOrientationRaw = swing.visionOrientationRaw
                    updated.captureFlags = swing.captureFlags
                    updated.notes = swing.notes
                    self.analysisProgress = nil
                    self.update(updated)
                    self.banner = AppModel.Banner(kind: .info, text: "Re-analyzed.")
                }
            } catch {
                await MainActor.run {
                    self.analysisProgress = nil
                    self.banner = AppModel.Banner(kind: .error, text: error.localizedDescription)
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
