// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Vision

struct ClipAnalysis: Sendable {
    var metrics: SwingMetrics
    var track: [BallObservation]
    var bat: BatMetrics?
    /// Sagittal-plane body measurements, and the pose track they came from.
    /// Empty when body tracking was off or the hitter was never found.
    var body: BodyMetrics?
    var pose: [PoseObservation]
    var fps: Double
    var frameWidth: Int
    var frameHeight: Int
    var contactTime: Double
    /// True when Vision found the flight and narrowed the search; false when
    /// the analysis fell back to full-frame detection.
    var usedVisionHint: Bool
}

enum ClipAnalysisError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case noBallTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That clip has no video track."
        case .readerFailed(let why):
            return "Could not read the clip: \(why)"
        case .noBallTrack:
            return "No ball flight found in this clip. Check that the ball is optic yellow and in frame, or widen the colour range in Settings."
        }
    }
}

/// Runs the measurement pipeline over a recorded clip.
///
/// Two passes over the file:
///  1. Vision locates the flight (`TrajectoryDetector`).
///  2. `BallDetector` measures every frame, searching only the corridor
///     Vision pointed at — or the whole frame if Vision found nothing.
///
/// Everything reported comes from the ported reference math in `Core/`.
enum ClipAnalyzer {

    struct Options: Sendable {
        var detector = DetectorSettings()
        var bat = BatTracker.Settings()
        var trackBat = true
        /// Run the body-pose pass. Off makes analysis meaningfully faster on a
        /// hot phone, which is why it is a switch and not always-on.
        var trackBody = true
        /// How often to run pose over the clip, in Hz. Body motion is nowhere
        /// near 240fps content — a swing takes ~180 ms, so 30 Hz gives ~6
        /// samples across it and 60 Hz gives ~11, which is plenty for
        /// load-versus-contact displacements. Running it per frame would cost
        /// roughly eight times as much for no more information.
        var poseSampleHz: Double = 60
        var direction: TrackBuilder.Direction = .auto
        var rollDeg: Double = 0
        /// Camera pitch at capture time, positive when the lens aims **down**.
        /// Together with `fieldOfViewDeg` this lets `TiltRectifier` warp every
        /// observation into the view a level camera would have recorded, which
        /// is what makes a tripod that could not reach contact height — and so
        /// got aimed up at it — still measurable. Zero means no correction, so
        /// clips recorded before this existed analyse exactly as they did.
        var tiltDeg: Double = 0
        /// Horizontal field of view of the capture format, degrees. Needed to
        /// turn tilt into a focal length; without it, tilt cannot be undone.
        var fieldOfViewDeg: Double = 0
        /// Container frame rate is trusted for clips this app recorded. Set
        /// this for imported footage whose metadata lies (iPhone slo-mo often
        /// reports 30 fps with every 240 fps frame present).
        var fpsOverride: Double?
        /// How far either side of Vision's parabola a candidate may sit.
        var corridorPx: Double = 90
        /// Skip Vision and go straight to full-frame detection.
        var forceFallbackDetector = false
        /// Which way was up in the recorded frames. The phone films sideways on
        /// a tripod, so handing Vision `.up` shows it a rotated human and it
        /// finds nobody — the same failure that silently suppressed every audio
        /// trigger before the live path started deriving this.
        var visionOrientation: CGImagePropertyOrientation = .up
    }

