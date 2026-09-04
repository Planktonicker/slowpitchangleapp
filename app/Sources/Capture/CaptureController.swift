// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// Owns the camera: 240fps capture, the rolling pre-roll ring, the audio
/// contact trigger, and committing swings to disk.
///
/// Threading: AVFoundation delivers video and audio on their own queues; the
/// encoder calls back on VideoToolbox's. Everything that touches the rings or
/// the recorder is funnelled through `pipelineQueue` so ordering is defined.
/// `@Published` state is always mutated on the main queue.
final class CaptureController: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case configuring
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var activeFormatDescription = ""
    @Published private(set) var fieldOfViewDeg: Double = 0
    @Published private(set) var fps: Double = SLA.targetFPS
    @Published private(set) var triggerLevelDb: Double = 0
    /// Frames dropped **while armed**, cumulative across the round.
    ///
    /// Not "frames dropped", which is what it used to be and could not be acted
    /// on. Three different things were summed into it: frames discarded on
    /// purpose while idle (the policy at `configure`), real drops from an armed
    /// stretch, and more idle discards piled on afterwards. Nothing on screen
    /// separated them, so a number in the hundreds meant nothing and trained
    /// the reader to ignore the one number that would have meant something.
    @Published private(set) var droppedFrameCount = 0
    /// Why they were dropped, when any were. Kept apart because the three
    /// causes call for different actions: `late` is the phone not keeping up
    /// (heat, another app); `outOfBuffers` is something holding the capture
    /// pool, which is the one that carries into the armed case where
    /// discarding is off and a starved pool stalls rather than sheds; and
    /// `discontinuity` is the capture pipeline itself hiccupping.
    @Published private(set) var dropReasons = DropReasons()

    struct DropReasons: Equatable {
        var late = 0
        var outOfBuffers = 0
        var discontinuity = 0
        var other = 0

        var total: Int { late + outOfBuffers + discontinuity + other }
        /// The dominant cause, for a chip that has room for one word.
        var headline: String? {
            let ranked = [("late", late), ("buffers", outOfBuffers),
                          ("camera", discontinuity), ("other", other)]
            guard let top = ranked.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return nil }
            return top.0
        }
    }
    @Published private(set) var isRecordingClip = false
    @Published private(set) var exposureLocked = false
    /// A person is currently detected in frame (pose gate, ~10 Hz).
    @Published private(set) var hitterPresent = false
    /// The hitter's skeleton in capture-device coordinates, for whichever
    /// screen is drawing it. Populated only while `wantsSkeleton` is set — the
    /// pose request runs regardless (it is the hitter gate), but converting and
    /// publishing its joints is pure cost when nothing is drawing them.
    @Published private(set) var skeleton: [PoseJoint: CGPoint]?

    /// Set while something wants the joints: the setup overlay always, the
    /// armed HUD if the hitter asked for it. See `skeleton`.
    var wantsSkeleton = false {
        didSet {
            guard wantsSkeleton != oldValue else { return }
            presenceGate.onPose = wantsSkeleton
                ? { [weak self] joints in
                    guard let self else { return }
                    // Inference runs at 10 Hz whether or not anybody is in
                    // frame, and `@Published` fires on every assignment,
                    // changed or not — so an empty field re-rendered the whole
                    // capture screen ten times a second to draw the same
                    // nothing. This guards only that case: with a hitter in
                    // frame the joints differ every sample and the publish rate
                    // is unchanged, which is the point of drawing them.
                    if joints == nil && self.skeleton == nil { return }
                    self.skeleton = joints
                }
                : nil
            if !wantsSkeleton { skeleton = nil }
        }
    }
    /// Audio impulses that fired with nobody in frame and were ignored.
    @Published private(set) var suppressedTriggerCount = 0
    /// The clip just recorded contained an impulse much louder than the one
    /// that triggered it — so the trigger heard something that was not the
    /// hit. Read and cleared by `AppModel` when the clip is filed.
    @Published var lastClipHeardLouderImpulse = false
    /// Non-nil while the system holds the camera (phone call, another app).
    @Published private(set) var interruptionMessage: String?
    /// What the ball-measurement gates saw on the last tap. Shown in setup so a
    /// rejection can be understood rather than guessed at.
    @Published private(set) var lastMeasureReport: String?
    /// Which way is up in the frames Vision receives. Derived from the
    /// device's rotation coordinator, never hardcoded: the phone lives sideways
    /// on a tripod, and a body-pose model handed a rotated human simply fails.
    @Published private(set) var visionOrientation: CGImagePropertyOrientation = .up
    @Published var isArmed = false {
        didSet {
            pipelineQueue.async { [weak self] in
                self?.syncArmed(startingRound: true)
            }
        }
    }

    /// Set while the setup overlay is on screen. Only then does the controller
    /// keep a BGRA snapshot for tap-to-measure; the armed hot path stays clean.
    ///
    /// Behind `snapshotLock`: written on the main thread, read per frame on
    /// the video queue, and both sides already take this lock for the
    /// snapshot itself.
    var wantsLiveMeasurement: Bool {
        get { snapshotLock.lock(); defer { snapshotLock.unlock() }; return _wantsLiveMeasurement }
        set {
            snapshotLock.lock()
            _wantsLiveMeasurement = newValue
            if !newValue { latestBGRASnapshot = nil }
            snapshotLock.unlock()
        }
    }
    private var _wantsLiveMeasurement = false

    /// Overrides `visionOrientation` when the user pins it in Settings. The
    /// 0/90/180/270 mapping is the classic thing to get backwards, and a wrong
    /// guess otherwise costs a whole trip to the field to discover.
    var visionOrientationOverride: CGImagePropertyOrientation? {
        didSet { if let o = visionOrientationOverride { setVisionOrientation(o) } }
    }

    /// When true, an audio trigger only records if a person was seen in the
    /// last ~1.5 s. Synced from Settings; manual capture always bypasses it.
    var requireHitterToTrigger = true

    /// How far a contact impulse must stand above the rolling noise floor.
    /// Synced from Settings — the slider previously moved a stored number that
    /// never reached the trigger, so lowering it to catch a quiet venue did
    /// nothing at all.
    var triggerThresholdDb: Double {
        get { trigger.thresholdDb }
        set { trigger.thresholdDb = newValue }
    }

    /// Seconds kept before and after contact. Synced from Settings for the
    /// same reason the threshold is: both sliders moved a stored number that
    /// the capture path never read, so the recorded window was always the
    /// compile-time default no matter what the screen said.
    ///
    /// Pre-roll has to cover the swing the body metrics are measured from —
    /// load, stride, then the barrel's approach — and the incoming pitch,
    /// which is what independently confirms the contact instant. Post-roll only
    /// has to outlast the ball's time in frame; past that it is storage for
    /// nothing. The ring is sized to the largest pre-roll the slider allows so
    /// the setting can be raised mid-session without restarting capture.
    var preRollS: Double = SLA.preRollS {
        didSet {
            let v = min(max(preRollS, 0.25), SLA.maxPreRollS)
            // pipelineQueue, not sessionQueue: that is the serial queue the
            // rings are appended and trimmed on, and SampleRing is explicitly
            // not thread-safe.
            pipelineQueue.async { [weak self] in
                self?.videoRing.maxDuration = v
                self?.audioRing.maxDuration = v + 0.5
            }
        }
    }
    var postRollS: Double = SLA.postRollS

    /// Fired on the main queue once a swing has been written to disk.
    var onClip: ((ClipRecorder.Output) -> Void)?
    var onError: ((String) -> Void)?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "swinglab.session")
    private let videoQueue = DispatchQueue(label: "swinglab.video")
    private let audioQueue = DispatchQueue(label: "swinglab.audio")
    private let pipelineQueue = DispatchQueue(label: "swinglab.pipeline")

    private var device: AVCaptureDevice?
    /// Guarded by `encoderLock` — written on sessionQueue during
    /// stop/configure, read on videoQueue at 240fps. See `VideoEncoder` for
    /// why the pointer handoff is the part that must be synchronized.
    private var encoder: VideoEncoder?
    private let encoderLock = NSLock()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoRing = SampleRing(maxDuration: SLA.preRollS, keyframeAligned: true)
    private let audioRing = SampleRing(maxDuration: SLA.preRollS + 0.5, keyframeAligned: false)
    private let recorder = ClipRecorder()
    private let trigger = ContactTrigger()
    private let presenceGate = HumanPresenceGate()
    private var clipCounter = 0
    private var videoFrameCounter = 0
    /// Newest frame converted to BGRA, for tap-to-measure during setup.
    ///
    /// Deliberately a copy from our own pool rather than the camera's buffer:
    /// holding one of the capture output's pooled buffers at 240fps with
    /// `alwaysDiscardsLateVideoFrames = false` starves the pool and shows up
    /// as dropped frames.
    private var latestBGRASnapshot: CVPixelBuffer?
    private let snapshotLock = NSLock()
    private var snapshotStride = 24
    private var converting = false
    private let convertQueue = DispatchQueue(label: "swinglab.convert", qos: .userInitiated)
    private var notificationTokens: [NSObjectProtocol] = []

    /// Frames between pose-gate submissions, computed once per configure so
    /// the video delegate never reads the main-actor-published `fps`.
    private var presenceStride = 24

    // Preview attachment. The layer's connection is created and owned
    // explicitly rather than falling out of a `.session` property assignment,
    // because that assignment blocks the main thread against a running
    // 240fps session and cannot be undone or repaired once the layer dies.
    private weak var attachedPreviewLayer: AVCaptureVideoPreviewLayer?
    private var previewConnection: AVCaptureConnection?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    /// The last angle the coordinator published. `sessionQueue` only.
    ///
    /// Needed because the angle and the connection do not have to exist at the
    /// same moment. Locking the phone rotates the window to portrait, which
    /// makes the coordinator publish; the session is stopped and restarted
    /// around the same transition, so the connection can be nil exactly then
    /// and the angle was simply dropped. It was never published again — the
    /// device had not moved, so there was nothing new to report — and the
    /// preview came back rotated wrong. Remembering it lets any connection made
    /// afterwards be brought up to date.
    private var lastPreviewRotationAngle: CGFloat?

    /// Queue-safe mirror of `visionOrientation`. The video delegate cannot read
    /// the `@Published` copy, which belongs to the main queue.
    private let orientationLock = NSLock()
    private var _visionOrientationForFrames: CGImagePropertyOrientation = .up
    var visionOrientationForFrames: CGImagePropertyOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return _visionOrientationForFrames
    }

    // Coalesced UI publishing. The audio path produced one main-queue hop per
    // buffer (~50-100/s) and drops produced one per frame; each hop invalidated
    // the whole environment-object tree. Values are accumulated on their own
    // queues and flushed at 10 Hz, only when something visibly changed.
    private var uiTimer: DispatchSourceTimer?
    private let uiLock = NSLock()
    private var pendingDb: Double = 0
    private var publishedDb: Double = 0
    private var pendingDrops = 0
    private var publishedDrops = 0
    private var pendingReasons = DropReasons()
    private var publishedReasons = DropReasons()
    /// The drop-reason constants, bridged once rather than per dropped frame.
    /// Explicitly typed, so the coercion happens here where it is a plain
    /// conversion and not in a pattern position where it is not.
    private static let dropReasonLate: String =
        kCMSampleBufferDroppedFrameReason_FrameWasLate as String
    private static let dropReasonOutOfBuffers: String =
        kCMSampleBufferDroppedFrameReason_OutOfBuffers as String
    private static let dropReasonDiscontinuity: String =
        kCMSampleBufferDroppedFrameReason_Discontinuity as String

    /// Whether `didDrop` counts at all.
    ///
    /// Guarded by `uiLock`, which the drop callback already takes — rather than
    /// read off `pipelineIsArmed`, which is owned by `pipelineQueue` and would
    /// be an unsynchronised cross-queue read from the video delegate. That is
    /// the same mistake already fixed once for `fps` and the vision
    /// orientation.
    private var countingDrops = false

    override init() {
        super.init()
        trigger.onContact = { [weak self] pts, db in
            self?.pipelineQueue.async {
                self?.startClip(contactPTS: pts, gated: true, triggerDb: db)
            }
        }
        presenceGate.onPresenceChange = { [weak self] present in
            self?.hitterPresent = present
        }
        installInterruptionObservers()
        startUITimer()
    }

    deinit {
        uiTimer?.cancel()
        for observation in rotationObservations { observation.invalidate() }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Publishes the two high-rate readouts at 10 Hz instead of per buffer.
    private func startUITimer() {
        let timer = DispatchSource.makeTimerSource(queue: pipelineQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.uiLock.lock()
            let db = self.pendingDb
            // Release the peak hold: without this the meter would latch the
            // loudest thing ever heard instead of the loudest in each tick.
            self.pendingDb = -.infinity
            let drops = self.pendingDrops
            let reasons = self.pendingReasons
            let dbChanged = db.isFinite && abs(db - self.publishedDb) >= 0.5
            let dropsChanged = drops != self.publishedDrops
            if dbChanged { self.publishedDb = db }
            if dropsChanged {
                self.publishedDrops = drops
                self.publishedReasons = reasons
            }
            self.uiLock.unlock()

            guard dbChanged || dropsChanged else { return }
            DispatchQueue.main.async {
                if dbChanged { self.triggerLevelDb = db }
                if dropsChanged {
                    self.droppedFrameCount = drops
                    self.dropReasons = reasons
                }
            }
        }
        timer.resume()
        uiTimer = timer
    }

    /// The camera can be taken away at any time — a phone call, another app,
    /// the system. Without these observers that manifests as a silently black
    /// preview; with them the UI says what happened and the session restarts
    /// itself when the camera comes back.
    private func installInterruptionObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            self?.interruptionMessage = "Camera paused by the system — waiting to get it back…"
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.interruptionMessage = nil
            // The session usually resumes on its own; kick it if it didn't.
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.interruptionMessage = "Camera error — restarting…"
            // One automatic recovery attempt after a beat.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.5) {
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    if self.session.isRunning {
                        self.interruptionMessage = nil
                    } else {
                        self.setStatus(.failed(error?.localizedDescription ?? "camera failed"))
                    }
                }
            }
        })
    }

    // MARK: - Preview attachment

    /// Bind a preview layer to the session.
    ///
    /// Assigning `layer.session` on the main thread blocks against a running
    /// 240fps session — that was the multi-second hang when the setup screen
    /// opened. Instead the layer is attached with no connection and we build
    /// the `AVCaptureConnection` ourselves on `sessionQueue`, inside a
    /// begin/commit pair. Owning the connection is also what makes re-attach
    /// possible after a reconfigure destroys the graph.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        attachedPreviewLayer = layer
        sessionQueue.async { [weak self] in
            self?.bindPreviewLayer(layer, reconfiguring: true)
        }
    }

    func detachPreview() {
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.previewConnection else { return }
            self.session.beginConfiguration()
            self.session.removeConnection(connection)
            self.session.commitConfiguration()
            self.previewConnection = nil
        }
    }

    /// Must run on `sessionQueue`. When `reconfiguring` is false the caller
    /// already holds a begin/commit pair (i.e. `configure()`).
    private func bindPreviewLayer(_ layer: AVCaptureVideoPreviewLayer,
                                  reconfiguring: Bool) {
        guard let input = session.inputs.first as? AVCaptureDeviceInput,
              let port = input.ports(for: .video,
                                     sourceDeviceType: input.device.deviceType,
                                     sourceDevicePosition: input.device.position).first
        else { return }

        if reconfiguring { session.beginConfiguration() }
        defer { if reconfiguring { session.commitConfiguration() } }

        if let existing = previewConnection {
            session.removeConnection(existing)
            previewConnection = nil
        }
        // No CATransaction here, for the reason spelled out in
        // `applyPreviewRotation`: a commit from this queue drains the main
        // thread's pending layout onto it. The implicit animation this used to
        // suppress — which on a preview layer reads as a flash of black — is
        // turned off on the layer itself instead, once, in
        // `CameraPreview.PreviewLayerView.init`.
        layer.setSessionWithNoConnection(session)

        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else { return }
        session.addConnection(connection)
        previewConnection = connection
        // A brand-new connection starts at the default angle, so bring it up to
        // whatever the last known one was before anything is drawn through it.
        if let angle = lastPreviewRotationAngle { applyPreviewRotation(angle) }

        // Re-enqueued rather than called here. `RotationCoordinator`'s init
        // has to read the layer's window and scene, which is main-thread work,
        // and this call site still holds the session's begin/commit pair — the
        // commit is in the `defer` above. Reaching for the main thread while
        // holding that lock is the same shape of trouble as the transaction
        // above. `sessionQueue` is serial, so this simply runs once the commit
        // has returned, and `rotationCoordinator` and `rotationObservations`
        // stay owned by the queue that has always owned them.
        let device = input.device
        sessionQueue.async { [weak self] in
            self?.installRotationCoordinator(device: device, layer: layer)
        }
    }

    /// Re-apply the current rotation to whatever connection exists now.
    ///
    /// Called when the app comes back to the foreground. Nothing about the
    /// phone changed while it was locked, so the coordinator has no reason to
    /// publish again — but the connection it last published to may be gone.
    func refreshPreviewRotation() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelPreview {
                self.applyPreviewRotation(angle)
            } else if let angle = self.lastPreviewRotationAngle {
                self.applyPreviewRotation(angle)
            }
            if let capture = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
                self.setVisionOrientation(Self.orientation(forCaptureAngle: capture))
            }
        }
    }

    /// One source of truth for "which way is up" — feeding both the preview
    /// connection and Vision. Replaces two hardcoded orientation tables.
    private func installRotationCoordinator(device: AVCaptureDevice,
                                            layer: AVCaptureVideoPreviewLayer) {
        for observation in rotationObservations { observation.invalidate() }
        rotationObservations.removeAll()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                              previewLayer: layer)
        rotationCoordinator = coordinator

        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        setVisionOrientation(Self.orientation(
            forCaptureAngle: coordinator.videoRotationAngleForHorizonLevelCapture))

        rotationObservations.append(coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.sessionQueue.async { self?.applyPreviewRotation(angle) }
        })
        rotationObservations.append(coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.setVisionOrientation(Self.orientation(forCaptureAngle: angle))
        })
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        // Recorded before the guard, not after. The whole point is to keep the
        // angle when there is nothing to apply it to yet.
        lastPreviewRotationAngle = angle
        guard let connection = previewConnection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        // The write, and its transaction, on the MAIN thread — this is the
        // rotation hang.
        //
        // This connection belongs to the preview layer, so setting its angle
        // moves geometry in the window's layer tree. CoreAnimation's
        // needs-layout set is process-wide, not per-transaction: whichever
        // thread commits next drains it. A commit from `sessionQueue`
        // therefore pulls whatever layout the main thread has outstanding onto
        // `sessionQueue` — and the one moment this code runs is a rotation,
        // when the main thread has the entire hierarchy marked needs-layout
        // and is part way through it. Two threads then run UIKit layout over
        // the same views and the update wedges: a landscape guide and a
        // landscape tab bar inside a portrait window, with the picture already
        // turned because THIS write is the half that got through.
        //
        // This is not the `layer.session` rule from CLAUDE.md. That rule is
        // about BUILDING the graph, which really does block for seconds
        // against a running 240fps session. Writing an angle to a connection
        // that already exists is a property write on a UI object.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            connection.videoRotationAngle = angle
            CATransaction.commit()
        }
    }

    private func setVisionOrientation(_ orientation: CGImagePropertyOrientation) {
        let resolved = visionOrientationOverride ?? orientation
        orientationLock.lock()
        _visionOrientationForFrames = resolved
        orientationLock.unlock()
        DispatchQueue.main.async {
            if self.visionOrientation != resolved { self.visionOrientation = resolved }
        }
    }

    /// The rotation the buffer needs to appear upright, as an EXIF orientation.
    static func orientation(forCaptureAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle.rounded()) % 360 {
        case 90:  return .right
        case 180: return .down
        case 270: return .left
        default:  return .up
        }
    }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }

    // MARK: - Lifecycle

    func configureAndStart() {
        setStatus(.configuring)
        // Establish the armed invariant BEFORE the session runs. `syncArmed`
        // used to run only from `isArmed.didSet`, which by definition has not
        // fired on a fresh start — so the trigger sat at whatever its default
        // was. The default has been fixed too, but the invariant should not
        // depend on a default agreeing with a UI flag.
        pipelineQueue.async { [weak self] in self?.syncArmed() }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Already live (e.g. .task re-fired without a matching stop):
            // reconfiguring a running session for no reason just glitches
            // the preview.
            if self.session.isRunning {
                self.setStatus(.running)
                return
            }
            do {
                try self.configure()
                self.session.startRunning()
                self.setStatus(.running)
            } catch {
                self.setStatus(.failed(error.localizedDescription))
            }
        }
    }

    /// Resolves once every operation already queued on the session queue has
    /// run — including a `stop()` enqueued a moment earlier.
    ///
    /// `stop()` is asynchronous, so "I stopped the camera, now decode a file"
    /// is a race: the reader can start while the session is still holding the
    /// hardware decoder, which is the failure this exists to close. The queue
    /// is serial, so simply getting to the back of it is the whole mechanism.
    func quiesce() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.encoderLock.lock()
            let enc = self.encoder
            self.encoder = nil
            self.encoderLock.unlock()
            enc?.invalidate()
            self.setStatus(.idle)
        }
        pipelineQueue.async { [weak self] in
            self?.videoRing.removeAll()
            self?.audioRing.removeAll()
            self?.recorder.cancel()
            // cancel() kills the recording without a completion, so nothing
            // downstream will ever clear the indicator — do it here, or a
            // round ended during the post-roll leaves REC shown forever and
            // the idle timer disabled off the back of it.
            DispatchQueue.main.async { self?.isRecordingClip = false }
        }
    }

    private func configure() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord,
                                      mode: .videoRecording,
                                      options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)

        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Strip any previous graph. `canAddInput` answers false while the old
        // inputs are still attached, which would otherwise kill the camera
        // permanently.
        //
        // Only our own preview connection is removed explicitly — the
        // input/output connections the session formed implicitly are torn down
        // by removing their inputs and outputs, and asking to remove one
        // directly is not allowed. The preview layer is re-bound at the end of
        // this method.
        if let existing = previewConnection {
            session.removeConnection(existing)
            previewConnection = nil
        }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        encoderLock.lock()
        let oldEncoder = encoder
        encoder = nil
        encoderLock.unlock()
        oldEncoder?.invalidate()

        // `.inputPriority` keeps our chosen 240fps format; a preset would
        // override it.
        session.sessionPreset = .inputPriority

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw CaptureError.noCamera
        }
        device = camera

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else { throw CaptureError.cannotAddInput }
        session.addInput(videoInput)

        if let mic = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(audioInput) { session.addInput(audioInput) }
        }

        guard let choice = FormatSelector.best(for: camera) else {
            throw CaptureError.noSuitableFormat
        }
        try FormatSelector.apply(choice, to: camera)

        // Native pixel format: the encoder takes it directly, and nothing in
        // the live path needs RGB. Analysis re-reads the file as BGRA.
        videoOutput.videoSettings = nil
        // Never discard *while armed*: a measurement built on a frame interval
        // cannot tolerate silent gaps, so drops are counted and surfaced.
        // Before arming there is nothing to measure — the frames only feed the
        // preview, the pose gate and setup — and refusing to discard there just
        // backs the queue up and reports hundreds of drops that mean nothing.
        videoOutput.alwaysDiscardsLateVideoFrames = !isArmed
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        let enc = try VideoEncoder(width: choice.width, height: choice.height, fps: choice.fps)
        enc.onEncoded = { [weak self] sb in
            self?.pipelineQueue.async { self?.handleEncoded(sb) }
        }
        encoderLock.lock()
        encoder = enc
        encoderLock.unlock()

        // Read once here rather than off the @Published `fps` in the video
        // delegate, which was a genuine data race across two queues.
        presenceStride = max(1, Int(choice.fps / 10))
        snapshotStride = max(1, Int(choice.fps / 10))

        // The graph was rebuilt above, so any live preview layer lost its
        // connection with it. Re-bind inside this begin/commit pair.
        if let layer = attachedPreviewLayer {
            bindPreviewLayer(layer, reconfiguring: false)
        }

        DispatchQueue.main.async {
            self.activeFormatDescription = choice.describes
            self.fieldOfViewDeg = choice.fieldOfViewDeg
            self.fps = choice.fps
        }
    }

    // MARK: - Exposure

    /// Lock focus and exposure, matching the capture protocol's
    /// press-and-hold AE/AF lock. Without it a passing cloud changes exposure
    /// mid-session and the ball smears differently swing to swing.
    func lockExposureAndFocus(at point: CGPoint? = nil) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let p = point {
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = p
                    }
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = p
                    }
                }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            } catch { return }

            // Let autofocus/exposure settle, then pin them.
            self?.sessionQueue.asyncAfter(deadline: .now() + 0.6) {
                guard let device = self?.device else { return }
                try? device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self?.exposureLocked = true }
            }
        }
    }

    func unlockExposureAndFocus() {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self?.exposureLocked = false }
        }
    }

    // MARK: - Triggering

    /// Force a clip without waiting for a contact impulse — the escape hatch
    /// for a venue where G5 fails, and how the cage gets used if its acoustics
    /// defeat the trigger. Bypasses the hitter gate: a human pressed it.
    func triggerManually() {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.startClip(contactPTS: now, gated: false)
        }
    }

    /// Measure the ball the user just tapped.
    ///
    /// - Parameter devicePoint: normalised camera coordinates from
    ///   `AVCaptureVideoPreviewLayer.captureDevicePointConverted`. Its origin
    ///   convention matches the capture buffer's row layout, so scaling by the
    ///   buffer dimensions lands on the right pixel without any rotation math.
    ///
    /// Runs off the capture queues — a full-frame scan on `videoQueue` would
    /// stall frame delivery at 240fps. Completion on the main queue.
    func measure(atDevicePoint devicePoint: CGPoint,
                 detector: DetectorSettings,
                 completion: @escaping (BallMeasureResult) -> Void) {
        snapshotLock.lock()
        let snapshot = latestBGRASnapshot
        snapshotLock.unlock()

        let fov = fieldOfViewDeg
        DispatchQueue.global(qos: .userInitiated).async {
            guard let snapshot else {
                DispatchQueue.main.async { completion(.noFrameYet) }
                return
            }
            let outcome: (BallMeasureResult, String) = PixelImage.withImage(snapshot) { img in
                let px = Double(devicePoint.x) * Double(img.width)
                let py = Double(devicePoint.y) * Double(img.height)
                // Search windows scale with the frame, not a fixed 160 px. A
                // ball two feet from the lens is several hundred pixels across
                // and needs room around it for the shape tests to run at all;
                // a fixed window silently capped the working distance.
                let w = Double(img.width)
                let radii = [w * 0.12, w * 0.25, w * 0.45]
                var last: SetupBallMeasure.Outcome = .nothingThere
                var report = ""
                for r in radii {
                    let attempt = SetupBallMeasure.measure(image: img,
                                                           tapX: px, tapY: py,
                                                           searchRadiusPx: r,
                                                           settings: detector,
                                                           fovDeg: fov)
                    last = attempt.outcome
                    report = attempt.report
                    switch last {
                    case .found(let m):
                        return (.found(m), report)
                    case .needsWiderSearch:
                        continue          // only this one is worth retrying
                    default:
                        break
                    }
                    break
                }
                switch last {
                case .found(let m):          return (.found(m), report)
                case .notAnEdge:             return (.notAnEdge, report)
                case .mergedWithBackground:  return (.mergedWithBackground, report)
                case .shadowed:              return (.shadowed, report)
                case .truncatedByFrame:      return (.truncatedByFrame, report)
                case .needsWiderSearch, .nothingThere:
                    return (.noBallNearTap(searchRadiusPx: radii.last ?? 0), report)
                }
            } ?? (.conversionFailed, "frame could not be read as BGRA")
            DispatchQueue.main.async {
                self.lastMeasureReport = outcome.1.isEmpty ? nil : outcome.1
                completion(outcome.0)
            }
        }
    }

    /// True when the pose gate has been running since `start` without ever
    /// detecting anyone — the signature of a gate that is broken rather than
    /// an empty field. Used to offer an escape hatch instead of silently
    /// suppressing every trigger, which is how the field test lost its hits.
    func hitterGateNeverFired(since start: CFTimeInterval) -> Bool {
        presenceGate.looksUnreliable(since: start)
    }

    /// - Parameter startingRound: whether this begins a NEW armed stretch.
    ///
    /// False when re-arming after a clip, and that distinction is a measurement
    /// bug rather than a nicety. `finishClip` calls this once the clip is
    /// written, with `isArmed` still true — so the old unconditional reset
    /// zeroed the counter after every swing. `AppModel.handleClip` latches its
    /// baseline from the counter BEFORE that lands (`onClip` is called
    /// synchronously; the re-arm is enqueued after it), so the baseline
    /// ratcheted upward while the counter restarted at zero, and swing *k*
    /// could only raise FRAMES_DROPPED by dropping MORE than swing *k-1*. A
    /// phone shedding a steady handful of frames per clip therefore flagged
    /// exactly one swing and then went quiet — and thermal drops get worse over
    /// a session, not better, so the quiet swings were the less trustworthy
    /// ones. The count is now cumulative for the round.
    private func syncArmed(startingRound: Bool = false) {
        pipelineIsArmed = isArmed
        trigger.isArmed = isArmed && !recorder.isRecording
        if isArmed { trigger.reset() }
        let armed = isArmed
        let resetting = armed && startingRound
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOutput.alwaysDiscardsLateVideoFrames = !armed
            // Counting follows arming exactly. While idle, late frames are
            // discarded ON PURPOSE, and counting a deliberate discard as a
            // fault is what put "483 DROPPED" on an amber chip in front of
            // somebody who had been told to watch that number.
            self.uiLock.lock()
            self.countingDrops = armed
            if resetting {
                self.pendingDrops = 0
                self.publishedDrops = 0
                self.pendingReasons = DropReasons()
                self.publishedReasons = DropReasons()
            }
            self.uiLock.unlock()
            if resetting {
                DispatchQueue.main.async {
                    self.droppedFrameCount = 0
                    self.dropReasons = DropReasons()
                }
            }
        }
    }

    /// Mirror of `isArmed` owned by `pipelineQueue`, so the recording path
    /// can consult it without a cross-thread read of a @Published var.
    private var pipelineIsArmed = false

    /// How loud the impulse that started the current clip was, over the
    /// rolling floor. `-infinity` for a manual clip, which had no impulse.
    private var clipTriggerDb: Double = -.infinity

    private func startClip(contactPTS: CMTime, gated: Bool,
                           triggerDb: Double = -.infinity) {
        guard !recorder.isRecording else { return }
        guard !videoRing.isEmpty else { return }
        // Belt and braces with the trigger's own armed flag. The flag alone
        // proved insufficient once: it defaulted to armed and nothing synced
        // it until the first ARM press, so the app recorded swings while the
        // screen said it would not. An audio trigger reaching this point on an
        // unarmed controller is a bug upstream — refuse it here regardless.
        if gated && !pipelineIsArmed { return }
        // The no-human false trigger from field testing: a sharp noise with
        // nobody in frame. Recording it would waste a clip AND corrupt G1
        // with a clip that never contained a swing, so it is suppressed —
        // counted, so the miss is visible, but never written to disk.
        if gated && requireHitterToTrigger && !presenceGate.recentlyPresent {
            DispatchQueue.main.async { self.suppressedTriggerCount += 1 }
            return
        }
        trigger.isArmed = false
        clipTriggerDb = triggerDb
        // Zeroed here so the peak measured over this clip is the peak DURING
        // it, not one inherited from the wait before it.
        _ = trigger.consumePeakSinceArm()
        // Which way the buffer must turn for display, as a matrix on the
        // file. `visionOrientationForFrames` already answers "which way is
        // up" for the pose gate; this writes the same answer where players
        // and the analyzer can read it.
        let turns = VideoOrientation.quarterTurns(from: visionOrientationForFrames)
        recorder.begin(videoRing: videoRing.samples,
                       audioRing: audioRing.samples,
                       contactPTS: contactPTS,
                       postRoll: postRollS,
                       manual: !gated,
                       displayTransform: CGAffineTransform(
                           rotationAngle: CGFloat(turns) * .pi / 2))
        DispatchQueue.main.async { self.isRecordingClip = true }
    }

    private func finishClip() {
        clipCounter += 1
        let url = ClipStore.newClipURL(index: clipCounter)
        // Was anything in this clip much louder than the thing that started
        // it? If so the trigger did not hear the hit, and the contact time on
        // this clip is the time of something else.
        //
        // The trigger is disarmed for the whole of a clip, so it cannot fire
        // on the real crack and cannot re-centre itself — and re-centring
        // would be the wrong fix anyway, because the loudest sound in a swing
        // clip is not always the bat: a ball into a chain-link fence 1.2 s
        // later can beat it, and moving contact FORWARD onto that is worse
        // than leaving it early. So this records rather than corrects. The
        // analyzer already recovers the reading (CONTACT_TIME_REJECTED); what
        // this adds is the reason, at capture time, while the venue is still
        // in front of the person who can fix it.
        let clipPeakDb = trigger.consumePeakSinceArm()
        let heardLouder = clipTriggerDb.isFinite && clipPeakDb.isFinite
            && clipPeakDb >= clipTriggerDb + SLA.retriggerMarginDb
        if heardLouder {
            DispatchQueue.main.async { self.lastClipHeardLouderImpulse = true }
        }
        recorder.finish(url: url) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRecordingClip = false
                switch result {
                case .success(let output):
                    self.onClip?(output)
                case .failure(let error):
                    self.onError?(error.localizedDescription)
                }
                // Re-arm only after the clip is safely written.
                self.pipelineQueue.async { self.syncArmed() }
            }
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        videoRing.append(sb)
        if recorder.isRecording {
            if recorder.appendVideo(sb) { finishClip() }
        }
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async {
            self.status = s
            if case .failed(let message) = s { self.onError?(message) }
        }
    }

    enum CaptureError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput, noSuitableFormat

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No back camera available."
            case .cannotAddInput: return "Could not attach the camera."
            case .cannotAddOutput: return "Could not attach the video output."
            case .noSuitableFormat:
                return "This device offers no high-speed capture format."
            }
        }
    }
}

