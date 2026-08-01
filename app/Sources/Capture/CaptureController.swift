// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation

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
    /// Audio impulses that fired with nobody in frame and were ignored.
    @Published private(set) var suppressedTriggerCount = 0
    /// Non-nil while the system holds the camera (phone call, another app).
    @Published private(set) var interruptionMessage: String?
    @Published var isArmed = false {
        didSet { pipelineQueue.async { [weak self] in self?.syncArmed() } }
    }

    /// When true, an audio trigger only records if a person was seen in the
    /// last ~1.5 s. Synced from Settings; manual capture always bypasses it.
    var requireHitterToTrigger = true

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
    /// Newest camera frame, for on-demand measurements (ball-size setup).
    /// Touched only on `videoQueue`.
    private var latestFrame: CVPixelBuffer?
    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        trigger.onContact = { [weak self] pts in
            self?.pipelineQueue.async { self?.startClip(contactPTS: pts, gated: true) }
        }
        presenceGate.onPresenceChange = { [weak self] present in
            self?.hitterPresent = present
        }
        installInterruptionObservers()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
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

        // Strip any previous graph. Reconfiguration is routine — every tab
        // switch and every return from the wizard's AR step lands here — and
        // canAddInput answers false while the old inputs are still attached,
        // which would otherwise kill the camera permanently.
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
        // Never discard: a measurement built on a frame interval cannot
        // tolerate silent gaps. Drops are counted and surfaced instead.
        videoOutput.alwaysDiscardsLateVideoFrames = false
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

    /// Measure the ball in the newest camera frame — the one-tap setup path.
    /// Finds the largest ball-coloured blob at rest and hands back its
    /// sub-pixel diameter. Completion on the main queue.
    func measureBall(detector: DetectorSettings,
                     completion: @escaping (Double?) -> Void) {
        videoQueue.async { [weak self] in
            guard let self, let frame = self.latestFrame else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let diameter = PixelImage.withImage(frame) { img -> Double? in
                let candidates = BallDetector.detect(image: img, frame: 0, t: 0,
                                                     settings: detector)
                return candidates.map(\.diameterPx).max()
            } ?? nil
            DispatchQueue.main.async { completion(diameter) }
        }
    }

    private func syncArmed() {
        trigger.isArmed = isArmed && !recorder.isRecording
        if isArmed { trigger.reset() }
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
            latestFrame = pb
            // Feed the pose gate roughly every 100 ms — every 240fps frame
            // would be waste; presence does not change at 240 Hz.
            videoFrameCounter += 1
            if videoFrameCounter % max(1, Int(fps / 10)) == 0 {
                presenceGate.submit(pixelBuffer: pb)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            encoder?.encode(pixelBuffer: pb, pts: pts, duration: duration)
        } else {
            trigger.process(sampleBuffer: sampleBuffer)
            let db = trigger.lastDb
            DispatchQueue.main.async { self.triggerLevelDb = db }
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
        DispatchQueue.main.async { self.droppedFrameCount += 1 }
    }
}
