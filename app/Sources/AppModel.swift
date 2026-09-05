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
    /// Swings in the round so far — DERIVED, never stored. Five writers used
    /// to hand-maintain a counter and disagreed: arm() zeroed it mid-round, so
    /// hitting three, tapping Stop and re-arming showed "no swings yet" on the
    /// HUD while "This round" listed three; imports joined the round without
    /// bumping it. The store is the truth, so count the store.
    var sessionSwingCount: Int { sessionSwings.count }
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
            syncHitterGate()
            wizard.hitterHeightM = settings.hitterHeightCm.map { $0 / 100 }
            capture.visionOrientationOverride = settings.visionOrientation.orientation
            capture.triggerThresholdDb = settings.triggerDb
            capture.preRollS = settings.preRollS
            capture.postRollS = settings.postRollS
        }
    }

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        var id = UUID()
        var kind: Kind
        var text: String
    }

    /// Bumped by `reload()`, which is the only place `swings` is ever
    /// assigned. Everything derived from the swings and cached below keys off
    /// this rather than comparing arrays: an equality check over every stored
    /// swing is not free either, and this is O(1).
    private var swingsRevision = 0

    /// The go/no-go scoreboard, rebuilt only when the swings change.
    ///
    /// This was a computed property, and `ValidationView` reads it eighteen
    /// times per render — once per number on the screen — so opening that
    /// screen rebuilt the whole board from every stored swing eighteen times,
    /// and again on every one of the hundreds of publishes an analysis used to
    /// emit.
    private var cachedScoreboard: (revision: Int, board: ValidationScoreboard)?
    var scoreboard: ValidationScoreboard {
        if let c = cachedScoreboard, c.revision == swingsRevision { return c.board }
        let board = ValidationScoreboard.build(from: swings)
        cachedScoreboard = (swingsRevision, board)
        return board
    }

    var isAnalyzing: Bool { analysisProgress != nil }

    /// A progress callback that only reaches the main actor when the number a
    /// human could read actually changes.
    ///
    /// `ClipAnalyzer` calls its progress closure once per decoded frame, in
    /// each of three passes: about 2,500 calls for a three-second 240fps clip.
    /// Every one of them hopped to the main actor and set an `@Published`
    /// property, and setting that invalidates every view observing `AppModel`
    /// — including, if they happened to be on screen, the Settings screen
    /// (which enumerated the clips directory in its body) and the Validation
    /// screen (which rebuilt its scoreboard from every stored swing, eighteen
    /// times over). That is where the analysis lag came from: not the decoding,
    /// which is on a background thread, but a main thread asked to re-render
    /// the app a thousand times while it ran.
    ///
    /// A progress bar has about a hundred distinguishable states. Publishing
    /// only when the whole percent changes cuts the hops by twenty-five times
    /// and looks identical.
    private func throttledProgress() -> @Sendable (Double) -> Void {
        let lastPercent = LockedInt(-1)
        return { [weak self] p in
            let pct = Int((p * 100).rounded(.down))
            guard lastPercent.setIfDifferent(pct) else { return }
            Task { @MainActor [weak self] in self?.analysisProgress = p }
        }
    }

    /// Minimal thread-safe box. The progress closure is `@Sendable` and called
    /// from whichever thread the analysis pass is on.
    private final class LockedInt: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ v: Int) { value = v }
        /// True when the value changed, i.e. when it is worth publishing.
        func setIfDifferent(_ v: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard v != value else { return false }
            value = v
            return true
        }
    }

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

        // Which way up the buffer is. The hitter-height measurement reads pose
        // joints in buffer coordinates, and the buffer is landscape-native
        // however the phone is held — so without this the span is measured in
        // the wrong frame for one of the two landscapes, silently.
        capture.$visionOrientation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] orientation in self?.wizard.bufferOrientation = orientation }
            .store(in: &cancellables)

        syncHitterGate()
        wizard.hitterHeightM = settings.hitterHeightCm.map { $0 / 100 }
        capture.visionOrientationOverride = settings.visionOrientation.orientation
        capture.triggerThresholdDb = settings.triggerDb
        capture.preRollS = settings.preRollS
        capture.postRollS = settings.postRollS
        reload()
    }

    // MARK: - Session

    private var cancellables = Set<AnyCancellable>()

    /// The round in progress, or nil when the app is sitting on the start
    /// screen. Everything about the capture screen keys off this: there is no
    /// camera running, and no reason to run one, until a hitter has said what
    /// they are about to do.
    @Published private(set) var session: Session?

    /// Set when a round has just ended, so the summary can be shown once and
    /// then dismissed. Kept separate from `session` because the round is over —
    /// nothing should be able to record into it.
    @Published var finishedSession: SessionSummary?

    var isInSession: Bool { session != nil }

    /// Swings taken in the round so far, newest first. Drives the live count on
    /// the capture screen; the end-of-round collation is `SessionSummary`.
    var sessionSwings: [SwingDTO] {
        guard let id = session?.id else { return [] }
        return swings.filter { $0.sessionID == id }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func startSession(mode: SessionMode) {
        session = Session(mode: mode)
        // A window learned last round was learned somewhere else, in some
        // other light. Nothing about a stale one looks wrong on screen.
        capture.learnedBall = nil
        currentSetting = mode.swingSetting
        finishedSession = nil
        hitterGateDisabledForSession = false
        // The camera is NOT started here. `CaptureView.begin()` asks for
        // permission first and starts it after, and starting a 240fps session
        // before that returns is how the first run of the app produces an
        // error banner instead of a permission prompt.
    }

    /// End the round and collate it.
    ///
    /// Deliberately does NOT wait for analysis still in flight. A hitter who
    /// has finished should not be held at a spinner, and the summary is built
    /// from the store, so a swing that lands a few seconds later is in the
    /// round's history regardless — it simply is not in the sheet they were
    /// shown. The alternative, blocking the end of a round on a background
    /// pass, trades a real annoyance for a cosmetic completeness.
    func endSession() {
        guard let s = session else { return }
        var closed = s
        closed.endedAt = Date()
        session = nil
        capture.isArmed = false
        capture.stop()
        // The escape hatch expires with the round that used it.
        hitterGateDisabledForSession = false
        finishedSession = SessionSummary.build(session: closed, swings: swings)
    }

    /// Every finished round, newest first, rebuilt from the swings themselves.
    ///
    /// Derived rather than stored — see `Session.derived`. The round in
    /// progress is excluded: it is not finished, and offering to reopen the
    /// thing you are already in is a button that can only confuse.
    /// Cached for the same reason as `scoreboard`: `RoundsView` reads
    /// `pastRounds` twice per render — once to ask whether it is empty, once
    /// to build the list — and each read regrouped every stored swing.
    private var cachedRounds: (revision: Int, rounds: [Session])?
    var pastRounds: [Session] {
        let all: [Session]
        if let c = cachedRounds, c.revision == swingsRevision {
            all = c.rounds
        } else {
            all = Session.allDerived(from: swings)
            cachedRounds = (swingsRevision, all)
        }
        // Filtered outside the cache: the round in progress can change without
        // the swings changing.
        return all.filter { $0.id != session?.id }
    }

    /// Cached per round. This is called from inside `RoundsView`'s row builder,
    /// so a list of ten finished rounds rebuilt ten summaries — each a pass
    /// over every stored swing — every time anything published.
    private var cachedSummaries: (revision: Int, byRound: [UUID: SessionSummary]) = (-1, [:])
    func summary(for round: Session) -> SessionSummary {
        if cachedSummaries.revision != swingsRevision {
            cachedSummaries = (swingsRevision, [:])
        }
        if let hit = cachedSummaries.byRound[round.id] { return hit }
        let built = SessionSummary.build(session: round, swings: swings)
        cachedSummaries.byRound[round.id] = built
        return built
    }

    /// Pick a finished round back up and keep hitting into it.
    ///
    /// For the round ended by accident, and for the one that turned out to be
    /// half a round — you went to fetch more balls, the app was closed, and
    /// what comes next is plainly the same session. Rebuilding it by hand meant
    /// adding every swing to a new round one at a time.
    ///
    /// A reopened round keeps its ORIGINAL id, so every swing already in it
    /// stays in it and nothing has to be re-tagged. `endedAt` clears, because a
    /// round you are hitting into has not ended; when it ends again the summary
    /// is rebuilt from scratch over the whole set, which is exactly what makes
    /// the late swings count.
    func reopenSession(_ round: Session) {
        if session != nil { endSession() }
        var reopened = round
        reopened.endedAt = nil
        session = reopened
        currentSetting = round.mode.swingSetting
        finishedSession = nil
        hitterGateDisabledForSession = false
        banner = Banner(kind: .info,
                        text: "Back in that round — \(sessionSwingCount) swing"
                            + (sessionSwingCount == 1 ? "" : "s") + " already in it.")
    }

    /// Put an existing swing into the round in progress.
    ///
    /// For the clip filmed before anyone thought to start a session, and for
    /// the swing that landed in the wrong round because it was imported after
    /// one ended. A round is a grouping the hitter makes, not a fact about the
    /// footage, so it has to be editable — otherwise the only way to fix a
    /// mis-grouped swing is to delete it.
    func addToCurrentSession(_ swing: SwingDTO) {
        guard let id = session?.id, swing.sessionID != id else { return }
        var updated = swing
        updated.sessionID = id
        update(updated)
    }

    /// Take it back out. Leaves the swing in the full history — this changes
    /// which round it belongs to, it does not delete anything.
    func removeFromSession(_ swing: SwingDTO) {
        guard swing.sessionID != nil else { return }
        var updated = swing
        updated.sessionID = nil
        update(updated)
    }

    /// Discard a round that recorded nothing, without showing a summary of
    /// nothing. Called when the hitter backs out of setup.
    func abandonSession() {
        session = nil
        capture.isArmed = false
        capture.stop()
    }

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
                                ?? "Measure the distance in Set up.")
            return
        }
        capture.isArmed = true
        armedAt = CACurrentMediaTime()
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
        // Once the escape has been taken the gate is off — offering it again
        // is a button that changes nothing, shown beside a chip saying the
        // check is already off.
        capture.isArmed && settings.requireHitter && !hitterGateDisabledForSession
            && armedAt > 0 && capture.hitterGateNeverFired(since: armedAt)
    }

    /// Give up on the hitter requirement for this session. Swings captured
    /// afterwards carry `.hitterGateDisabled` so the looser gate is on record.
    /// Give up on the hitter requirement **for this round**.
    ///
    /// It used to do that by writing `settings.requireHitter = false`, and
    /// `settings` saves itself on every change — so a button labelled "for the
    /// session", offered whenever the gate had been quiet a while and easy to
    /// tap once out of curiosity, turned the requirement off PERMANENTLY and
    /// wrote it to disk.
    ///
    /// The next round then started with `hitterGateDisabledForSession` reset
    /// to false and `settings.requireHitter` still false: the gate was off, and
    /// because the flag that records "the gate was off" was the session one,
    /// nothing on the swing said so. That is the exact combination that
    /// recorded an empty room and reported 331 mph with no note explaining how
    /// it got past a requirement the owner believed was on.
    ///
    /// Now it is session state and only session state. The stored setting is
    /// never touched, and it goes back on by itself at the end of the round.
    func trustAudioTriggerForSession() {
        hitterGateDisabledForSession = true
        banner = Banner(kind: .info,
                        text: "Trigger will fire on sound alone for the rest of this round. Swings are flagged so you know, and the setting goes back on when the round ends.")
    }

    private(set) var hitterGateDisabledForSession = false {
        didSet { syncHitterGate() }
    }

    /// Whether a trigger currently needs a person in frame. Both the stored
    /// setting and the round's escape hatch have a say, and the capture
    /// controller must hear about either changing.
    private func syncHitterGate() {
        capture.requireHitterToTrigger = settings.requireHitter && !hitterGateDisabledForSession
    }

    /// True when the swing about to be recorded is not being checked for a
    /// hitter — whichever of the two reasons it is. Flagged on the record, so
    /// a reading taken without the check can never look like one taken with it.
    var hitterCheckIsOff: Bool {
        !settings.requireHitter || hitterGateDisabledForSession
    }

    func disarm() { capture.isArmed = false }

    /// Manual capture — the escape hatch when the audio trigger cannot hear
    /// contact. Recorded as such so gate G5 stays honest.
    func triggerManually() {
        capture.triggerManually()
        // No flag kept here. Whether a clip was manual is recorded ON the
        // clip by ClipRecorder — a pending flag consumed by whichever clip
        // finished next mislabelled an auto clip as manual whenever the
        // manual press was swallowed (button hit during a post-roll), which
        // corrupted the G5 statistic and skipped the sound-travel correction
        // on a clip that needed it.
    }
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
        // Security-scoped access has to survive the checks below AND the copy,
        // and the checks are async — so the scope is opened here and closed in
        // the task rather than by a `defer` that would fire first.
        let needsScope = picked.startAccessingSecurityScopedResource()
        Task { @MainActor [weak self] in
            defer { if needsScope { picked.stopAccessingSecurityScopedResource() } }
            guard let self else { return }

            // Checked BEFORE the copy, not after the analysis.
            //
            // A file that is not a readable video used to be copied into the
            // store, handed to the analyzer, decoded until the reader gave up,
            // and reported as "Nothing measurable in that clip" — which reads
            // as a detection failure on a real swing. It is not; it is a file
            // with no video in it, and saying so costs one metadata load.
            if let problem = await Self.importProblem(with: picked) {
                self.banner = Banner(kind: .warning, text: problem)
                return
            }
            // ...and a file already in the store is not measured twice.
            if let dupe = await Self.duplicateOf(picked) {
                self.banner = Banner(kind: .warning, text: dupe)
                return
            }
            do {
                self.importCopiedClip(at: try ClipStore.importClip(from: picked))
            } catch {
                self.banner = Banner(kind: .error,
                                     text: "Could not read that file: \(error.localizedDescription)")
            }
        }
    }

    /// Why this file cannot be measured, or `nil` if it can be.
    ///
    /// Metadata only — no decoding — so it costs nothing next to the three
    /// full passes it saves when the answer is "there is no video here".
    static func importProblem(with url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else {
            return "That file could not be opened as a video. If it came from another app, try exporting it again — a placeholder or a still-downloading iCloud file looks like this."
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              tracks.first != nil else {
            return "That file has no video track — there is nothing in it to measure. Audio-only recordings and Live Photos both look like this."
        }
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.05 else {
            return "That clip is empty or too short to hold a swing. A hit ball is in frame for a fraction of a second, but the clip still has to contain it."
        }
        return nil
    }

    /// A message naming the clip this one duplicates, or `nil` if it is new.
    ///
    /// Size first because it is free, then duration to confirm — two different
    /// recordings agreeing on both is not something worth guarding against.
    /// The answer points at re-measuring rather than at importing again: a
    /// second copy of a clip already measured adds a duplicate swing to the
    /// history, doubles what it costs on a phone that fills quickly at 240fps,
    /// and skews G1, G4 and G5, all to produce the number already on screen.
    static func duplicateOf(_ url: URL) async -> String? {
        guard let existing = ClipStore.existingClipMatchingSize(of: url) else { return nil }
        let a = try? await AVURLAsset(url: url).load(.duration).seconds
        let b = try? await AVURLAsset(url: existing).load(.duration).seconds
        guard let a, let b, abs(a - b) < 0.05 else { return nil }
        return "Already imported — this is the same clip as \(existing.lastPathComponent), which is in Swings. To measure it again with the current settings, open it there and tap re-measure; importing it a second time would only add a duplicate."
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
            // Both checks again here, because the Photos path does not come
            // through `importClip` — `PhotoClipPicker` writes the original
            // recording straight into the store and calls this. Cheap enough
            // to repeat: metadata loads, no decoding.
            //
            // The file is already on disk by the time we get here, and it is
            // ours, so a rejected clip is removed rather than left behind. The
            // Files path checks before copying so it never reaches this with
            // one to clean up.
            if let problem = await Self.importProblem(with: stored) {
                try? FileManager.default.removeItem(at: stored)
                self.banner = Banner(kind: .warning, text: problem)
                return
            }
            if let dupe = await Self.duplicateOf(stored) {
                try? FileManager.default.removeItem(at: stored)
                self.banner = Banner(kind: .warning, text: dupe)
                return
            }
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
                    progress: self.throttledProgress())
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
                                  analysis: finalAnalysis, failure: finalFailure,
                                  report: report)
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

    private static let ballNotIdentifiedPrefix = SwingDTO.ballNotIdentifiedPrefix

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
                             into dto: inout SwingDTO,
                             report: String? = nil) {
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

        // The stage-by-stage report, for every swing and not only for imports.
        // A live-captured swing is precisely the one that cannot be re-run to
        // find out what happened — the moment is gone — so if the report is
        // going to exist anywhere it has to be written at capture time.
        if let report, let data = report.data(using: .utf8) {
            let name = base + ".report.txt"
            try? data.write(to: ClipStore.trackURL(named: name), options: .atomic)
            dto.diagnosticsFilename = name
        }
    }

    private func finishImport(stored: URL, setting: SwingSetting,
                              analysis: ClipAnalysis?, failure: String?,
                              report: String? = nil) {
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
        // Imported INTO the round it was imported during. Without this a clip
        // brought in mid-session vanished: "This round" filters on the session
        // id, so the swing appeared nowhere on the screen that had just been
        // used to import it, and the end-of-round summary never counted it.
        //
        // The round is where the swing was looked at, not where it was filmed,
        // and that is the honest reading — the record still carries
        // `.importedClip`, so nothing about its provenance is lost.
        dto.sessionID = session?.id
        confirmBall(analysis, into: &dto)
        // Carried on the record so re-analysis uses the same lens the first
        // pass assumed, and so the horizon tool has a focal length to work
        // with. Assumed, not measured — hence the flag above.
        dto.cameraFovDeg = settings.importFovDeg
        writeTracks(for: analysis, clipName: name, setting: setting,
                    into: &dto, report: report)
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

    // MARK: - Hardware decoder contention

    /// Run a decode-heavy job, and if it fails while the camera is running,
    /// free the hardware decoder and try once more.
    ///
    /// The capture session CAN hold the decoder — the documented "Operation
    /// Interrupted after zero frames", which the import path avoids by
    /// stopping the camera first. The live path cannot do that up front: it
    /// analyzes the swing that just happened while staying armed for the next
    /// one, and stopping the session between pitches would be worse than the
    /// failure. Field evidence also says decode-while-capturing usually works
    /// (live swings have measured). So the camera is only stopped when the
    /// failure actually occurs, the job retried once, and the session — and
    /// the armed state a round expects — restored after.
    private func retryingWithFreeDecoder<T: Sendable>(
        _ body: @Sendable () async throws -> T) async throws -> T {
        do { return try await body() }
        catch {
            let (running, armed) = await MainActor.run {
                (capture.status == .running, capture.isArmed)
            }
            guard running else { throw error }
            await MainActor.run { self.stopCapture() }
            await capture.quiesce()
            defer {
                Task { @MainActor in
                    self.startCapture()
                    if armed { self.capture.isArmed = true }
                }
            }
            return try await body()
        }
    }

    /// The overlay exporter and other view-driven decoders use the same
    /// retry, so a mid-round export does not die on decoder contention.
    func runFreeingDecoderIfNeeded<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await retryingWithFreeDecoder(body)
    }

    // MARK: - Clip handling

    func handleClip(_ output: ClipRecorder.Output, autoTriggered: Bool) {
        let wasManual = output.manual
        // Snapshot the conditions of CAPTURE, not of analysis-finish. Analysis
        // takes seconds, and ending the round during it resets both the
        // session and the gate override — reading them afterwards stripped the
        // .hitterGateDisabled flag and the round membership from exactly the
        // swing recorded under them.
        let capturedSessionID = session?.id
        let capturedGateOff = hitterCheckIsOff
        // Read and cleared here, for the same reason as the two above: the
        // controller sets it as the clip closes, and the next clip's trigger
        // would otherwise inherit this one's verdict.
        let capturedWrongSound = capture.lastClipHeardLouderImpulse
        capture.lastClipHeardLouderImpulse = false
        let setting = currentSetting
        let placement = wizard.placement
        let droppedDuringClip = capture.droppedFrameCount > dropsAtClipStart
        dropsAtClipStart = capture.droppedFrameCount
        var options = settings.analyzerOptions
        // The ball the hitter tapped in setup beats a constant that assumed
        // optic yellow in daylight — it is a sample of THIS ball, in THIS
        // light, at the distance it will be hit from. Only the live path: an
        // imported clip was filmed by something else, somewhere else.
        let usedLearnedBall = capture.learnedBall != nil
        if let learned = capture.learnedBall { options.detector = learned }
        options.rollDeg = placement.rollDeg
        options.tiltDeg = placement.tiltDeg
        options.fieldOfViewDeg = placement.fovDeg
        options.visionOrientation = capture.visionOrientationForFrames
        options.trackBody = settings.trackBody

        analysisProgress = 0
        // A report for every swing, not only for imports. A live-captured
        // swing is the one that cannot be re-run to find out what happened,
        // because the moment is gone — so if the evidence is going to exist at
        // all it has to be gathered on the pass that measures it.
        let diagnostics = ClipDiagnostics()
        diagnostics.ballWindowLearned = usedLearnedBall

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var analysis: ClipAnalysis?
            var failure: String?
            do {
                analysis = try await self.retryingWithFreeDecoder {
                    try await ClipAnalyzer.analyze(
                        url: output.url,
                        // Not the trigger time. The trigger fires when the crack
                        // reaches the phone, one sound-travel-time after contact —
                        // three frames at 240fps from a normal tripod distance,
                        // measured against a field clip. See `contactTimeFromAudio`.
                        contactTime: SLA.contactTimeFromAudio(
                            audioT: output.contactOffset,
                            distanceM: wasManual ? nil : placement.distanceM),
                        options: options,
                        diagnostics: diagnostics,
                        progress: self.throttledProgress()
                    )
                }
            } catch {
                failure = error.localizedDescription
                diagnostics.failure = failure
            }
            let finalAnalysis = analysis
            let finalFailure = failure
            let finalReport = diagnostics.report(detector: options.detector)
            await MainActor.run {
                self.lastDiagnostics = finalReport
                self.finishClip(output: output,
                                report: finalReport,
                                setting: setting,
                                placement: placement,
                                droppedFrames: droppedDuringClip,
                                analysis: finalAnalysis,
                                failure: finalFailure,
                                autoTriggered: autoTriggered && !wasManual,
                                sessionID: capturedSessionID,
                                gateWasOff: capturedGateOff,
                                triggeredOnWrongSound: capturedWrongSound)
            }
        }
    }

    private func finishClip(output: ClipRecorder.Output,
                            report: String?,
                            setting: SwingSetting,
                            placement: PlacementWizard.Placement,
                            droppedFrames: Bool,
                            analysis: ClipAnalysis?,
                            failure: String?,
                            autoTriggered: Bool,
                            sessionID: UUID?,
                            gateWasOff: Bool,
                            triggeredOnWrongSound: Bool) {
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
            writeTracks(for: analysis, clipName: clipName, setting: setting,
                        into: &dto, report: report)
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
            + (gateWasOff ? [.hitterGateDisabled] : [])
            + (droppedFrames ? [.framesDropped] : [])
            + (triggeredOnWrongSound ? [.triggeredOnWrongSound] : [])
        dto.sessionID = sessionID

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

    /// Every file a swing owns.
    ///
    /// One list, called from all three delete paths. It used to be written out
    /// three times, and the copies had already drifted once: the report file
    /// was added to one of them and not the others, so "Delete all swings" —
    /// which promises to remove the measurements and the footage behind them —
    /// left one .report.txt per swing behind forever, on a device the app
    /// itself warns fills quickly at 240fps.
    private func removeFiles(of swing: SwingDTO) {
        ClipStore.delete(clipNamed: swing.clipFilename)
        ClipStore.delete(trackNamed: swing.trackCSVFilename)
        ClipStore.delete(trackNamed: swing.poseFilename)
        ClipStore.delete(trackNamed: swing.traceFilename)
        ClipStore.delete(trackNamed: swing.diagnosticsFilename)
    }

    func delete(_ swing: SwingDTO) {
        removeFiles(of: swing)
        try? store.delete(id: swing.id)
        reload()
    }

    /// Delete several swings, reloading once at the end.
    ///
    /// Not a loop over `delete(_:)`: each of those re-fetches the whole store
    /// and rebuilds every derived view of it, so clearing a selection of forty
    /// would do forty full fetches on the main thread — the same fault
    /// `deleteAll` was written to avoid.
    func delete(_ doomed: [SwingDTO]) {
        guard !doomed.isEmpty else { return }
        for swing in doomed {
            removeFiles(of: swing)
            try? store.delete(id: swing.id)
        }
        reload()
    }

    /// Delete a whole round.
    ///
    /// A round IS its swings — nothing stores one separately, which is why an
    /// empty round does not appear in the list at all (see `RoundsView`). So
    /// deleting one is deleting them, and there is no orphan record left
    /// behind to rebuild it from.
    func deleteRound(id: UUID) {
        delete(swings.filter { $0.sessionID == id })
        // A window learned for a round that no longer exists is a leak, and a
        // small one, but it is also the kind that outlives the reason it was
        // stored.
        learnedBallBySession[id] = nil
    }

    /// How many swings a round would take with it. The delete confirmation
    /// says this, because "delete round" reads like removing a heading.
    func swingCount(inRound id: UUID) -> Int {
        swings.filter { $0.sessionID == id }.count
    }

    /// Delete every stored swing, reloading once at the end.
    ///
    /// The Settings button used to loop `delete(_:)` over `model.swings`, and
    /// each of those re-fetched the whole store and rebuilt every derived
    /// view of it — so clearing two hundred swings did two hundred full
    /// fetches on the main thread while the confirmation sheet sat on screen
    /// waiting to dismiss.
    func deleteAll() {
        for swing in swings {
            removeFiles(of: swing)
            try? store.delete(id: swing.id)
        }
        reload()
    }

    // MARK: - Learning the ball from a clip already filmed

    /// Colour and size window learned by pointing at the ball.
    ///
    /// Keyed by round where there is one and by the swing itself where there
    /// is not. An imported clip picked up outside a round has no session id —
    /// `finishImport` stamps `session?.id`, which is nil then — so keying on
    /// the round alone meant pointing at the ball in a clip filmed by the
    /// Camera app silently learned nothing and re-measured with the default
    /// window. That is exactly the footage most likely to need it.
    ///
    /// In memory and not persisted, deliberately — the same rule as the live
    /// one. A window learned in a garage at night is worse than the default on
    /// a sunlit field, and a stale one looks no different on the screen.
    @Published private(set) var learnedBallBySession: [UUID: DetectorSettings] = [:]

    /// The round if the swing is in one, otherwise the swing itself.
    private func ballWindowKey(for swing: SwingDTO) -> UUID { swing.sessionID ?? swing.id }

    /// A whole round being re-measured, one swing at a time.
    struct RoundRemeasure: Equatable {
        var sessionID: UUID
        var done: Int
        var total: Int
        /// Set by `cancelRoundRemeasure`; the queue drains without starting
        /// another. The swing already running is allowed to finish, because
        /// killing it halfway leaves neither the old reading nor a new one.
        var cancelling: Bool
    }
    @Published private(set) var roundRemeasure: RoundRemeasure?
    private var roundQueue: [SwingDTO] = []

    /// Sample the ball at a tap on a stored clip and keep the window for the
    /// round that clip belongs to.
    ///
    /// The same measurement the setup tap runs — one implementation, so a ball
    /// learned here and a ball learned live cannot disagree about what a ball
    /// looks like.
    func learnBall(from swing: SwingDTO, tapX: Double, tapY: Double, t: Double) async {
        guard let clipName = swing.clipFilename else { return }
        let key = ballWindowKey(for: swing)
        let url = ClipStore.clipURL(named: clipName)
        let fov = swing.cameraFovDeg ?? 0
        let base = settings.detector
        guard let pb = await ClipFrameSampler.frame(url: url, at: t) else { return }
        let learned: DetectorSettings? = PixelImage.withImage(pb) { img in
            let w = Double(img.width)
            for r in [w * 0.12, w * 0.25, w * 0.45] {
                let attempt = SetupBallMeasure.measure(image: img, tapX: tapX, tapY: tapY,
                                                       searchRadiusPx: r,
                                                       settings: base, fovDeg: fov)
                if case .found = attempt.outcome { return attempt.learned }
                if case .needsWiderSearch = attempt.outcome { continue }
                break
            }
            return nil
        } ?? nil
        guard let learned else {
            // Silence here used to mean two different things — the frame could
            // not be decoded, or the tap found no ball — and both looked like
            // nothing happening. Say which, because the second is fixable by
            // tapping more accurately and the first is not.
            banner = Banner(kind: .warning,
                            text: "No ball found at that tap, so nothing was learned. Try tapping the centre of the ball.")
            return
        }
        learnedBallBySession[key] = learned
        if let sessionID = swing.sessionID {
            let n = swings.filter { $0.sessionID == sessionID }.count
            banner = Banner(kind: .info,
                            text: "Ball learned. Re-measure the round (\(n) swings) from the swing screen.")
        } else {
            banner = Banner(kind: .info,
                            text: "Ball learned from this clip and used to re-measure it.")
        }
    }

    /// Re-measure every swing in a round with the window just learned.
    ///
    /// A queue rather than a loop, because `reanalyze` is fire-and-forget: it
    /// hands the work to a detached task and returns. Draining a queue as each
    /// one lands keeps exactly one analysis in flight — which is what the
    /// phone can do anyway — without restructuring the path that every manual
    /// re-measure already uses and that is known to work.
    func reanalyzeRound(sessionID: UUID) {
        guard roundRemeasure == nil else { return }
        let queue = swings.filter { $0.sessionID == sessionID && $0.clipFilename != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard !queue.isEmpty else {
            banner = Banner(kind: .warning, text: "No clips in this round to re-measure.")
            return
        }
        roundQueue = queue
        roundRemeasure = RoundRemeasure(sessionID: sessionID, done: 0,
                                        total: queue.count, cancelling: false)
        startNextInRound()
    }

    func cancelRoundRemeasure() {
        guard roundRemeasure != nil else { return }
        roundRemeasure?.cancelling = true
        roundQueue.removeAll()
    }

    private func startNextInRound() {
        guard roundRemeasure != nil else { return }
        guard let next = roundQueue.first else {
            let done = roundRemeasure?.done ?? 0
            let cancelled = roundRemeasure?.cancelling ?? false
            roundRemeasure = nil
            banner = Banner(kind: .info,
                            text: cancelled ? "Stopped after \(done) swings."
                                            : "Re-measured \(done) swings.")
            return
        }
        roundQueue.removeFirst()
        reanalyze(next)
    }

    /// Called when any re-analysis finishes, successfully or not. A failed
    /// swing must not stall the round — it keeps its old reading and the queue
    /// moves on, which is also why the count says how many were re-measured
    /// rather than how many improved.
    private func roundStepFinished() {
        guard roundRemeasure != nil else { return }
        roundRemeasure?.done += 1
        startNextInRound()
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
        // The ball pointed at in this round beats the default window, exactly
        // as the setup tap does for a live one.
        let learned = learnedBallBySession[ballWindowKey(for: swing)]
        if let learned { options.detector = learned }
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
        // Re-analysis gets its own report, for the same reason the first pass
        // does: the whole point of re-measuring is to find out whether a change
        // helped, and the stage-by-stage account is the only thing that says
        // where it helped. Without this the button that exists to produce
        // evidence was deleting it.
        let diagnostics = ClipDiagnostics()
        diagnostics.ballWindowLearned = learned != nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await self.retryingWithFreeDecoder {
                    try await ClipAnalyzer.analyze(
                    url: url,
                    // Only a LIVE swing's contact time is a measurement — the
                    // audio trigger. On an import the stored value is just the
                    // first point of the PREVIOUS track, and on the tap-the-ball
                    // recovery flow that previous track is the wrong object by
                    // definition: feeding its start back in as "contact" made
                    // the analyzer extrapolate the corrected fit a second past
                    // its own data and filter out tracks starting before a
                    // contact that never happened.
                    contactTime: !swing.captureFlags.contains(.importedClip)
                        && swing.contactTime > 0 ? swing.contactTime : nil,
                    options: options,
                    diagnostics: diagnostics,
                    progress: self.throttledProgress())
                }
                let report = diagnostics.report(detector: options.detector)
                await MainActor.run {
                    self.lastDiagnostics = report
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
                    // The round the swing belongs to. Re-measuring a swing is
                    // not moving it: without this line the rebuilt DTO started
                    // with a nil session id, and "This round" filters on that,
                    // so tapping re-measure made the swing vanish from the
                    // round it was hit in, from that round's summary and from
                    // the past-rounds list derived off the same field.
                    updated.sessionID = swing.sessionID
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
                                     setting: swing.setting, into: &updated,
                                     report: report)
                    self.analysisProgress = nil
                    self.update(updated)
                    if self.roundRemeasure == nil {
                        self.banner = AppModel.Banner(kind: .info, text: "Re-analyzed.")
                    }
                    self.roundStepFinished()
                }
            } catch {
                await MainActor.run {
                    self.analysisProgress = nil
                    // A seed that found nothing keeps the swing exactly as it
                    // was rather than replacing it with a worse answer, and
                    // says which end of the pipeline to look at.
                    let kind: Banner.Kind =
                        (error as? ClipAnalysisError) == .noBallAtSeed ? .warning : .error
                    if self.roundRemeasure == nil {
                        self.banner = AppModel.Banner(kind: kind, text: error.localizedDescription)
                    }
                    self.roundStepFinished()
                }
            }
        }
    }

    func reload() {
        do {
            swings = try store.all()
            // Every derived-and-cached view of the swings keys off this.
            swingsRevision &+= 1
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

    // MARK: - Diagnostics bundle

    /// Everything needed to diagnose a set of swings, in ONE small file.
    ///
    /// The per-swing audit bundle shares the clip too, which is right for one
    /// swing and impossible for twenty: a 240fps clip is ~19 MB, so a round is
    /// most of a gigabyte and cannot be sent anywhere. Nothing in the ball
    /// analysis needs the video — it needs the candidates the detector
    /// produced, the tracks it built, and which one it chose.
    ///
    /// The traces are the bulk, and almost all of a trace is candidates from
    /// parts of the clip nothing happened in. Keeping only those within
    /// `candidateWindowS` of contact cuts a 660 KB trace to tens of KB while
    /// keeping the part any question is actually about — where the ball was
    /// when it was hit. Track summaries are kept whole, because "why was that
    /// one chosen" is answered by the losers.
    func exportDiagnostics(for doomed: [SwingDTO],
                           candidateWindowS: Double = 0.5) -> URL? {
        guard !doomed.isEmpty else { return nil }
        var out: [[String: Any]] = []
        for swing in doomed.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            var entry: [String: Any] = [
                "clip": swing.clipFilename ?? "(none)",
                "setting": swing.setting.rawValue,
                "capturedAt": ISO8601DateFormatter().string(from: swing.capturedAt),
                "contactTime": swing.contactTime,
                "launchAngleDeg": swing.launchAngleDeg,
                "exitVeloMph": swing.exitVeloMph,
                "flags": swing.flags.map(\.rawValue),
                "captureFlags": swing.captureFlags.map(\.rawValue),
                "cameraRollDeg": swing.cameraRollDeg as Any,
                "cameraTiltDeg": swing.cameraTiltDeg as Any,
                "cameraFovDeg": swing.cameraFovDeg as Any,
            ]
            if let id = swing.sessionID { entry["sessionID"] = id.uuidString }
            if let name = swing.diagnosticsFilename,
               let text = try? String(contentsOf: ClipStore.trackURL(named: name), encoding: .utf8) {
                entry["report"] = text
            }
            if let name = swing.trackCSVFilename,
               let text = try? String(contentsOf: ClipStore.trackURL(named: name), encoding: .utf8) {
                entry["trackCSV"] = text
            }
            if let name = swing.traceFilename,
               let data = try? Data(contentsOf: ClipStore.trackURL(named: name)),
               var trace = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let centre = swing.contactTime > 0 ? swing.contactTime : nil
                if let centre, let all = trace["candidates"] as? [[String: Any]] {
                    let kept = all.filter { c in
                        guard let t = c["t"] as? Double else { return false }
                        return abs(t - centre) <= candidateWindowS
                    }
                    trace["candidates"] = kept
                    // Say so IN the file. A trimmed trace that does not admit
                    // it reads as "the detector found nothing out there",
                    // which is the same shape as a real finding.
                    trace["candidatesTrimmedToWindowS"] = candidateWindowS
                    trace["candidatesTrimmedAround"] = centre
                    trace["candidatesBeforeTrim"] = all.count
                }
                // The per-frame census is small and is the whole point of the
                // gate instrumentation, so it is kept whole.
                entry["trace"] = trace
            }
            out.append(entry)
        }
        let doc: [String: Any] = [
            "swinglab_diagnostics_bundle": 1,
            "swings": out,
            "count": out.count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: doc,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let stamp = Self.stampFormatter.string(from: Date())
        let url = ClipStore.exportsDirectory
            .appendingPathComponent("diagnostics_\(out.count)swings_\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            banner = Banner(kind: .error, text: "Could not write the bundle: \(error.localizedDescription)")
            return nil
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
