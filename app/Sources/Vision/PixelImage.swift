import CoreVideo
import Foundation

/// A borrowed view of a locked 32BGRA pixel buffer.
///
/// Every frame that reaches the detector is BGRA: the capture output and the
/// `AVAssetReader` are both configured to hand us `kCVPixelFormatType_32BGRA`
/// so no YUV conversion code exists in this app. The instance is only valid
/// while the underlying buffer stays locked — never store one.
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

    @inline(__always)
    static func inRange(b: Double, g: Double, r: Double,
                        lo: HSVBounds, hi: HSVBounds) -> Bool {
        let (h, s, v) = fromBGR(b: b, g: g, r: r)
        return h >= lo.h && h <= hi.h
            && s >= lo.s && s <= hi.s
            && v >= lo.v && v <= hi.v
    }
}
