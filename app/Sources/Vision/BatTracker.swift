// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Barrel path through contact, from the fluorescent tape wrapped around the
/// bat (see `docs/CAPTURE_PROTOCOL.md` — the tape is filmed from Phase 0 on
/// precisely so this could be built later).
struct BatMetrics: Equatable, Codable, Sendable {
    var attackAngleDeg: Double
    var nFrames: Int
    var fitRmsPx: Double
    /// Tape centroid path in image pixels, oldest first — drawn over the replay.
    var pathPx: [CGPoint]
    var vxPxS: Double
    var vyPxS: Double
    /// Tape centroid at contact (t = 0 of the fit), in image pixels. Paired
    /// with the ball's position at t0 for the contact-offset (undercut) read.
    var contactXPx: Double
    var contactYPx: Double

    /// The barrel path is measured over a much shorter window than the ball
    /// flight and from a single side-on view, so treat it as indicative.
    /// True 3D swing plane needs two synced cameras (deferred to v2).
    var isLowConfidence: Bool { nFrames < 6 || fitRmsPx > 6.0 }
}

/// Tracks the barrel tape in the frames leading up to contact.
///
/// v1 scope, matching the approved plan: attack angle from the side view plus
/// a swing-path overlay. Deliberately simpler than the ball pipeline — there
/// is no scale cross-check here, because an angle needs no scale.
enum BatTracker {

    struct Settings: Equatable, Codable, Sendable {
        var hsvLo: HSVBounds = SLA.batHSVLoDefault
        var hsvHi: HSVBounds = SLA.batHSVHiDefault
        /// How far before contact to look. The barrel covers a lot of ground
        /// fast; much more than this and the path is no longer a straight
        /// approach to the ball.
        var windowS: Double = 0.06
        var minBlobArea: Double = 30
        var maxBlobArea: Double = 20000
    }

    struct TapeObservation {
        var t: Double
        var x: Double
        var y: Double
    }

    /// Largest tape-coloured blob in a frame, if any.
    static func detectTape(image: PixelImage,
                           settings: Settings,
                           roi: ROI? = nil) -> (x: Double, y: Double)? {
        let r = (roi ?? ROI(x0: 0, y0: 0, x1: image.width, y1: image.height))
            .clamped(width: image.width, height: image.height)
        let w = r.x1 - r.x0, h = r.y1 - r.y0
        guard w > 2, h > 2 else { return nil }

        var mask = [UInt8](repeating: 0, count: w * h)
        for yy in 0..<h {
            let iy = r.y0 + yy
            for xx in 0..<w {
                let p = image.pixel(x: r.x0 + xx, y: iy)
                if HSVConvert.inRange(b: p.b, g: p.g, r: p.r,
                                      lo: settings.hsvLo, hi: settings.hsvHi) {
                    mask[yy * w + xx] = 255
                }
            }
        }
        Morphology.open(&mask, width: w, height: h)
        Morphology.close(&mask, width: w, height: h)

        let blobs = ConnectedComponents.label(mask: mask, width: w, height: h)
        var best: ConnectedComponents.Blob?
        for b in blobs {
            let area = Double(b.count)
            guard area >= settings.minBlobArea, area <= settings.maxBlobArea else { continue }
            if best == nil || b.count > best!.count { best = b }
        }
        guard let b = best else { return nil }
        return (Double(r.x0) + b.meanX, Double(r.y0) + b.meanY)
    }

    /// Fit the barrel path and take its angle at contact.
    static func analyze(observations: [TapeObservation],
                        contactTime: Double) -> BatMetrics? {
        guard observations.count >= 3 else { return nil }
        let sorted = observations.sorted { $0.t < $1.t }
        let ts = sorted.map { $0.t - contactTime }
        let xs = sorted.map { $0.x }
        let ys = sorted.map { $0.y }

        let fx = Geometry.fitQuadratic(ts: ts, vs: xs)
        let fy = Geometry.fitQuadratic(ts: ts, vs: ys)
        // Derivative at t = 0, i.e. at contact.
        let vx = fx.b
        let vy = fy.b
        guard vx != 0 || vy != 0 else { return nil }

        // Up-positive, and independent of which way the hitter faces.
        let angle = atan2(-vy, abs(vx)) * 180 / Double.pi
        let rms = (fx.rms * fx.rms + fy.rms * fy.rms).squareRoot()

        return BatMetrics(
            attackAngleDeg: angle,
            nFrames: sorted.count,
            fitRmsPx: rms,
            pathPx: zip(xs, ys).map { CGPoint(x: $0, y: $1) },
            vxPxS: vx,
            vyPxS: vy,
            contactXPx: fx.c,
            contactYPx: fy.c
        )
    }
}