// MARK: - Sample delivery

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            videoFrameCounter += 1
            // Feed the pose gate roughly every 100 ms — every 240fps frame
            // would be waste; presence does not change at 240 Hz.
            if videoFrameCounter % presenceStride == 0 {
                presenceGate.submit(pixelBuffer: pb, orientation: visionOrientationForFrames)
            }
            // Only while setup is on screen: keep one BGRA copy so a tap has
            // something to measure. Converted on its own queue — a CoreImage
            // render is far too slow to sit on the 240fps delivery path, and
            // doing it there was throttling frame delivery outright.
            if wantsLiveMeasurement, videoFrameCounter % snapshotStride == 0 {
                snapshotLock.lock()
                let busy = converting
                if !busy { converting = true }
                snapshotLock.unlock()
                if !busy {
                    convertQueue.async { [weak self] in
                        guard let self else { return }
                        let bgra = PixelBufferConvert.toBGRA(pb)
                        self.snapshotLock.lock()
                        if let bgra { self.latestBGRASnapshot = bgra }
                        self.converting = false
                        self.snapshotLock.unlock()
                    }
                }
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            encoderLock.lock()
            let liveEncoder = encoder
            encoderLock.unlock()
            liveEncoder?.encode(pixelBuffer: pb, pts: pts, duration: duration)
        } else {
            trigger.process(sampleBuffer: sampleBuffer)
            // Peak since the last read, not the final window of this buffer:
            // the published level exists so calibration and the meter can see
            // impulses, and an impulse rarely lands in the final window.
            let db = trigger.consumePeakDb()
            uiLock.lock()
            pendingDb = max(pendingDb, db)
            uiLock.unlock()
            pipelineQueue.async { [weak self] in
                guard let self else { return }
                self.audioRing.append(sampleBuffer)
                if self.recorder.isRecording { self.recorder.appendAudio(sampleBuffer) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        // The reason is an attachment on the (empty) dropped buffer. Read
        // before taking the lock: it is a dictionary lookup, and this runs on
        // the delegate queue that 240 fps delivery depends on.
        let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil) as? String

        uiLock.lock()
        // Only while armed. Idle discards are the discard POLICY working, not
        // a fault — see `syncArmed`.
        if countingDrops {
            pendingDrops += 1
            // `if`, not `switch`, and compared against constants bridged
            // above. Inside a `case`, `x as String` parses as a cast PATTERN
            // rather than a coercion, so the pattern kept its CFString type
            // and could not match the bridged String subject.
            if reason == Self.dropReasonLate {
                pendingReasons.late += 1
            } else if reason == Self.dropReasonOutOfBuffers {
                pendingReasons.outOfBuffers += 1
            } else if reason == Self.dropReasonDiscontinuity {
                pendingReasons.discontinuity += 1
            } else {
                pendingReasons.other += 1
            }
        }
        uiLock.unlock()
    }
}