    /// - Parameters:
    ///   - contactTime: seconds from clip start, from the audio trigger. When
    ///     `nil`, the first tracked point is treated as contact.
    ///   - progress: 0...1, called on an arbitrary thread.
    ///
    /// Does blocking I/O; call from a detached task.
    /// - Parameter diagnostics: filled in stage by stage when supplied. Owned by
    ///   the caller so it survives this throwing — a clip that produced nothing
    ///   is exactly the one worth a report.
    static func analyze(url: URL,
                        contactTime: Double?,
                        options: Options = Options(),
                        diagnostics: ClipDiagnostics? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClipAnalysis {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipAnalysisError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        let fps = options.fpsOverride ?? (nominalFPS > 1 ? Double(nominalFPS) : SLA.targetFPS)
        let duration = try await asset.load(.duration).seconds
        diagnostics?.fps = fps
        diagnostics?.width = width
        diagnostics?.height = height
        diagnostics?.durationS = duration
        diagnostics?.fpsWasOverridden = options.fpsOverride != nil

        // --- pass 1: Vision locates the flight ---
        var hint: TrajectoryHint?
        if !options.forceFallbackDetector {
            let detector = TrajectoryDetector(imageWidth: width, imageHeight: height)
            try forEachSampleBuffer(asset: asset, track: videoTrack) { sb, _, t in
                detector.process(sampleBuffer: sb)
                if duration > 0 { progress?(min(0.45, 0.45 * t / duration)) }
            }
            hint = detector.hint()
            diagnostics?.hintPoints = hint.map { $0.pointsPx.count }
        }

        // --- pass 2: measure ---
        let searchROI = hint?.roi(pad: options.corridorPx + 40, width: width, height: height)
        var perFrame: [Int: [BallObservation]] = [:]
        var tape: [BatTracker.TapeObservation] = []
        // The bat window is only known once contact is known. When the caller
        // did not supply one, fall back to Vision's flight start.
        let assumedContact = contactTime ?? hint?.startTime
        let batWindow: ClosedRange<Double>? = assumedContact.map {
            ($0 - options.bat.windowS)...($0 + 0.005)
        }

        // A handful of frames, spread through the clip, get their raw in-window
        // pixel count measured. Counting on every frame would double the cost
        // of a pass that already walks every pixel, and the question it answers
        // — does anything in this footage match the colour window at all —
        // needs samples, not a census.
        let probeStride = max(1, Int((duration * fps / 8).rounded()))

        try forEachSampleBuffer(asset: asset, track: videoTrack) { sb, index, t in
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            diagnostics?.framesDecoded += 1
            _ = PixelImage.withImage(pb) { img in
                if let diagnostics, index % probeStride == 0 {
                    diagnostics.probedFrames += 1
                    diagnostics.inWindowPixels.append(
                        BallDetector.countInWindow(image: img, settings: options.detector))
                }
                var cands = BallDetector.detect(image: img,
                                                frame: index,
                                                t: t,
                                                settings: options.detector,
                                                roi: searchROI)
                if let h = hint {
                    cands = cands.filter { h.admits(x: $0.x, y: $0.y, corridorPx: options.corridorPx) }
                }
                if !cands.isEmpty {
                    perFrame[index] = cands
                    diagnostics?.framesWithCandidates += 1
                    diagnostics?.totalCandidates += cands.count
                    diagnostics?.candidateDiametersPx.append(contentsOf: cands.map(\.diameterPx))
                }

                if options.trackBat, let w = batWindow, w.contains(t),
                   let p = BatTracker.detectTape(image: img, settings: options.bat) {
                    tape.append(BatTracker.TapeObservation(t: t, x: p.x, y: p.y))
                    diagnostics?.batTapeFrames += 1
                }
            }
            if duration > 0 { progress?(0.45 + min(0.5, 0.5 * t / duration)) }
        }

        // --- build the track ---
        var tracks = TrackBuilder.buildTracks(perFrame: perFrame, fps: fps)
        diagnostics?.tracksBuilt = tracks.count
        diagnostics?.bestTrackFrames = tracks.map(\.count).max() ?? 0
        var selected = TrackBuilder.selectOutboundTrack(tracks, direction: options.direction)

        // Vision saw a flight but the corridor filter starved the tracker:
        // retry unconstrained rather than reporting nothing.
        if selected == nil && hint != nil && !options.forceFallbackDetector {
            var retry = options
            retry.forceFallbackDetector = true
            return try await analyze(url: url, contactTime: contactTime,
                                     options: retry, diagnostics: diagnostics,
                                     progress: progress)
        }
        if selected == nil, !tracks.isEmpty {
            tracks.sort { $0.count > $1.count }
            selected = tracks.first
        }
        guard let track = selected, track.count >= 3 else {
            throw ClipAnalysisError.noBallTrack
        }

        let effectiveContact = contactTime ?? track[0].t

        // Undo camera tilt before anything is measured. The track handed back
        // to the caller stays in raw image coordinates — the debug overlay
        // draws on the original frames — but every number comes from the
        // rectified copy. The bat tape goes through the same warp, or the
        // contact-offset reading would compare a rectified ball against an
        // un-rectified barrel.
        let focalPx = TiltRectifier.focalPx(widthPx: Double(width),
                                            fovDeg: options.fieldOfViewDeg)
        let cx = Double(width) / 2, cy = Double(height) / 2
        let measured = TiltRectifier.rectify(track: track,
                                             tiltDeg: options.tiltDeg,
                                             focalPx: focalPx, cx: cx, cy: cy)
        let measuredTape: [BatTracker.TapeObservation]
        if options.tiltDeg != 0, focalPx > 0 {
            measuredTape = tape.map { o in
                let r = TiltRectifier.rectify(x: o.x, y: o.y,
                                              tiltDeg: options.tiltDeg,
                                              focalPx: focalPx, cx: cx, cy: cy)
                return BatTracker.TapeObservation(t: o.t, x: r.x, y: r.y)
            }
        } else {
            measuredTape = tape
        }

        let metrics = SwingAnalyzer.analyze(track: measured,
                                            contactTime: effectiveContact,
                                            rollDeg: options.rollDeg)
        let bat = options.trackBat ? BatTracker.analyze(observations: measuredTape,
                                                        contactTime: effectiveContact) : nil

        // --- pass 3: the hitter's body ---
        //
        // A third decode pass rather than folding pose into pass 2. Vision's
        // request handler wants the pixel buffer, `BallDetector` wants a locked
        // `PixelImage` of the same buffer, and pose runs at a fraction of the
        // frame rate — interleaving them would hold every frame hostage to the
        // slowest consumer for no gain, since this pass reads roughly one frame
        // in four.
        var pose: [PoseObservation] = []
        var body: BodyMetrics?
        if options.trackBody {
            pose = try detectPose(asset: asset, track: videoTrack,
                                  fps: fps, sampleHz: options.poseSampleHz,
                                  orientation: options.visionOrientation,
                                  width: width, height: height,
                                  tiltDeg: options.tiltDeg, focalPx: focalPx,
                                  cx: cx, cy: cy, diagnostics: diagnostics)
            body = BodyAnalyzer.analyze(track: pose,
                                        contactTime: effectiveContact,
                                        scaleMPerPx: metrics.scaleBallMPerPx,
                                        ballDirectionX: metrics.vxPxS)
        }
        diagnostics?.launchAngleDeg = metrics.launchAngleDeg
        diagnostics?.exitVeloMph = metrics.exitVeloMph
        diagnostics?.scaleMPerPx = metrics.scaleBallMPerPx
        diagnostics?.flags = metrics.flags.map(\.rawValue)
        progress?(1.0)

        return ClipAnalysis(metrics: metrics,
                            track: track,
                            bat: bat,
                            body: body,
                            pose: pose,
                            fps: fps,
                            frameWidth: width,
                            frameHeight: height,
                            contactTime: effectiveContact,
                            usedVisionHint: hint != nil)
    }

    /// Run body pose over the clip, sub-sampled.
    ///
    /// Coordinates come back in the same buffer pixels the ball and bat are
    /// measured in, and go through the same tilt rectification, so a body
    /// distance and a ball distance mean the same thing and a tilted camera is
    /// corrected for the hitter exactly as it is for the flight.
    private static func detectPose(asset: AVAsset,
                                   track: AVAssetTrack,
                                   fps: Double,
                                   sampleHz: Double,
                                   orientation: CGImagePropertyOrientation,
                                   width: Int, height: Int,
                                   tiltDeg: Double, focalPx: Double,
                                   cx: Double, cy: Double,
                                   diagnostics: ClipDiagnostics? = nil) throws -> [PoseObservation] {
        let frameStride = max(1, Int((fps / max(1, sampleHz)).rounded()))
        var out: [PoseObservation] = []
        // One request object reused across frames: allocating a fresh
        // VNDetectHumanBodyPoseRequest per frame is a measurable share of the
        // cost at these rates.
        let request = VNDetectHumanBodyPoseRequest()

        try forEachSampleBuffer(asset: asset, track: track) { sb, index, t in
            guard index % frameStride == 0,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            diagnostics?.poseFramesSampled += 1
            let handler = VNImageRequestHandler(cvPixelBuffer: pb,
                                                orientation: orientation,
                                                options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observations = request.results, !observations.isEmpty else { return }

            // The largest skeleton, by the spread of its confident joints.
            // A coach, an on-deck hitter or a passer-by is farther from the
            // camera and therefore smaller; picking the biggest is the cheap
            // version of "the one we are filming", and it agrees with the
            // framing guide, which puts the hitter close and alone.
            var best: [PoseJoint: PosePoint]?
            var bestSpan = -1.0
            for obs in observations {
                guard let points = try? obs.recognizedPoints(.all) else { continue }
                var joints: [PoseJoint: PosePoint] = [:]
                for (name, joint) in HumanPresenceGate.jointMap {
                    guard let p = points[name],
                          Double(p.confidence) >= SLA.jointConfidenceMin else { continue }
                    let px = VisionGeometry.imagePoint(fromVision: p.location,
                                                       orientation: orientation,
                                                       width: width, height: height)
                    let r = TiltRectifier.rectify(x: Double(px.x), y: Double(px.y),
                                                  tiltDeg: tiltDeg, focalPx: focalPx,
                                                  cx: cx, cy: cy)
                    joints[joint] = PosePoint(x: r.x, y: r.y,
                                              confidence: Double(p.confidence))
                }
                guard joints.count >= 4 else { continue }
                let ys = joints.values.map(\.y)
                let span = (ys.max() ?? 0) - (ys.min() ?? 0)
                if span > bestSpan {
                    bestSpan = span
                    best = joints
                }
            }
            if let best {
                out.append(PoseObservation(frame: index, t: t, joints: best))
                diagnostics?.poseFramesWithPerson += 1
                for (joint, p) in best { diagnostics?.noteJoint(joint, confidence: p.confidence) }
            }
        }
        return out
    }

    /// Decode every frame once, handing back (sampleBuffer, frameIndex,
    /// presentationSeconds). Frame time comes from the PTS rather than
    /// `index / fps`, so a dropped frame does not shift everything after it.
    private static func forEachSampleBuffer(asset: AVAsset,
                                            track: AVAssetTrack,
                                            _ body: (CMSampleBuffer, Int, Double) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ClipAnalysisError.readerFailed("cannot attach BGRA output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipAnalysisError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        defer { reader.cancelReading() }

        var index = 0
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let t = pts.isNumeric ? pts.seconds : 0
            try body(sb, index, t)
            index += 1
        }
        if reader.status == .failed {
            throw ClipAnalysisError.readerFailed(reader.error?.localizedDescription ?? "read failed")
        }
    }
}
