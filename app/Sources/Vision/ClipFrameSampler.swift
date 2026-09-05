// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// One frame out of a stored clip, as a buffer the detector can read.
///
/// Exists so the ball can be learned from a clip you have already filmed, not
/// only from the live camera. The review screen shows its frames through
/// `AVPlayer`, which hands back pixels to nobody, so pointing at the ball there
/// could record WHERE it was and never what it looked like.
enum ClipFrameSampler {

    /// - Parameter seconds: presentation time, matching the times in the track
    ///   CSV and `ballSeedT`.
    ///
    /// **No preferred track transform.** `ballSeedX/Y` are raw buffer pixels —
    /// `VideoOverlayGeometry.bufferPoint` undoes the display rotation when the
    /// tap is recorded — so a frame decoded with the transform applied would be
    /// a different coordinate system from the tap that indexes into it, and the
    /// colour would be sampled from whatever happened to sit at the mirrored
    /// position.
    static func frame(url: URL, at seconds: Double) async -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = false
        // Both tolerances, both zero. The default is half a second either way,
        // which at 240fps is 120 frames — the ball would be sampled from
        // somewhere else entirely in the swing.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else { return nil }
        return bgraBuffer(from: cg)
    }

    /// A CGImage rendered into a 32BGRA `CVPixelBuffer`.
    ///
    /// `PixelImage.withImage` accepts BGRA and nothing else, and returns nil
    /// rather than misreading another layout — so the byte order here is not a
    /// detail. `.byteOrder32Little` with `.premultipliedFirst` is what CoreGraphics
    /// calls ARGB-little, which in memory is B, G, R, A: the same bytes
    /// `kCVPixelFormatType_32BGRA` names.
    static func bgraBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
