// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreVideo
import Foundation

/// A borrowed view of a locked 32BGRA pixel buffer.
///
/// BGRA only — `withImage` returns nil for anything else, so callers must
/// convert first. The `AVAssetReader` in `ClipAnalyzer` asks for BGRA
/// directly; the **live capture output does not** (it runs at the device-native
/// YUV format so the encoder can take frames untouched), so live frames go
/// through `PixelBufferConvert.toBGRA` on their way here.
///
/// That distinction used to be documented the other way round, and the live
/// measurement path quietly returned nil for every tap as a result.
///
/// The instance is only valid while the underlying buffer stays locked —
/// never store one.
struct PixelImage {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    @inline(__always)
    func pixel(x: Int, y: Int) -> (b: Double, g: Double, r: Double) {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let p = base + cy * bytesPerRow + cx * 4
        return (Double(p[0]), Double(p[1]), Double(p[2]))
    }

    /// Bilinear sample with edge replication, mirroring OpenCV's
    /// `remap(..., INTER_LINEAR, BORDER_REPLICATE)` used by the reference
    /// sub-pixel diameter measurement.
    @inline(__always)
    func sampleBilinear(x: Double, y: Double) -> (b: Double, g: Double, r: Double) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        let p00 = pixel(x: x0, y: y0)
        let p10 = pixel(x: x0 + 1, y: y0)
        let p01 = pixel(x: x0, y: y0 + 1)
        let p11 = pixel(x: x0 + 1, y: y0 + 1)
        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy
        return (
            p00.b * w00 + p10.b * w10 + p01.b * w01 + p11.b * w11,
            p00.g * w00 + p10.g * w10 + p01.g * w01 + p11.g * w11,
            p00.r * w00 + p10.r * w10 + p01.r * w01 + p11.r * w11
        )
    }

    /// Run `body` against a locked pixel buffer. Returns `nil` if the buffer
    /// is not BGRA or cannot be locked.
    static func withImage<T>(_ pb: CVPixelBuffer, _ body: (PixelImage) throws -> T) rethrows -> T? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let img = PixelImage(
            base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
            width: CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb)
        )
        return try body(img)
    }
}

/// OpenCV-compatible 8-bit HSV, so venue tuning transfers unchanged between
/// `track_ball.py --hsv-lo/--hsv-hi` and the app's Settings screen.
///
/// H is halved into 0..179 exactly as OpenCV does; S and V are 0..255.
enum HSVConvert {
    @inline(__always)
    static func fromBGR(b: Double, g: Double, r: Double) -> (h: Double, s: Double, v: Double) {
        let v = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = v - minC
        let s = v > 0 ? delta * 255.0 / v : 0
        var h: Double = 0
        if delta > 0 {
            if v == r {
                h = 60 * (g - b) / delta
            } else if v == g {
                h = 120 + 60 * (b - r) / delta
            } else {
                h = 240 + 60 * (r - g) / delta
            }
            if h < 0 { h += 360 }
        }
        return (h / 2, s, v)
    }

    /// Exactly `fromBGR` followed by the three range tests, with the tests
    /// reordered so the cheap ones run first.
    ///
    /// Not an approximation — the same arithmetic, short-circuited. Value and
    /// saturation each cost a couple of comparisons and at most one divide;
    /// hue costs a three-way branch, a second divide and a wrap. The old
    /// version computed hue for every pixel and then usually threw it away,
    /// because on a frame of grass, sky, dirt and skin almost everything fails
    /// on brightness or saturation first. At two million pixels a frame and
    /// several hundred frames a clip, that ordering was most of the runtime of
    /// the full-frame fallback.
    @inline(__always)
    static func inRange(b: Double, g: Double, r: Double,
                        lo: HSVBounds, hi: HSVBounds) -> Bool {
        let v = max(r, max(g, b))
        guard v >= lo.v, v <= hi.v else { return false }

        let minC = min(r, min(g, b))
        let delta = v - minC
        let s = v > 0 ? delta * 255.0 / v : 0
        guard s >= lo.s, s <= hi.s else { return false }

        // Grey pixels have no hue; `fromBGR` reports 0 for them, so match that
        // rather than inventing a different answer for the degenerate case.
        var h: Double = 0
        if delta > 0 {
            if v == r {
                h = 60 * (g - b) / delta
            } else if v == g {
                h = 120 + 60 * (b - r) / delta
            } else {
                h = 240 + 60 * (r - g) / delta
            }
            if h < 0 { h += 360 }
        }
        h /= 2
        return h >= lo.h && h <= hi.h
    }
}
