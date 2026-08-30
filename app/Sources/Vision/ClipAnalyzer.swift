// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import QuartzCore
import Vision

struct ClipAnalysis: Sendable {
    var metrics: SwingMetrics
    var track: [BallObservation]
    var bat: BatMetrics?
    /// The barrel-tape path in RAW buffer pixels, for drawing.
    ///
    /// Deliberately not `bat.pathPx`. That one is tilt-rectified, because every
    /// number is taken from the rectified copy; this one is not, because the
    /// overlay is drawn on the original frames. Drawing the rectified path over
    /// raw video puts the bat visibly beside the bat on any clip filmed off
    /// level — which reads as a broken tracker when the tracker was right.
    var tapePathPx: [CGPoint] = []
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
    /// What the detector saw on the way to that track, so a failure can be
    /// looked at rather than guessed about. See `DetectionTrace`.
    var trace = DetectionTrace()
}

/// `Equatable` so callers can react to a specific failure — a hand-picked ball
/// that found nothing is a different situation from a clip that would not
/// decode, and they want different words.
enum ClipAnalysisError: LocalizedError, Equatable {
    case noVideoTrack
    case readerFailed(String)
    case noBallTrack
    /// A ball was picked by hand and nothing was detected there.
    case noBallAtSeed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That clip has no video track."
        case .readerFailed(let why):
            return "Could not read the clip: \(why)"
        case .noBallAtSeed:
            return "No ball was detected where you tapped. That is a DETECTION problem, not a tracking one — the colour or size gates are excluding it there. Try a frame where the ball is against the sky or the trees rather than the grass, or widen the ball colour range in Settings."
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
        /// Force a frame rate, bypassing both the measurement and the
        /// container metadata.
        ///
        /// Almost never needed now that the rate is measured from the clip's
        /// own sample timing (`measureFrameTiming`), which handles 198.94 fps
        /// footage as happily as a round 240 and does not care what the
        /// container claims. Kept as an escape hatch for footage whose timing
        /// is itself wrong — a re-wrapped or re-timed file — where there is no
        /// signal left to measure and the user simply knows the answer.
        var fpsOverride: Double?
        /// A point the user tapped on the ball, in buffer pixels and clip
        /// time. When set, the track is followed out from HERE and automatic
        /// selection is skipped entirely.
        ///
        /// This is the escape hatch that makes a cluttered clip measurable at
        /// all. Choosing which of several hundred tracks is the ball is a
        /// heuristic on footage like a phone lying in grass; a tap is a
        /// measurement of the one thing the pipeline cannot infer.
        var ballSeed: (t: Double, x: Double, y: Double)?

        /// Skip the Vision trajectory pass entirely. Detection is full-frame
        /// either way — the hint stopped constraining the search after it
        /// twice steered onto the wrong object — so all this saves now is the
        /// cost of the pass itself and its contact-time fallback.
        var forceFallbackDetector = false
        /// Rescale the detector's radius gates from the 1080p they are written
        /// for to whatever this clip actually is.
        ///
        /// Only for imported footage. Live capture is always the format the app
        /// chose, and quietly moving a number the parity fixtures pin would be
        /// a different kind of mistake from the one this avoids.
        var scaleDetectorRadiiToFrameWidth = false
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
        let startedAt = CFAbsoluteTimeGetCurrent()
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipAnalysisError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        // Measured first, container second. See `measureFrameTiming`: the
        // header is a claim, the sample timing is the footage. This is what
        // lets 198.94 fps footage — an ordinary iPhone slow-motion rate —
        // analyse correctly without anybody choosing a number from a list.
        let timing = try? measureFrameTiming(asset: asset, track: videoTrack)
        let fps = options.fpsOverride
            ?? timing?.fps
            ?? (nominalFPS > 1 ? Double(nominalFPS) : SLA.targetFPS)
        let duration = try await asset.load(.duration).seconds
        diagnostics?.fps = fps
        diagnostics?.width = width
        diagnostics?.height = height
        diagnostics?.durationS = duration
        diagnostics?.fpsSource = options.fpsOverride != nil ? .override
            : (timing != nil ? .measured : .container)
        diagnostics?.containerFps = nominalFPS > 1 ? Double(nominalFPS) : nil
        diagnostics?.frameIntervalIrregularFraction = timing?.irregularFraction

