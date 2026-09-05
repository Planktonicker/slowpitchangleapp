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
        // How the container says the buffer should be turned for display. The
        // measurement needs it because a launch angle is signed — see
        // `VideoOrientation`.
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
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
        diagnostics?.frameDropFraction = timing?.droppedFraction

        // Which way the buffer must turn to be the picture a person sees.
        // From the container's display matrix when it carries one; otherwise
        // from the capture-time Vision orientation — the app's OWN recordings
        // are written straight from the encoder with no matrix at all, so a
        // phone mounted the other way up produced clips whose buffer was
        // upside down and whose transform said it was not. Every signed
        // number (launch angle above all) is measured after this turn.
        var quarterTurns = VideoOrientation.quarterTurns(preferredTransform)
        if quarterTurns == 0 {
            quarterTurns = VideoOrientation.quarterTurns(from: options.visionOrientation)
        }
        diagnostics?.videoQuarterTurns = quarterTurns

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
        // The bat window exists only when contact is genuinely known — the
        // audio trigger on a live capture. It used to fall back to Vision's
        // flight start, and Vision's flight is structurally the PITCH, so on
        // imports the tape was collected a second before contact and the
        // quadratic fit then EXTRAPOLATED to t=0: a fabricated attack angle,
        // bat speed and smash factor from a cluster of glove-coloured pixels.
        // No contact, no bat panel — absent, not invented.
        let batWindow: ClosedRange<Double>? = contactTime.map {
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
                var cands: [BallObservation] = []
                if motion != nil {
                    let found = BallDetector.detectWithCensus(image: img,
                                                              frame: index,
                                                              t: t,
                                                              settings: options.detector,
                                                              roi: searchROI,
                                                              motion: motion)
                    cands = found.observations
                    // Every frame, not only the ones that produced something.
                    // A frame with blobs and no candidates and a frame with no
                    // blobs at all are the two different answers to "why did
                    // the ball stop being seen here", and only this tells them
                    // apart.
                    let c = found.census
                    if (trace.frameCensus?.count ?? 0) < DetectionTrace.candidateLimit {
                        if trace.frameCensus == nil { trace.frameCensus = [] }
                        trace.frameCensus?.append(
                            DetectionTrace.FrameCensus(frame: index, t: t,
                                                       blobs: c.blobs,
                                                       tooSmall: c.tooSmall,
                                                       tooLarge: c.tooLarge,
                                                       tooElongated: c.tooElongated,
                                                       diameterOutOfRange: c.diameterOutOfRange,
                                                       passed: c.passed))
                    }
                    diagnostics?.gateBlobs += c.blobs
                    diagnostics?.gateTooSmall += c.tooSmall
                    diagnostics?.gateTooLarge += c.tooLarge
                    diagnostics?.gateTooElongated += c.tooElongated
                    diagnostics?.gateDiameterOutOfRange += c.diameterOutOfRange
                }
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
        // Selection happens in DISPLAY space. `direction` means which way the
        // hit crosses the picture a person sees; on a clip whose buffer is
        // turned, a buffer-space vx points the other way (180) or sideways
        // (90), and the direction gate then rejects the hit and hands back the
        // pitch. The chosen index maps straight back to the raw track, which
        // stays in buffer pixels for the overlay.
        let uprightTracks = tracks.map {
            VideoOrientation.rotate(track: $0, width: width, height: height,
                                    quarterTurns: quarterTurns)
        }
        func pickIndex(direction: TrackBuilder.Direction) -> Int? {
            guard let t = TrackBuilder.selectOutboundTrack(uprightTracks,
                                                           direction: direction,
                                                           contactTime: contactTime)
            else { return nil }
            return uprightTracks.firstIndex(of: t)
        }
        // The contact instant, when the caller knows it, is what keeps the
        // incoming pitch out of the answer — see `selectOutboundTrack`. It is
        // known on every live capture (the audio trigger, corrected for the
        // speed of sound) and unknown on most imports, where selection falls
        // back to speed as before.
        var selected = pickIndex(direction: options.direction).map { tracks[$0] }

        // Last resort, when the requested direction matched nothing. This used
        // to take the LONGEST track, which on a swing clip is reliably the
        // worst possible answer: the longest thing in the footage is either an
        // inbound pitch hanging in frame for two seconds or a patch of grass
        // being re-detected, never the hit. Falling back to the same scoring
        // with the direction constraint dropped keeps the "fastest coherent
        // track" rule and gives up only the thing that actually failed.
        if selected == nil, !tracks.isEmpty {
            selected = pickIndex(direction: .auto).map { tracks[$0] }
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
                                                      direction: options.direction,
                                                      contactTime: contactTime)
                throw ClipAnalysisError.noBallAtSeed
            }
        }

        // Record what the builder produced and why the losers lost, BEFORE
        // everything but the winner is thrown away. This is the only place
        // that knowledge exists.
        trace.tracksBuilt = tracks.count
        trace.trackSummaries = Self.summarise(tracks: tracks, selected: selected,
                                              direction: options.direction,
                                              contactTime: contactTime)
        trace.stitchExplains = Self.explainUnjoined(chains: tracks)
        // The instant every track is being judged against. `selectOutbound`
        // keeps only what began at or after it — and imposes no upper bound,
        // so a track half a second later is as eligible as one at contact.
        // Whether that is the right rule is a measurement question; showing
        // the reader the instant is not, and without it the summaries cannot
        // be read at all.
        trace.contactT = contactTime
        trace.contactSource = contactTime == nil ? "none — taken from the first frame of flight"
                                                 : "audio trigger"
        if let contactTime, let selected, let first = selected.first {
            diagnostics?.selectedStartsAfterContactS = first.t - contactTime
            diagnostics?.tracksNearContact = tracks.filter {
                guard let f = $0.first else { return false }
                return abs(f.t - contactTime) <= 0.15
            }.count
            // Against the RELAXED minimum, which is the one that applies to
            // them. Counted against eight, this said "too short to be scored"
            // about tracks the selector had just scored.
            diagnostics?.shortTracksNearContact = tracks.filter {
                guard let f = $0.first else { return false }
                return abs(f.t - contactTime) <= 0.15 && $0.count < SLA.nearContactMinFrames
            }.count
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
        //
        // Rotation first, for the same reason and a more basic one: a launch
        // angle is SIGNED. Measuring it in the encoded buffer is only
        // orientation-independent for lengths; on a clip whose buffer is
        // upside down a ball dropped from head height read +76.9 deg — going
        // almost straight UP — and the pipeline then correctly refused it as
        // impossible. The tracking was perfect. The frame it was measured in
        // was not the frame anybody sees.
        let turns = quarterTurns
        let display = VideoOrientation.displaySize(width: width, height: height,
                                                   quarterTurns: turns)
        let upright = VideoOrientation.rotate(track: track, width: width, height: height,
                                              quarterTurns: turns)

        // Focal length from the BUFFER width. The horizontal field of view
        // describes the sensor's landscape span, which is the buffer's long
        // axis whatever the display turn — computing it from display.width
        // made the focal wrong by the aspect ratio (~1.78x) on quarter-turned
        // clips, so tilt rectification injected bias instead of removing it.
        // A pinhole's focal in pixels is the same in every direction, so one
        // number serves the rotated frame too.
        let focalPx = TiltRectifier.focalPx(widthPx: Double(width),
                                            fovDeg: options.fieldOfViewDeg)
        let cx = Double(display.width) / 2, cy = Double(display.height) / 2
        let measured = TiltRectifier.rectify(track: upright,
                                             tiltDeg: options.tiltDeg,
                                             focalPx: focalPx, cx: cx, cy: cy)
        // The tape goes through both warps too, or the contact-offset reading
        // would compare an upright, rectified ball against a raw barrel.
        let measuredTape: [BatTracker.TapeObservation] = tape.map { o in
            let u = VideoOrientation.point(x: o.x, y: o.y, width: width, height: height,
                                           quarterTurns: turns)
            guard options.tiltDeg != 0, focalPx > 0 else {
                return BatTracker.TapeObservation(t: o.t, x: u.x, y: u.y)
            }
            let r = TiltRectifier.rectify(x: u.x, y: u.y, tiltDeg: options.tiltDeg,
                                          focalPx: focalPx, cx: cx, cy: cy)
            return BatTracker.TapeObservation(t: o.t, x: r.x, y: r.y)
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
            // Vision must be shown the frames upright or it finds nobody. The
            // capture path records the orientation; imports never had one, so
            // fall back to the container's turn — .up on a 180 clip is how the
            // body pass silently returned nothing for a hitter in plain view.
            let poseOrientation = options.visionOrientation == .up
                ? VideoOrientation.imageOrientation(quarterTurns: turns)
                : options.visionOrientation
            pose = try detectPose(asset: asset, track: videoTrack,
                                  fps: fps, sampleHz: options.poseSampleHz,
                                  orientation: poseOrientation,
                                  width: width, height: height,
                                  diagnostics: diagnostics,
                                  duration: duration, progress: progress)
            // Raw joints are what is STORED and DRAWN — the overlay sits on the
            // original frames, the same split the ball and bat use. Only the
            // copy the numbers come from is rotated and rectified; measuring
            // from the rectified copy while drawing it raw is how the skeleton
            // floated beside the hitter on any off-level clip.
            let poseMeasured = VideoOrientation.rotate(pose: pose,
                                                       width: width, height: height,
                                                       quarterTurns: turns)
                .map { obs -> PoseObservation in
                    guard options.tiltDeg != 0, focalPx > 0 else { return obs }
                    var joints: [PoseJoint: PosePoint] = [:]
                    for (j, pt) in obs.joints {
                        let r = TiltRectifier.rectify(x: pt.x, y: pt.y,
                                                      tiltDeg: options.tiltDeg,
                                                      focalPx: focalPx, cx: cx, cy: cy)
                        joints[j] = PosePoint(x: r.x, y: r.y, confidence: pt.confidence)
                    }
                    return PoseObservation(frame: obs.frame, t: obs.t, joints: joints)
                }
            body = BodyAnalyzer.analyze(track: poseMeasured,
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
                    // Raw buffer pixels, deliberately. Rotation and tilt
                    // rectification happen in the caller, on the MEASURED copy
                    // only — what this returns is stored and drawn on the
                    // original frames.
                    joints[joint] = PosePoint(x: Double(px.x), y: Double(px.y),
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
                          direction: TrackBuilder.Direction,
                          contactTime: Double?) -> [DetectionTrace.TrackSummary] {
        var out: [DetectionTrace.TrackSummary] = []
        for tr in tracks {
            guard let first = tr.first, let last = tr.last else { continue }
            let dt = last.t - first.t
            let dx = last.x - first.x, dy = last.y - first.y
            // The score selection actually uses. It used to be net
            // displacement over elapsed time, which is a different number on
            // exactly the tracks worth reading a summary about — a stalled
            // blob glued to something fast reads fast by that measure and
            // slow by this one.
            let speed = TrackBuilder.medianStepSpeed(tr) ?? 0
            let straight = TrackBuilder.straightness(tr)
            // Near contact the length gate relaxes, so the reason a track was
            // passed over depends on where it started. Reporting the strict
            // minimum for a track the selector judged by the relaxed one is
            // how a report sends somebody looking for a bug that is not there.
            let nearContact = contactTime.map {
                first.t >= $0 - SLA.selectContactTolS && first.t <= $0 + SLA.selectContactLateS
            } ?? false
            let minLen = nearContact ? SLA.nearContactMinFrames : SLA.minTrackFrames
            let isSelected = selected.map { $0.first?.frame == first.frame
                && $0.last?.frame == last.frame && $0.count == tr.count } ?? false

            // The selector's gates, in the order it applies them.
            var reason = ""
            if !isSelected {
                if tr.count < minLen {
                    reason = "only \(tr.count) frames, needs \(minLen)"
                        + (nearContact ? " even at contact" : "")
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
        /// Fraction of intervals that are not a whole number of frame periods.
        ///
        /// This is the one that means the timing cannot be trusted: everything
        /// downstream reads frame times from the container, so an interval
        /// that lands nowhere near a multiple of the period is a timestamp
        /// nobody can stand behind.
        ///
        /// A gap of exactly four periods is NOT irregular. Four frames were
        /// dropped; the timestamps either side are still true, and a fit
        /// against real times does not care that some are missing. Conflating
        /// the two is what made this warn about clean footage — see
        /// `droppedFraction`.
        var irregularFraction: Double
        /// Frames that never arrived, as a fraction of the frames the clip
        /// would have had at its own rate.
        ///
        /// The honest reading of a gap. It costs resolution rather than
        /// correctness — fewer points in the fit, a wider stitch to cross —
        /// and at some level it costs the measurement, but it is a different
        /// fault from unreliable timing and has a different fix.
        var droppedFraction: Double
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
    /// **Not the median, and this cost a real clip.** `AVAssetWriter` gives a
    /// passthrough video track QuickTime's default time scale of 600 unless
    /// told otherwise, and 600 cannot express 240 fps: a frame is 2.5 ticks,
    /// so the writer alternates 2 and 3 — 3.333 ms, 5.000 ms, 3.333 ms — for
    /// frames that arrived perfectly evenly. The median then lands on one of
    /// those two values (200 fps), and every interval of the other value is
    /// more than 20% away from it, so 40% of a clean clip reads as irregular
    /// and the report tells the hitter to throw the footage away.
    ///
    /// The base period is the mean of the intervals that carry no dropped
    /// frame, which averages the alternation back to the truth — 4.183 ms,
    /// 239 fps, on the clip that exposed this. `ClipRecorder` now sets a time
    /// scale that can express the rate, so new clips do not alternate at all;
    /// this still has to be right for every clip already recorded and for
    /// anything imported.
    static func frameTiming(fromIntervals intervals: [Double]) -> FrameTiming? {
        let usable = intervals.filter { $0 > 0 && $0.isFinite }
        guard usable.count >= 4 else { return nil }
        let sorted = usable.sorted()

        // The shortest intervals are the ones with nothing missing. Taken from
        // the 5th percentile rather than the minimum, so a single impossibly
        // short interval — a duplicated timestamp, a container rounding two
        // frames onto the same tick — cannot set the scale for the whole clip.
        let shortest = sorted[max(0, sorted.count / 20)]
        guard shortest > 0 else { return nil }
        let singles = sorted.filter { $0 <= shortest * 1.5 }
        guard !singles.isEmpty else { return nil }
        let base = singles.reduce(0, +) / Double(singles.count)
        guard base > 0, base.isFinite else { return nil }

        // Each interval is either a whole number of frame periods — one frame,
        // or one plus however many were dropped — or it is a timestamp that
        // means nothing. A quarter of a period is a generous tolerance and
        // deliberately so: it has to swallow the ±0.5 tick of a container that
        // cannot express the rate, which is a fifth of a period at 600.
        var expected = 0.0
        var irregular = 0
        for i in usable {
            let periods = (i / base).rounded()
            if periods >= 1, abs(i - periods * base) <= base * 0.25 {
                expected += periods
            } else {
                irregular += 1
                expected += 1   // it is still one interval between two frames
            }
        }
        let dropped = max(0, expected - Double(usable.count))
        return FrameTiming(fps: 1 / base,
                           intervals: usable.count,
                           irregularFraction: Double(irregular) / Double(usable.count),
                           droppedFraction: expected > 0 ? dropped / expected : 0)
    }

    /// Every pass decodes to BGRA, including the two that only hand the buffer
    /// to Vision and would be happy with the native YUV. That looks like waste
    /// and it is, but the ways to avoid it are all worse: `outputSettings: nil`
    /// vends the track's ORIGINAL format, i.e. still-compressed samples with no
    /// image buffer at all; naming a specific bi-planar YUV forces a conversion
    /// of its own whenever the file's range is the other one; and the two
    /// remaining passes would then run against a different pixel layout from
    /// the measurement pass, which is the one thing here that must not vary.
    /// The conversion is VideoToolbox's and it is not what makes this slow —
    /// the measurement pass walking two million pixels a frame is.
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
