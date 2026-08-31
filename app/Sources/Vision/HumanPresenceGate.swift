// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import Vision

/// Answers one question cheaply: is there a person in frame right now?
///
/// The audio trigger fires on any sharp impulse — a dropped bat, a car door,
/// a fence rattle. In the field that produced a recorded "hit" with nobody in
/// frame, which is worse than a wasted clip: it pollutes the G1 trackability
/// statistic with clips that never contained a swing. So the trigger is gated
/// on human presence, the same way SwingVision and HomeCourt-class apps gate
/// their capture on on-device pose detection.
///
/// Implementation: `VNDetectHumanBodyPoseRequest` on the Neural Engine, fed a
/// frame roughly every 100 ms — nowhere near every 240fps frame, which would
/// be pointless and expensive. A single inference is ~10 ms on recent
/// hardware, so this stays well under 10% of one core. A detection counts
/// only when several joints are confident, which filters the occasional
/// phantom the raw request produces on busy backgrounds.
///
/// Since the pose request is being run anyway, the joints it finds are also
/// published — in capture-device coordinates, ready for
/// `layerPointConverted(fromCaptureDevicePoint:)` — so the setup screen can
/// draw the skeleton it is judging. That costs nothing: `recognizedPoints` was
/// already being called and its output thrown away.
///
/// The gate still makes no claim about whether the motion is a swing. Swing
/// classification, and the sagittal body metrics, are computed offline from the
/// recorded clip by `BodyAnalyzer` — for eliminating no-human false triggers,
/// presence is sufficient and far more robust.
final class HumanPresenceGate {

    /// Seconds a detection stays valid. The hitter crouches, shifts, and
    /// blurs during the swing itself — pose detection can momentarily lose
    /// them at exactly the moment the trigger fires, so presence is a window,
    /// not an instant.
    var presenceWindow: TimeInterval = 1.5

    /// Joints that must clear `jointConfidence` for a detection to count.
    var minimumJoints = 4
    var jointConfidence: Float = 0.3

    /// What a whole-person box has to clear, and how much of the frame it has
    /// to fill, for the fallback detector to count as a hitter.
    ///
    /// Emphatically NOT `jointConfidence`. Those are two different questions
    /// sharing one number, and using 0.3 — a sensible bar for "is this wrist
    /// reliable" — as the bar for "is this a person" is why the gate let a
    /// trigger through with nobody at the plate. `VNDetectHumanRectanglesRequest`
    /// returns low-confidence boxes readily, and it will return them for people
    /// on a screen, on a poster, or on the far side of a field.
    ///
    /// The size test does most of the work and needs no tuning: the hitter is
    /// the subject of the shot. Somebody a quarter of the frame tall is at the
    /// plate; somebody a twentieth of it tall is a passer-by, a spectator, or
    /// a picture of a person, and none of those are about to hit a ball.
    var personBoxConfidence: Float = 0.7
    var personBoxMinHeightFraction: CGFloat = 0.25

    /// Called on the main queue whenever detection flips.
    var onPresenceChange: ((Bool) -> Void)?

    /// Called on the main queue with the latest skeleton, in capture-device
    /// coordinates (normalized, top-left origin) — the space
    /// `AVCaptureVideoPreviewLayer` converts from. `nil` when nobody was found.
    ///
    /// Set to `nil` when nothing is drawing it: the conversion and the main-queue
    /// hop are pure cost otherwise.
    ///
    /// Written from the main thread when the setup overlay opens and closes,
    /// read on the gate's utility queue per submitted frame — so it goes
    /// through the lock like the rest of the cross-thread state.
    var onPose: (([PoseJoint: CGPoint]?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPose }
        set { lock.lock(); _onPose = newValue; lock.unlock() }
    }
    private var _onPose: (([PoseJoint: CGPoint]?) -> Void)?

    /// Seconds the gate may go without ever seeing anyone before the caller is
    /// told to stop trusting it. Pose detection can fail for reasons we cannot
    /// see from here — an unusual angle, heavy backlight, a hitter in dark
    /// clothing against a dark fence — and a gate that silently suppresses
    /// every trigger is worse than no gate at all.
    var neverSeenTimeout: TimeInterval = 20

    /// True when the gate has been running this long without a single
    /// detection, i.e. it is probably broken rather than correctly empty.
    func looksUnreliable(since start: CFTimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Seen SINCE the caller's start, not ever. One detection while framing
        // the shot used to satisfy this for the rest of the app's life, so a
        // gate that went blind for the whole armed round — backlight, dark
        // clothing, a wrong orientation override — suppressed every trigger
        // with the escape hatch never offered: the exact silent failure this
        // watchdog exists to catch.
        if let seen = _lastSeenAt, seen >= start { return false }
        return CACurrentMediaTime() - start > neverSeenTimeout
    }

