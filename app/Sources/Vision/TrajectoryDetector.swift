// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Vision

/// Where in the frame the ball flew, according to Vision.
///
/// Deliberately *not* a measurement. `VNDetectTrajectoriesRequest` is very
/// good at "a small object flew along a parabola, here and between these
/// times" and gives us nothing about apparent ball size — and ball size is
/// half of the scale cross-check. So Vision is used as a locator: it says
/// where and when to look, our own detector measures what is there.
///
/// That keeps every reported number coming from the ported reference math
/// while still getting Vision's robustness against background clutter.
struct TrajectoryHint: Sendable {
    /// Detected points in image pixels, y-down.
    var pointsPx: [CGPoint]
    var startTime: Double
    var endTime: Double

    init(pointsPx: [CGPoint], startTime: Double, endTime: Double) {
        self.pointsPx = pointsPx
        self.startTime = startTime
        self.endTime = endTime
    }

}

/// Thin wrapper over `VNDetectTrajectoriesRequest`.
///
/// The request is stateful: it accumulates evidence across frames, so the
/// same instance must be fed every frame of the clip in order.
final class TrajectoryDetector {

    private let request: VNDetectTrajectoriesRequest
    private var best: VNTrajectoryObservation?
    /// The orientation the last frame was submitted with. Vision reports
    /// results in that oriented space, so `hint()` needs it to map them back.
    private var lastOrientation: CGImagePropertyOrientation = .up
    private let imageWidth: Int
    private let imageHeight: Int

    /// - Parameter trajectoryLength: how many points must line up on a
    ///   parabola before Vision reports it. 8 matches `minTrackFrames`.
    init(imageWidth: Int, imageHeight: Int, trajectoryLength: Int = SLA.minTrackFrames) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        // completionHandler is spelled out: the initializer is imported from
        // Objective-C without a default for it.
        request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: max(5, trajectoryLength),
                                              completionHandler: nil)
        // A softball at 4.5-6 m on a 1080-wide frame is roughly 1-3% of the
        // frame width. Keep the window generous — cage clips sit at the small
        // end and the tee at the large end.
        request.objectMinimumNormalizedRadius = 0.003
        request.objectMaximumNormalizedRadius = 0.06
    }

    /// Feed one frame. Safe to ignore per-frame failures; a clip only needs
    /// enough good frames to establish the parabola.
    /// - Parameter orientation: which way is up in the recorded frames.
    ///   Trajectory detection looks for a parabola, so a rotated frame has
    ///   gravity pointing sideways and the request finds nothing.
    ///
    ///   This only costs speed, never accuracy: the hint is a locator, and
    ///   `ClipAnalyzer` falls back to full-frame detection when it comes back
    ///   empty. Every reported number is measured by `BallDetector` on raw
    ///   buffer rows, which is orientation-independent.
    func process(sampleBuffer: CMSampleBuffer,
                 orientation: CGImagePropertyOrientation = .up) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer,
                                            orientation: orientation,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        // Kept for hint(): Vision returns points in the ORIENTED image, so
        // un-normalizing them needs the same orientation that went in.
        lastOrientation = orientation
        guard let results = request.results else { return }
        for obs in results {
            if let current = best {
                if obs.detectedPoints.count > current.detectedPoints.count {
                    best = obs
                }
            } else {
                best = obs
            }
        }
    }

    /// The most-supported trajectory seen across the clip, if any.
    func hint() -> TrajectoryHint? {
        guard let obs = best, obs.detectedPoints.count >= 3 else { return nil }
        // Vision's normalized coordinates are measured on the ORIENTED image,
        // origin bottom-left. Mapping them back onto the buffer therefore has
        // to undo the orientation as well as the y flip — assuming `.up` here
        // put the points in the wrong half of a sideways frame.
        let pts = obs.detectedPoints.map { p in
            VisionGeometry.imagePoint(fromVision: p.location,
                                      orientation: lastOrientation,
                                      width: imageWidth, height: imageHeight)
        }
        let range = obs.timeRange
        let start = range.start.isNumeric ? range.start.seconds : 0
        let end = range.end.isNumeric ? range.end.seconds : 0
        return TrajectoryHint(pointsPx: pts,
                              startTime: start,
                              endTime: max(end, start))
    }
}
