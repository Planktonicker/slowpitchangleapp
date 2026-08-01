import AVFoundation
import CoreMedia
import Foundation
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
}

/// Thin wrapper over `VNDetectTrajectoriesRequest`.
///
/// The request is stateful: it accumulates evidence across frames, so the
/// same instance must be fed every frame of the clip in order.
final class TrajectoryDetector {

    private let request: VNDetectTrajectoriesRequest
    private var best: VNTrajectoryObservation?
    private let imageWidth: Int
    private let imageHeight: Int

    /// - Parameter trajectoryLength: how many points must line up on a
    ///   parabola before Vision reports it. 8 matches `minTrackFrames`.
    init(imageWidth: Int, imageHeight: Int, trajectoryLength: Int = SLA.minTrackFrames) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: max(5, trajectoryLength))
        // A softball at 15-20 ft on a 1080-wide frame is roughly 1-3% of the
        // frame width. Keep the window generous — cage clips sit at the small
        // end and the tee at the large end.
        request.objectMinimumNormalizedRadius = 0.003
        request.objectMaximumNormalizedRadius = 0.06
    }

    /// Feed one frame. Safe to ignore per-frame failures; a clip only needs
    /// enough good frames to establish the parabola.
    func process(sampleBuffer: CMSampleBuffer) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
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
        // Vision's normalized coordinates put the origin bottom-left; image
        // space is y-down.
        let pts = obs.detectedPoints.map { p in
            CGPoint(x: p.x * CGFloat(imageWidth),
                    y: (1 - p.y) * CGFloat(imageHeight))
        }
        let range = obs.timeRange
        let start = range.start.isNumeric ? range.start.seconds : 0
        let end = range.end.isNumeric ? range.end.seconds : 0
        return TrajectoryHint(pointsPx: pts,
                              startTime: start,
                              endTime: max(end, start))
    }
}
