import AVFoundation
import CoreMedia
import Foundation

struct ClipAnalysis: Sendable {
    var metrics: SwingMetrics
    var track: [BallObservation]
    var bat: BatMetrics?
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
        var direction: TrackBuilder.Direction = .auto
        var rollDeg: Double = 0
        /// Container frame rate is trusted for clips this app recorded. Set
        /// this for imported footage whose metadata lies (iPhone slo-mo often
        /// reports 30 fps with every 240 fps frame present).
        var fpsOverride: Double?
        /// How far either side of Vision's parabola a candidate may sit.
        var corridorPx: Double = 90
        /// Skip Vision and go straight to full-frame detection.
        var forceFallbackDetector = false
    }

    /// - Parameters:
    ///   - contactTime: seconds from clip start, from the audio trigger. When
    ///     `nil`, the first tracked point is treated as contact.
    ///   - progress: 0...1, called on an arbitrary thread.
    ///
    /// Does blocking I/O; call from a detached task.
    static func analyze(url: URL,
                        contactTime: Double?,
                        options: Options = Options(),
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

        // --- pass 1: Vision locates the flight ---
        var hint: TrajectoryHint?
        if !options.forceFallbackDetector {
            let detector = TrajectoryDetector(imageWidth: width, imageHeight: height)
            try forEachSampleBuffer(asset: asset, track: videoTrack) { sb, _, t in
                detector.process(sampleBuffer: sb)
                if duration > 0 { progress?(min(0.45, 0.45 * t / duration)) }
            }
            hint = detector.hint()
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

        try forEachSampleBuffer(asset: asset, track: videoTrack) { sb, index, t in
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            _ = PixelImage.withImage(pb) { img in
                var cands = BallDetector.detect(image: img,
                                                frame: index,
                                                t: t,
                                                settings: options.detector,
                                                roi: searchROI)
                if let h = hint {
                    cands = cands.filter { h.admits(x: $0.x, y: $0.y, corridorPx: options.corridorPx) }
                }
                if !cands.isEmpty { perFrame[index] = cands }

                if options.trackBat, let w = batWindow, w.contains(t),
                   let p = BatTracker.detectTape(image: img, settings: options.bat) {
                    tape.append(BatTracker.TapeObservation(t: t, x: p.x, y: p.y))
                }
            }
            if duration > 0 { progress?(0.45 + min(0.5, 0.5 * t / duration)) }
        }

        // --- build the track ---
        var tracks = TrackBuilder.buildTracks(perFrame: perFrame, fps: fps)
        var selected = TrackBuilder.selectOutboundTrack(tracks, direction: options.direction)

        // Vision saw a flight but the corridor filter starved the tracker:
        // retry unconstrained rather than reporting nothing.
        if selected == nil && hint != nil && !options.forceFallbackDetector {
            var retry = options
            retry.forceFallbackDetector = true
            return try await analyze(url: url, contactTime: contactTime,
                                     options: retry, progress: progress)
        }
        if selected == nil, !tracks.isEmpty {
            tracks.sort { $0.count > $1.count }
            selected = tracks.first
        }
        guard let track = selected, track.count >= 3 else {
            throw ClipAnalysisError.noBallTrack
        }

        let effectiveContact = contactTime ?? track[0].t
        let metrics = SwingAnalyzer.analyze(track: track,
                                            contactTime: effectiveContact,
                                            rollDeg: options.rollDeg)
        let bat = options.trackBat ? BatTracker.analyze(observations: tape,
                                                        contactTime: effectiveContact) : nil
        progress?(1.0)

        return ClipAnalysis(metrics: metrics,
                            track: track,
                            bat: bat,
                            fps: fps,
                            frameWidth: width,
                            frameHeight: height,
                            contactTime: effectiveContact,
                            usedVisionHint: hint != nil)
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