        var options = options
        if options.scaleDetectorRadiiToFrameWidth, width > 0,
           width != SLA.targetWidth {
            let k = Double(width) / Double(SLA.targetWidth)
            options.detector.minRadiusPx *= k
            options.detector.maxRadiusPx *= k
            diagnostics?.radiusScale = k
        }

        // --- pass 1: Vision locates the flight ---
        var hint: TrajectoryHint?
        if !options.forceFallbackDetector {
            let detector = TrajectoryDetector(imageWidth: width, imageHeight: height)
            try forEachSampleBuffer(asset: asset, track: videoTrack) { sb, _, t in
                detector.process(sampleBuffer: sb)
                if duration > 0 { progress?(min(0.35, 0.35 * t / duration)) }
            }
            hint = detector.hint()
            diagnostics?.hintPoints = hint.map { $0.pointsPx.count }
            diagnostics?.hintSpanPx = hint.map {
                let xs = $0.pointsPx.map { Double($0.x) }
                return (xs.max() ?? 0) - (xs.min() ?? 0)
            }
        }

        // --- pass 2: measure ---
        // The whole frame, every frame — same as the reference. Vision's hint
        // used to constrain this, first as a box around its points, then as a
        // corridor along their fitted curve, and both steered the search off
        // the ball. The failure is structural, not a tuning miss:
        // VNDetectTrajectoriesRequest rewards a long clean parabola, and in
        // slow-pitch the long clean parabola is the PITCH. The hit is several
        // times faster and gone in a fraction of a second — exactly what that
        // detector is worst at — so on a real swing clip the hint converges on
        // the wrong ball and every constraint built on it excludes the right
        // one. The hint survives only as a contact-time fallback and a
        // diagnostics line; `sla_common.py` never had a corridor, and now
        // neither does this.
        let searchROI: ROI? = nil
        var perFrame: [Int: [BallObservation]] = [:]
        var tape: [BatTracker.TapeObservation] = []
        var trace = DetectionTrace(searchedX0: searchROI?.x0, searchedY0: searchROI?.y0,
                                   searchedX1: searchROI?.x1, searchedY1: searchROI?.y1)
        // Previous frame's luma, for the motion gate. Held across the walk:
        // the gate is the difference between ~130 candidates a frame on grassy
        // footage and a handful. See `MotionMask`.
        var previousLuma: MotionMask.Luma?
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
                let luma = MotionMask.Luma(pixels: img.lumaPlane(),
                                           width: img.width, height: img.height)
                let motion = MotionMask.mask(current: luma, previous: previousLuma)
                previousLuma = luma
                if let diagnostics, index % probeStride == 0 {
                    diagnostics.probedFrames += 1
                    diagnostics.inWindowPixels.append(
                        BallDetector.countInWindow(image: img, settings: options.detector))
                }
                // No previous frame means no gate, and an ungated frame on
                // grassy footage yields ~130 ball-coloured blobs of scenery.
                // Nothing survives track building from a single frame, but it
                // would fill the diagnostics report with junk and hide the
                // real story. One frame at 240fps costs nothing.
                let cands: [BallObservation] = motion == nil
                    ? []
                    : BallDetector.detect(image: img,
                                          frame: index,
                                          t: t,
                                          settings: options.detector,
                                          roi: searchROI,
                                          motion: motion)
                // Kept before track building, so the review can show a
                // candidate the detector genuinely found and the pipeline then
                // discarded — without this they would be indistinguishable
                // from pixels where nothing was found.
                if trace.candidates.count < DetectionTrace.candidateLimit {
                    trace.candidates.append(contentsOf: cands.prefix(DetectionTrace.perFrameLimit))
                } else if !trace.truncated {
                    trace.truncated = true
                    trace.truncatedAtT = trace.candidates.last?.t
                }
                if !cands.isEmpty {
                    perFrame[index] = cands
                    diagnostics?.framesWithCandidates += 1
                    diagnostics?.totalCandidates += cands.count
                    diagnostics?.candidateDiametersPx.append(contentsOf: cands.map(\.diameterPx))
                }

