// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// Burns the tracking overlay into a slow-motion clip you can send to somebody.
///
/// The review screen already draws all of this live, so why re-render it? Because
/// the live overlay only exists inside this app. A hitter wanting to show a coach
/// what happened, or wanting to look at it again in six months, has a 240fps file
/// that plays in a third of a second and shows nothing. This is the artefact that
/// leaves the phone.
///
/// **Drawn in encoded buffer pixels, with the source's `preferredTransform`
/// copied onto the output track.** Every measurement in this app lives in buffer
/// pixels, so drawing there needs no coordinate mapping at all and cannot be
/// rotated wrong — the player applies the same rotation to picture and overlay
/// together. Mapping into display space first, which is what the on-screen
/// overlay has to do, is the step that historically produced a confident
/// ninety-degrees-wrong drawing. Here it is simply not performed.
///
/// **Slow motion is retiming, not interpolation.** Every source frame is kept and
/// written at 30fps, so 240fps footage comes out eight times slower with no
/// frames invented and no blending. The output frame rate is the only knob.
///
/// What is deliberately NOT drawn: rejected candidates, the search region, and
/// the other tracks the builder produced. Those are diagnostics — they answer
/// "why did the app get this wrong", which is a question for the review screen,
/// not for a clip somebody is being shown their swing on.
enum OverlayVideoExporter {

