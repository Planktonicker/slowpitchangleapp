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
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var isRecordingClip = false
    @Published private(set) var exposureLocked = false
    /// A person is currently detected in frame (pose gate, ~10 Hz).
    @Published private(set) var hitterPresent = false
    /// The hitter's skeleton in capture-device coordinates, for the setup
    /// overlay to draw. Populated only while `wantsSkeleton` is set — the pose
    /// request runs regardless (it is the hitter gate), but converting and
    /// publishing its joints is pure cost when nothing is drawing them.
    @Published private(set) var skeleton: [PoseJoint: CGPoint]?

    /// Set while the setup overlay is on screen. See `skeleton`.
    var wantsSkeleton = false {
        didSet {
            guard wantsSkeleton != oldValue else { return }
            presenceGate.onPose = wantsSkeleton
                ? { [weak self] joints in self?.skeleton = joints }
                : nil
            if !wantsSkeleton { skeleton = nil }
        }
    }
    /// Audio impulses that fired with nobody in frame and were ignored.
    @Published private(set) var suppressedTriggerCount = 0
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
        didSet { pipelineQueue.async { [weak self] in self?.syncArmed() } }
    }

    /// Set while the setup overlay is on screen. Only then does the controller
    /// keep a BGRA snapshot for tap-to-measure; the armed hot path stays clean.
    var wantsLiveMeasurement = false {
        didSet {
            if !wantsLiveMeasurement {
                snapshotLock.lock()
                latestBGRASnapshot = nil
                snapshotLock.unlock()
            }
        }
    }

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

    /// Fired on the main queue once a swing has been written to disk.
    var onClip: ((ClipRecorder.Output) -> Void)?
    var onError: ((String) -> Void)?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "swinglab.session")
    private let videoQueue = DispatchQueue(label: "swinglab.video")
    private let audioQueue = DispatchQueue(label: "swinglab.audio")
    private let pipelineQueue = DispatchQueue(label: "swinglab.pipeline")

    private var device: AVCaptureDevice?
    private var encoder: VideoEncoder?
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

    override init() {
        super.init()
        trigger.onContact = { [weak self] pts in
            self?.pipelineQueue.async { self?.startClip(contactPTS: pts, gated: true) }
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
            let drops = self.pendingDrops
            let dbChanged = abs(db - self.publishedDb) >= 0.5
            let dropsChanged = drops != self.publishedDrops
            if dbChanged { self.publishedDb = db }
            if dropsChanged { self.publishedDrops = drops }
            self.uiLock.unlock()

            guard dbChanged || dropsChanged else { return }
            DispatchQueue.main.async {
                if dbChanged { self.triggerLevelDb = db }
                if dropsChanged { self.droppedFrameCount = drops }
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
        // Layer mutations are implicitly animated; that animation on a preview
        // layer reads as a flash of black.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setSessionWithNoConnection(session)
        CATransaction.commit()

        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else { return }
        session.addConnection(connection)
        previewConnection = connection
        // A brand-new connection starts at the default angle, so bring it up to
        // whatever the last known one was before anything is drawn through it.
        if let angle = lastPreviewRotationAngle { applyPreviewRotation(angle) }

        installRotationCoordinator(device: input.device, layer: layer)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        connection.videoRotationAngle = angle
        CATransaction.commit()
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

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.encoder?.invalidate()
            self.encoder = nil
            self.setStatus(.idle)
        }
        pipelineQueue.async { [weak self] in
            self?.videoRing.removeAll()
            self?.audioRing.removeAll()
            self?.recorder.cancel()
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
        encoder?.invalidate()
        encoder = nil

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
        encoder = enc

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

    private func syncArmed() {
        trigger.isArmed = isArmed && !recorder.isRecording
        if isArmed { trigger.reset() }
        let armed = isArmed
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOutput.alwaysDiscardsLateVideoFrames = !armed
            if armed {
                // The count that matters starts here; drops accumulated while
                // idle say nothing about a measurement.
                self.uiLock.lock()
                self.pendingDrops = 0
                self.publishedDrops = 0
                self.uiLock.unlock()
                DispatchQueue.main.async { self.droppedFrameCount = 0 }
            }
        }
    }

    private func startClip(contactPTS: CMTime, gated: Bool) {
        guard !recorder.isRecording else { return }
        guard !videoRing.isEmpty else { return }
        // The no-human false trigger from field testing: a sharp noise with
        // nobody in frame. Recording it would waste a clip AND corrupt G1
        // with a clip that never contained a swing, so it is suppressed —
        // counted, so the miss is visible, but never written to disk.
        if gated && requireHitterToTrigger && !presenceGate.recentlyPresent {
            DispatchQueue.main.async { self.suppressedTriggerCount += 1 }
            return
        }
        trigger.isArmed = false
        recorder.begin(videoRing: videoRing.samples,
                       audioRing: audioRing.samples,
                       contactPTS: contactPTS,
                       postRoll: SLA.postRollS)
        DispatchQueue.main.async { self.isRecordingClip = true }
    }

    private func finishClip() {
        clipCounter += 1
        let url = ClipStore.newClipURL(index: clipCounter)
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
            encoder?.encode(pixelBuffer: pb, pts: pts, duration: duration)
        } else {
            trigger.process(sampleBuffer: sampleBuffer)
            let db = trigger.lastDb
            uiLock.lock()
            pendingDb = db
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
        uiLock.lock()
        pendingDrops += 1
        uiLock.unlock()
    }
}