                if options.trackBat, let w = batWindow, w.contains(t), motion != nil,
                   let p = BatTracker.detectTape(image: img, settings: options.bat,
                                                 motion: motion) {
                    tape.append(BatTracker.TapeObservation(t: t, x: p.x, y: p.y))
                    diagnostics?.batTapeFrames += 1
                }
            }
            if duration > 0 { progress?(0.35 + min(0.45, 0.45 * t / duration)) }
        }

        // --- build the track ---
        // Stitched immediately: detection gaps fragment a real flight into
        // bursts shorter than the length gate, and selection has to see the
        // rejoined chains, not the pieces. See `TrackBuilder.stitchTracks`.
        let fragments = TrackBuilder.buildTracks(perFrame: perFrame, fps: fps)
        var tracks = TrackBuilder.stitchTracks(fragments)
        diagnostics?.tracksBuilt = tracks.count
        diagnostics?.bestTrackFrames = tracks.map(\.count).max() ?? 0
        var selected = TrackBuilder.selectOutboundTrack(tracks, direction: options.direction)

        // Last resort, when the requested direction matched nothing. This used
        // to take the LONGEST track, which on a swing clip is reliably the
        // worst possible answer: the longest thing in the footage is either an
        // inbound pitch hanging in frame for two seconds or a patch of grass
        // being re-detected, never the hit. Falling back to the same scoring
        // with the direction constraint dropped keeps the "fastest coherent
        // track" rule and gives up only the thing that actually failed.
        if selected == nil, !tracks.isEmpty {
            selected = TrackBuilder.selectOutboundTrack(tracks, direction: .auto)
        }
        if selected == nil, !tracks.isEmpty {
            tracks.sort { $0.count > $1.count }
            selected = tracks.first
        }
        // A tap overrides every heuristic: follow the ball out from where the
        // user pointed, and do not let scoring second-guess them.
        if let seed = options.ballSeed {
            let seeded = TrackBuilder.trackFromSeed(perFrame: perFrame, fps: fps,
                                                    t: seed.t, x: seed.x, y: seed.y,
                                                    frameWidthPx: Double(width))
            if let seeded, seeded.count >= 3 {
                selected = seeded
                tracks = [seeded] + tracks
                trace.usedBallSeed = true
                diagnostics?.usedBallSeed = true
            } else {
                // Nothing detected near the tap. Do NOT quietly fall back to
                // the automatic pick: the user tapped precisely BECAUSE that
                // pick was wrong, and handing it back with a fresh timestamp
                // is the pipeline overruling the one input it cannot infer.
                // Failing says the true thing — the ball was not DETECTED
                // there, which is a colour or size problem, not a selection
                // one, and wants a different fix.
                trace.ballSeedFoundNothing = true
                diagnostics?.ballSeedFoundNothing = true
                trace.tracksBuilt = tracks.count
                trace.trackSummaries = Self.summarise(tracks: tracks, selected: nil,
                                                      direction: options.direction)
                throw ClipAnalysisError.noBallAtSeed
            }
        }

        // Record what the builder produced and why the losers lost, BEFORE
        // everything but the winner is thrown away. This is the only place
        // that knowledge exists.
        trace.tracksBuilt = tracks.count
        trace.trackSummaries = Self.summarise(tracks: tracks, selected: selected,
                                              direction: options.direction)
        trace.stitchExplains = Self.explainUnjoined(chains: tracks)

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
        // The bat is tracked automatically and reported only when a bat was
        // actually there. Nothing asks the user whether they taped the barrel:
        // if the tape is on, its path is measured; if it is not, no attack
        // angle, no bat speed and no smash factor appear at all.
        //
        // Presence is decided on SPEED, because the failure that matters is a
        // stationary pink object — a jersey, a glove in the grass — standing in
        // for a barrel and producing a confident-looking attack angle for a bat
        // that was never taped. A barrel through contact moves; a cooler lid
        // does not. Below the floor the reading is withheld rather than
        // flagged, because it is not a poorly measured bat, it is not a bat.
        var bat: BatMetrics?
        if options.trackBat,
           let candidate = BatTracker.analyze(observations: measuredTape,
                                              contactTime: effectiveContact) {
            let speedMps = SLA.batSpeedMps(vxPxS: candidate.vxPxS,
                                           vyPxS: candidate.vyPxS,
                                           scaleMPerPx: metrics.scaleBallMPerPx)
            if speedMps >= options.bat.minBarrelSpeedMps {
                bat = candidate
            } else {
                diagnostics?.batRejectedReason = String(
                    format: "tape path moved at %.1f m/s, under the %.0f m/s floor — "
                          + "not a swinging bat", speedMps, options.bat.minBarrelSpeedMps)
            }
        }

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
                                  cx: cx, cy: cy, diagnostics: diagnostics,
                                  duration: duration, progress: progress)
            body = BodyAnalyzer.analyze(track: pose,
                                        contactTime: effectiveContact,
                                        scaleMPerPx: metrics.scaleBallMPerPx,
                                        ballDirectionX: metrics.vxPxS)
        }
        diagnostics?.launchAngleDeg = metrics.launchAngleDeg
        diagnostics?.exitVeloMph = metrics.exitVeloMph
        diagnostics?.scaleMPerPx = metrics.scaleBallMPerPx
        diagnostics?.flags = metrics.flags.map(\.rawValue)
        diagnostics?.elapsedS = CFAbsoluteTimeGetCurrent() - startedAt
        progress?(1.0)

        return ClipAnalysis(metrics: metrics,
                            track: track,
                            bat: bat,
                            tapePathPx: bat == nil
                                ? [] : tape.map { CGPoint(x: $0.x, y: $0.y) },
                            body: body,
                            pose: pose,
                            fps: fps,
                            frameWidth: width,
                            frameHeight: height,
                            contactTime: effectiveContact,
                            usedVisionHint: hint != nil,
                            trace: trace)
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
                                   diagnostics: ClipDiagnostics? = nil,
                                   duration: Double = 0,
                                   progress: (@Sendable (Double) -> Void)? = nil) throws -> [PoseObservation] {
        let frameStride = max(1, Int((fps / max(1, sampleHz)).rounded()))
        var out: [PoseObservation] = []
        // One request object reused across frames: allocating a fresh
        // VNDetectHumanBodyPoseRequest per frame is a measurable share of the
        // cost at these rates.
        let request = VNDetectHumanBodyPoseRequest()

        try forEachSampleBuffer(asset: asset, track: track) { sb, index, t in
            // Reported from inside the pass, not around it. This is the third
            // walk over the file and it used to sit silently at 95% for its
            // whole duration, which reads as the app having hung.
            if duration > 0 { progress?(0.80 + min(0.19, 0.19 * t / duration)) }
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
    /// Why the fastest chains did not join each other, in the stitch gates'
    /// own numbers. Diagnostic only — the decisions were already made by
    /// `TrackBuilder.stitchError`; this re-walks the same gates (same shared
    /// constants) to NAME the one that refused.
    static func explainUnjoined(chains: [[BallObservation]]) -> [String] {
        // The fast few are the ones worth explaining; clutter not joining
        // clutter is not news.
        let fast = chains.compactMap { tr -> (speed: Double, tr: [BallObservation])? in
            guard let f = tr.first, let l = tr.last, l.t > f.t else { return nil }
            let s = ((l.x - f.x) * (l.x - f.x) + (l.y - f.y) * (l.y - f.y)).squareRoot() / (l.t - f.t)
            return s >= 800 ? (s, tr) : nil
        }.sorted { $0.speed > $1.speed }.prefix(6).map(\.tr)

        var out: [String] = []
        for a in fast {
            for b in fast {
                guard let aLast = a.last, let bFirst = b.first, let aFirst = a.first,
                      bFirst.t > aLast.t, bFirst.t - aLast.t < 0.4 else { continue }
                let gap = bFirst.t - aLast.t
                let head = String(format: "%.2f–%.2fs → %.2fs  gap %.0fms: ",
                                  aFirst.t, aLast.t, bFirst.t, gap * 1000)
                out.append(head + Self.stitchRefusal(a, b, gap: gap))
                if out.count >= 8 { return out }
            }
        }
        return out
    }

    private static func stitchRefusal(_ a: [BallObservation], _ b: [BallObservation],
                                      gap: Double) -> String {
        if gap > SLA.stitchMaxGapS {
            return String(format: "gap over the %.0fms stitch limit", SLA.stitchMaxGapS * 1000)
        }
        guard let aLast = a.last, let bFirst = b.first else { return "empty track" }
        let va = TrackBuilder.endVelocityForDiagnostics(a)
        let vb = TrackBuilder.startVelocityForDiagnostics(b)
        let speedA = (va.vx * va.vx + va.vy * va.vy).squareRoot()
        let speedB = (vb.vx * vb.vx + vb.vy * vb.vy).squareRoot()
        guard speedA > 1e-9, speedB > 1e-9 else { return "an endpoint has no measurable velocity" }
        let diameters = (a.map(\.diameterPx) + b.map(\.diameterPx)).sorted()
        let medianD = diameters[diameters.count / 2]
        guard medianD > 1e-9 else { return "no measurable ball size" }
        let gPx = SLA.g * medianD / SLA.ballDiameterM

        let jx = vb.vx - va.vx, jy = vb.vy - va.vy
        let jump = (jx * jx + jy * jy).squareRoot()
        let jumpLimit = SLA.stitchAccelK * gPx * gap + SLA.stitchVelocityNoisePxS
        if jump > jumpLimit {
            return String(format: "velocity jumps %.0f px/s — gravity allows %.0f",
                          jump, jumpLimit)
        }
        let hopX = bFirst.x - aLast.x, hopY = bFirst.y - aLast.y
        let hop = (hopX * hopX + hopY * hopY).squareRoot()
        if hop > 4.0 {
            let coshop = (va.vx * hopX + va.vy * hopY) / (speedA * hop)
            let hopAngle = acos(max(-1, min(1, coshop))) * 180 / .pi
            if hopAngle > SLA.stitchMaxAngleDeg {
                return String(format: "the two sit %.0f° apart, not along the flight",
                              hopAngle)
            }
        }
        let predX = aLast.x + va.vx * gap
        let predY = aLast.y + va.vy * gap + 0.5 * gPx * gap * gap
        let tol = SLA.stitchBaseTolPx + SLA.stitchTolPxPerS * speedA * gap
        let dx = bFirst.x - predX, dy = bFirst.y - predY
        let err = (dx * dx + dy * dy).squareRoot()
        if err > tol {
            return String(format: "lands %.0fpx from the prediction (tolerance %.0f)", err, tol)
        }
        // Should be impossible after stitching ran — and therefore the most
        // important line this can ever print.
        return String(format: "JOINABLE at %.0fpx — yet not joined; report this", err)
    }

    /// Summarise every candidate track, worst-case truncated, with the
    /// selector's own reason for passing each one over.
    static func summarise(tracks: [[BallObservation]],
                          selected: [BallObservation]?,
                          direction: TrackBuilder.Direction) -> [DetectionTrace.TrackSummary] {
        var out: [DetectionTrace.TrackSummary] = []
        for tr in tracks {
            guard let first = tr.first, let last = tr.last else { continue }
            let dt = last.t - first.t
            let dx = last.x - first.x, dy = last.y - first.y
            let speed = dt > 0 ? (dx * dx + dy * dy).squareRoot() / dt : 0
            let straight = TrackBuilder.straightness(tr)
            let isSelected = selected.map { $0.first?.frame == first.frame
                && $0.last?.frame == last.frame && $0.count == tr.count } ?? false

            // The selector's gates, in the order it applies them.
            var reason = ""
            if !isSelected {
                if tr.count < SLA.minTrackFrames {
                    reason = "only \(tr.count) frames, needs \(SLA.minTrackFrames)"
                } else if dt <= 0 {
                    reason = "no elapsed time"
                } else if straight < SLA.trackStraightnessMin {
                    reason = String(format: "wanders — straightness %.2f, needs %.2f",
                                    straight, SLA.trackStraightnessMin)
                } else if direction != .auto,
                          (dx > 0) != (direction == .right) {
                    reason = "travels the wrong way for a hit"
                } else {
                    reason = "slower than the chosen track"
                }
            }

            let stride = max(1, tr.count / DetectionTrace.trackPointLimit)
            let pts = stride == 1 ? tr : tr.enumerated().compactMap {
                $0.offset % stride == 0 ? $0.element : nil
            }
            out.append(.init(frames: tr.count, startT: first.t, endT: last.t,
                             speedPxS: speed, straightness: straight,
                             selected: isSelected, rejectedBecause: reason,
                             points: pts.map { .init(x: $0.x, y: $0.y) }))
        }
        // Fastest first, but never drop the winner.
        out.sort { $0.selected != $1.selected ? $0.selected
                                              : $0.speedPxS > $1.speedPxS }
        return Array(out.prefix(DetectionTrace.trackSummaryLimit))
    }

    // MARK: - Frame rate

    /// What the clip's own sample timing says its frame rate is.
    struct FrameTiming: Sendable {
        var fps: Double
        /// How many intervals the answer is based on.
        var intervals: Int
        /// Fraction of intervals more than 20% away from the median.
        ///
        /// Everything downstream — exit velocity above all — assumes frames
        /// arrive at a constant interval. Variable-rate footage breaks that
        /// assumption silently, producing a number that looks ordinary and is
        /// wrong, so it is measured rather than hoped for.
        var irregularFraction: Double
    }

    /// Measure the frame rate from the clip itself, rather than believing the
    /// container.
    ///
    /// `nominalFrameRate` is metadata: a field somebody wrote, not a fact
    /// derived from the samples. iPhone slow motion is the case that matters
    /// here — a 240 fps original carrying a slow-motion edit reports 30 — but
    /// it is wrong in quieter ways too, rounding 198.94 to 199 or to 200, and
    /// exit velocity scales *directly* with frame rate, so a 20% error in this
    /// number is a 20% error in every mile per hour the app reports.
    ///
    /// The samples cannot lie in the same way: whatever the header says, the
    /// presentation timestamps are what the frames actually are. This reads
    /// them **without decoding** — `outputSettings: nil` hands back the
    /// compressed samples — so it costs a fraction of a second even on a
    /// gigabyte of 240 fps footage, and it needs no setting, no preset list
    /// and no guess about which phone recorded it.
    ///
    /// The median, not the mean: one dropped frame doubles a single interval,
    /// and a mean would quietly drag the rate down with it while a median does
    /// not notice.
    static func measureFrameTiming(asset: AVAsset,
                                   track: AVAssetTrack,
                                   sampleLimit: Int = 300) throws -> FrameTiming? {
        let reader = try AVAssetReader(asset: asset)
        // No output settings at all: passthrough of the compressed samples.
        // Timing survives, the decoder is never woken, and this stays cheap
        // enough to run before every analysis instead of being a setting.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var durations: [Double] = []
        var stamps: [Double] = []
        while durations.count < sampleLimit, stamps.count < sampleLimit,
              let sb = output.copyNextSampleBuffer() {
            let d = CMSampleBufferGetDuration(sb)
            if d.isNumeric, d.seconds > 0 { durations.append(d.seconds) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if pts.isNumeric { stamps.append(pts.seconds) }
        }

        // Per-sample durations when the container carries them: they are
        // already per-frame and immune to ordering.
        var intervals = durations
        if intervals.count < 8 {
            // Otherwise fall back to the gaps between timestamps. Sorted
            // first, because a passthrough reader emits in DECODE order, and
            // any footage carrying B-frames would otherwise hand back negative
            // intervals and a nonsense rate.
            let ordered = stamps.sorted()
            intervals = zip(ordered.dropFirst(), ordered).map { $0 - $1 }.filter { $0 > 0 }
        }
        return frameTiming(fromIntervals: intervals)
    }

    /// The arithmetic, split out from the reading so it can be tested without
    /// a video file.
    ///
    /// The median, not the mean: one dropped frame doubles a single interval,
    /// and a mean would quietly drag the rate down with it while a median does
    /// not notice. That distinction is the whole reason this is a function
    /// rather than a division.
    static func frameTiming(fromIntervals intervals: [Double]) -> FrameTiming? {
        let usable = intervals.filter { $0 > 0 && $0.isFinite }
        guard usable.count >= 4 else { return nil }
        let sorted = usable.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0, median.isFinite else { return nil }
        let irregular = usable.filter { abs($0 - median) > median * 0.2 }.count
        return FrameTiming(fps: 1 / median,
                           intervals: usable.count,
                           irregularFraction: Double(irregular) / Double(usable.count))
    }

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