    struct Options {
        /// Frames per second in the exported file. Every source frame is kept,
        /// so the slow-motion factor is (source fps ÷ this).
        var outputFPS: Int32 = 30
        /// Seconds either side of contact to include. The whole clip at 8x is a
        /// half-minute of mostly empty field.
        var leadS: Double = 0.75
        var trailS: Double = 1.25
        var drawBall = true
        var drawTrail = true
        var drawSkeleton = true
        var drawBat = true
        /// Burned-in numbers, bottom-left. Counter-rotated so it reads upright
        /// after the track transform is applied.
        var caption: String?
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case cannotRead(String)
        case cannotWrite(String)
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:      return "That clip has no video track."
            case .cannotRead(let m): return "Could not read the clip: \(m)"
            case .cannotWrite(let m): return "Could not write the export: \(m)"
            case .noFrames:          return "No frames fell inside the export window."
            }
        }
    }

    /// - Parameters:
    ///   - track: the measured ball path, in buffer pixels.
    ///   - pose: the hitter's joints per frame, in buffer pixels.
    ///   - batPath: the barrel-tape path in RAW buffer pixels. Raw, not the
    ///     rectified `BatMetrics.pathPx`: everything here is drawn on the
    ///     original frames, and the rectified path would sit visibly beside the
    ///     bat on any clip filmed off level.
    ///   - contactTime: clip time of contact, which the window is centred on.
    static func export(clip url: URL,
                       track: [BallObservation],
                       pose: [PoseObservation],
                       batPath: [CGPoint],
                       contactTime: Double,
                       options: Options = Options(),
                       progress: ((Double) -> Void)? = nil) async throws -> URL {

        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { throw ExportError.noVideoTrack }

        let start = max(0, contactTime - options.leadS)
        let end = contactTime + options.trailS

        // --- reader ---
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.cannotRead("no BGRA output") }
        reader.add(output)

        // --- writer ---
        let dst = ClipStore.exportsDirectory
            .appendingPathComponent("swing_slowmo_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, width * height * 8),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        // The whole reason the overlay needs no coordinate mapping: the output
        // track carries the source's rotation, so the player turns the picture
        // and the drawing together.
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        guard writer.canAdd(input) else { throw ExportError.cannotWrite("cannot add video input") }
        writer.add(input)

        guard reader.startReading() else {
            throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let sorted = track.sorted { $0.t < $1.t }
        let poses = pose.sorted { $0.t < $1.t }
        let caption = options.caption
        let captionAngle = rotationAngle(of: transform)

        var frameIndex: Int64 = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let t = pts.isNumeric ? pts.seconds : 0

            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.cannotWrite("no pixel buffer pool")
            }
            var maybe: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe) == kCVReturnSuccess,
                  let dstBuffer = maybe else {
                throw ExportError.cannotWrite("could not allocate a frame")
            }

            copy(src: src, dst: dstBuffer)
            draw(into: dstBuffer, width: width, height: height,
                 t: t, track: sorted, poses: poses, batPath: batPath,
                 contactTime: contactTime, options: options,
                 caption: caption, captionAngle: captionAngle)

            let outPTS = CMTime(value: frameIndex, timescale: options.outputFPS)
            guard adaptor.append(dstBuffer, withPresentationTime: outPTS) else {
                throw ExportError.cannotWrite(
                    writer.error?.localizedDescription ?? "frame rejected by the writer")
            }
            frameIndex += 1
            if end > start {
                progress?(min(1.0, (t - start) / (end - start)))
            }
        }

        guard frameIndex > 0 else {
            reader.cancelReading()
            writer.cancelWriting()
            throw ExportError.noFrames
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "write failed")
        }
        progress?(1.0)
        return dst
    }

    // MARK: - Pixels

    /// Row-by-row copy rather than a CGImage round-trip. The source and
    /// destination are both BGRA at the same size, so this is a memcpy per row
    /// and costs nothing; going through Core Image would allocate and colour-
    /// manage every one of several hundred frames.
    private static func copy(src: CVPixelBuffer, dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return }
        let sRow = CVPixelBufferGetBytesPerRow(src)
        let dRow = CVPixelBufferGetBytesPerRow(dst)
        let rows = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let bytes = min(sRow, dRow)
        for y in 0..<rows {
            memcpy(d.advanced(by: y * dRow), s.advanced(by: y * sRow), bytes)
        }
    }

    // MARK: - Drawing

    private static func draw(into buffer: CVPixelBuffer,
                             width: Int, height: Int,
                             t: Double,
                             track: [BallObservation],
                             poses: [PoseObservation],
                             batPath: [CGPoint],
                             contactTime: Double,
                             options: Options,
                             caption: String?,
                             captionAngle: CGFloat) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // Buffer pixels are y-down; CoreGraphics is y-up. Flip once here and
        // every coordinate below is the same number the detector measured.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Line weights scale with the picture: a 2pt stroke that reads well on
        // a 720p export is invisible on 4K.
        let k = CGFloat(max(width, height)) / 1280.0

        if options.drawTrail, track.count >= 2 {
            // Only the flight SO FAR. Drawing the whole path from frame one
            // gives away where the ball ends up before it gets there, which
            // makes the export useless for showing somebody what happened.
            let sofar = track.filter { $0.t <= t }
            if sofar.count >= 2 {
                ctx.setStrokeColor(UIColor(Theme.yellow).withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(2.5 * k)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: sofar[0].x, y: sofar[0].y))
                for o in sofar.dropFirst() { ctx.addLine(to: CGPoint(x: o.x, y: o.y)) }
                ctx.strokePath()
            }
        }

        // Only from just before contact. The barrel path is measured over ~60
        // ms; showing it for the whole clip would draw a bat that is not there.
        if options.drawBat, batPath.count >= 2, t >= contactTime - 0.12 {
            ctx.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(3 * k)
            ctx.beginPath()
            ctx.move(to: batPath[0])
            for p in batPath.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }

        if options.drawSkeleton, let observation = nearest(poses, to: t) {
            ctx.setStrokeColor(UIColor(Theme.yellow).cgColor)
            ctx.setLineWidth(2.5 * k)
            for segment in PoseJoint.segments {
                var started = false
                ctx.beginPath()
                for joint in segment {
                    guard let p = observation.point(joint) else {
                        // A break, not a shortcut: joining across a joint the
                        // model was unsure about draws a limb that was never
                        // detected.
                        if started { ctx.strokePath() }
                        started = false
                        continue
                    }
                    if started { ctx.addLine(to: p) } else { ctx.move(to: p); started = true }
                }
                if started { ctx.strokePath() }
            }
            ctx.setFillColor(UIColor(Theme.yellow).cgColor)
            for joint in PoseJoint.allCases {
                guard let p = observation.point(joint) else { continue }
                let r = 3.5 * k
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }

        if options.drawBall, let o = nearestBall(track, to: t) {
            // At the MEASURED diameter, not a fixed marker size. The scale that
            // every mile per hour rests on is that diameter, so a ring visibly
            // bigger or smaller than the ball under it is a scale error made
            // visible — in the artefact somebody else will look at, not only on
            // a debug screen.
            let d = max(8, o.diameterPx)
            ctx.setStrokeColor(UIColor(Theme.pass).cgColor)
            ctx.setLineWidth(2.5 * k)
            ctx.strokeEllipse(in: CGRect(x: o.x - d / 2, y: o.y - d / 2, width: d, height: d))
        }

        if let caption, !caption.isEmpty {
            drawCaption(caption, in: ctx, width: width, height: height,
                        k: k, angle: captionAngle)
        }
    }

    /// The caption is the one thing that must NOT rotate with the picture.
    ///
    /// Everything else is a mark on the scene and belongs in the scene's frame;
    /// text belongs to the reader. Drawn in buffer space it would come out
    /// sideways on any clip the transform turns, so it is counter-rotated by
    /// exactly the angle the track carries.
    private static func drawCaption(_ text: String, in ctx: CGContext,
                                    width: Int, height: Int,
                                    k: CGFloat, angle: CGFloat) {
        let font = UIFont.systemFont(ofSize: 22 * k, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(Theme.yellow),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pad = 14 * k

        ctx.saveGState()
        // Back into UIKit's y-down world so the text is not drawn mirrored.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)

        // Rotate about the picture centre, then place the caption relative to
        // the rotated frame's own bottom-left.
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: -angle)
        let rotated = abs(angle) > .pi / 4
        let halfW = (rotated ? CGFloat(height) : CGFloat(width)) / 2
        let halfH = (rotated ? CGFloat(width) : CGFloat(height)) / 2

        let origin = CGPoint(x: -halfW + pad, y: halfH - pad - size.height)
        let box = CGRect(x: origin.x - pad / 2, y: origin.y - pad / 4,
                         width: size.width + pad, height: size.height + pad / 2)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(box)
        string.draw(at: origin)

        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    /// Rotation the video track's transform applies, in radians.
    private static func rotationAngle(of t: CGAffineTransform) -> CGFloat {
        atan2(t.b, t.a)
    }

    private static func nearest(_ poses: [PoseObservation], to t: Double) -> PoseObservation? {
        poses.min { abs($0.t - t) < abs($1.t - t) }
    }

    /// The ball is only drawn on frames it was actually measured on. A ring
    /// that lingers on the last known position after the ball has gone is a
    /// claim the tracker never made.
    private static func nearestBall(_ track: [BallObservation], to t: Double) -> BallObservation? {
        guard let o = track.min(by: { abs($0.t - t) < abs($1.t - t) }) else { return nil }
        return abs(o.t - t) <= 0.008 ? o : nil
    }
}
