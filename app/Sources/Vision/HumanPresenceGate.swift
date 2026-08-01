// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreVideo
import Foundation
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
/// This gate is presence-only by design. Swing *classification* (is that
/// motion actually a swing?) belongs to Phase 3 alongside bat tracking; for
/// eliminating no-human false triggers, presence is sufficient and far more
/// robust.
final class HumanPresenceGate {

    /// Seconds a detection stays valid. The hitter crouches, shifts, and
    /// blurs during the swing itself — pose detection can momentarily lose
    /// them at exactly the moment the trigger fires, so presence is a window,
    /// not an instant.
    var presenceWindow: TimeInterval = 1.5

    /// Joints that must clear `jointConfidence` for a detection to count.
    var minimumJoints = 4
    var jointConfidence: Float = 0.3

    /// Called on the main queue whenever detection flips.
    var onPresenceChange: ((Bool) -> Void)?

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
    func submit(pixelBuffer: CVPixelBuffer) {
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

            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .up,
                                                options: [:])
            var detected = false
            if (try? handler.perform([request])) != nil,
               let observations = request.results {
                for obs in observations {
                    guard let points = try? obs.recognizedPoints(.all) else { continue }
                    let confident = points.values.filter { $0.confidence >= self.jointConfidence }
                    if confident.count >= self.minimumJoints {
                        detected = true
                        break
                    }
                }
            }

            self.lock.lock()
            let changed = detected != self._detectedNow
            self._detectedNow = detected
            if detected { self._lastSeenAt = CACurrentMediaTime() }
            self.lock.unlock()

            if changed {
                let value = detected
                DispatchQueue.main.async { self.onPresenceChange?(value) }
            }
        }
    }
}
