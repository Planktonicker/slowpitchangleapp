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

    /// Vertical corridor around the path, fitted from the hint points.
    private var fit: (a: Double, b: Double, c: Double)?

    init(pointsPx: [CGPoint], startTime: Double, endTime: Double) {
        self.pointsPx = pointsPx
        self.startTime = startTime
        self.endTime = endTime
        if pointsPx.count >= 3 {
            let f = Geometry.fitQuadratic(ts: pointsPx.map { Double($0.x) },
                                          vs: pointsPx.map { Double($0.y) })
            self.fit = (f.a, f.b, f.c)
        } else {
            self.fit = nil
        }
    }

    /// True when a candidate at (x, y) is plausibly on this trajectory.
    func admits(x: Double, y: Double, corridorPx: Double) -> Bool {
        if let f = fit {
            let yHat = f.a * x * x + f.b * x + f.c
            if abs(y - yHat) <= corridorPx { return true }
        }
        for p in pointsPx {
            let dx = x - Double(p.x), dy = y - Double(p.y)
            if (dx * dx + dy * dy).squareRoot() <= corridorPx { return true }
        }
        return false
    }

    /// Bounding box of the hint, expanded by `pad`, for ROI-limited search.
    /// The bounding box of the points Vision actually reported, padded.
    ///
    /// Kept for the no-fit case and for tests. On its own it is NOT the region
    /// worth searching — see `searchROI`.
    func roi(pad: Double, width: Int, height: Int) -> ROI? {
        guard !pointsPx.isEmpty else { return nil }
        let xs = pointsPx.map { Double($0.x) }
        let ys = pointsPx.map { Double($0.y) }
        return ROI(x0: Int((xs.min() ?? 0) - pad),
                   y0: Int((ys.min() ?? 0) - pad),
                   x1: Int((xs.max() ?? 0) + pad) + 1,
                   y1: Int((ys.max() ?? 0) + pad) + 1)
            .clamped(width: width, height: height)
    }

    /// Where the ball could be, which is not the same as where Vision saw it.
    ///
    /// `admits` extrapolates: it fits a parabola to the hint points and accepts
    /// a candidate within the corridor of that curve at ANY x, including far
    /// past the last point Vision reported. The search region did not
    /// extrapolate — it was the hint's own bounding box plus a little padding.
    /// So the two disagreed about where the ball might be, and the tighter one
    /// won in silence: the detector never looked at pixels the corridor would
    /// have accepted, and a ball that flew on past Vision's last point simply
    /// did not exist.
    ///
    /// That is not a rare corner. `VNDetectTrajectoriesRequest` reports the
    /// segment it is confident about, which on a real swing is often the few
    /// frames around the fastest, cleanest part of the flight — one clip gave
    /// eight points. Everything before and after was cropped away before a
    /// single pixel was examined, and the resulting short track looked like a
    /// detector that could not see a ball in plain view.
    ///
    /// Now the region follows the fitted curve across the frame, so the search
    /// and the admission test agree. Clutter rejection does not suffer: it was
    /// never the ROI doing that job, it was the corridor, and the corridor is
    /// unchanged.
    func searchROI(corridorPx: Double, width: Int, height: Int) -> ROI? {
        guard !pointsPx.isEmpty else { return nil }
        let pad = corridorPx + 40
        var minX = pointsPx.map { Double($0.x) }.min() ?? 0
        var maxX = pointsPx.map { Double($0.x) }.max() ?? 0
        var minY = pointsPx.map { Double($0.y) }.min() ?? 0
        var maxY = pointsPx.map { Double($0.y) }.max() ?? 0

        if let f = fit, width > 1 {
            // Walk the curve across the frame and keep the stretch of it that
            // is actually on screen. A steep parabola leaves the picture almost
            // at once and contributes almost nothing; a shallow one reaches the
            // far edge and the region grows to match, which is the correct
            // answer rather than an expensive one.
            let step = max(1.0, Double(width) / 240)
            var x = 0.0
            while x <= Double(width) {
                let yHat = f.a * x * x + f.b * x + f.c
                if yHat >= -corridorPx, yHat <= Double(height) + corridorPx {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, yHat); maxY = max(maxY, yHat)
                }
                x += step
            }
        }

        return ROI(x0: Int(minX - pad), y0: Int(minY - pad),
                   x1: Int(maxX + pad) + 1, y1: Int(maxY + pad) + 1)
            .clamped(width: width, height: height)
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
        // put the corridor in the wrong half of a sideways frame, which reads
        // downstream as a hint that admits nothing.
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