    private let queue = DispatchQueue(label: "swinglab.posegate", qos: .utility)
    private let lock = NSLock()
    private var _lastSeenAt: CFTimeInterval?
    private var _detectedNow = false
    private var busy = false

    /// True when a person was seen within `presenceWindow`. Safe from any
    /// queue — the pipeline queue checks this at trigger time.
    var recentlyPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let seen = _lastSeenAt else { return false }
        return CACurrentMediaTime() - seen < presenceWindow
    }

    /// The latest raw detection result, for the UI chip.
    var detectedNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _detectedNow
    }

    /// Feed a frame. Returns immediately; drops the frame if an inference is
    /// already running, which at the submission rate simply means "checked a
    /// tenth of a second later".
    /// - Parameter orientation: which way is up in this buffer. The phone lives
    ///   sideways on a tripod, so this is never safely assumed: handed a
    ///   rotated or upside-down human, the pose model simply finds nobody —
    ///   and with the hitter gate on, that silently suppresses every trigger.
    func submit(pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation = .up) {
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            var detected = false
            var skeleton: [PoseJoint: CGPoint]?

            let pose = VNDetectHumanBodyPoseRequest()
            if (try? handler.perform([pose])) != nil,
               let observations = pose.results {
                for obs in observations {
                    guard let points = try? obs.recognizedPoints(.all) else { continue }
                    let confident = points.values.filter { $0.confidence >= self.jointConfidence }
                    if confident.count >= self.minimumJoints {
                        detected = true
                        if self.onPose != nil {
                            skeleton = Self.deviceSkeleton(from: points,
                                                           orientation: orientation,
                                                           minConfidence: self.jointConfidence)
                        }
                        break
                    }
                }
            }

            // Pose is the strict test; a plain person-shaped box is far more
            // robust to rotation, partial bodies and awkward stances. But it is
            // also far more willing to say yes, so it gets its own bar on both
            // confidence and size — see `personBoxConfidence`. Sharing
            // `jointConfidence` here is what let a trigger through with nobody
            // at the plate.
            if !detected {
                let rects = VNDetectHumanRectanglesRequest()
                if (try? handler.perform([rects])) != nil,
                   let found = rects.results {
                    detected = found.contains {
                        $0.confidence >= self.personBoxConfidence
                            && $0.boundingBox.height >= self.personBoxMinHeightFraction
                    }
                }
            }

            self.lock.lock()
            let changed = detected != self._detectedNow
            self._detectedNow = detected
            if detected { self._lastSeenAt = CACurrentMediaTime() }
            self.lock.unlock()

            if let handoff = self.onPose {
                DispatchQueue.main.async { handoff(skeleton) }
            }

            if changed {
                let value = detected
                DispatchQueue.main.async { self.onPresenceChange?(value) }
            }
        }
    }

    /// Apple's joint names -> ours, and Vision's normalized coordinates ->
    /// capture-device coordinates.
    ///
    /// Shared with the offline pass in `ClipAnalyzer` so the live skeleton and
    /// the recorded one can never disagree about which joint is which — the
    /// kind of divergence that shows up as a body metric that does not match
    /// the picture the user was looking at.
    static let jointMap: [VNHumanBodyPoseObservation.JointName: PoseJoint] = [
        .nose: .nose,
        .neck: .neck,
        .leftShoulder: .leftShoulder,
        .rightShoulder: .rightShoulder,
        .leftHip: .leftHip,
        .rightHip: .rightHip,
        .leftKnee: .leftKnee,
        .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle,
        .rightAnkle: .rightAnkle,
        // Drawn, never measured — see `PoseJoint`.
        .leftElbow: .leftElbow,
        .rightElbow: .rightElbow,
        .leftWrist: .leftWrist,
        .rightWrist: .rightWrist,
    ]

    static func deviceSkeleton(from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                               orientation: CGImagePropertyOrientation,
                               minConfidence: Float) -> [PoseJoint: CGPoint] {
        var out: [PoseJoint: CGPoint] = [:]
        for (name, joint) in jointMap {
            guard let p = points[name], p.confidence >= minConfidence else { continue }
            out[joint] = VisionGeometry.devicePoint(fromVision: p.location,
                                                    orientation: orientation)
        }
        return out
    }
}
