// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import ImageIO

/// Maps Vision's coordinates back onto the pixel buffer they came from.
///
/// This is small and load-bearing, and it is the classic thing to get
/// backwards, so it lives in one tested place rather than inline at each call
/// site.
///
/// Two conventions have to be reconciled:
///
///  * **Vision** returns normalized points with the origin **bottom-left**,
///    y up, measured on the image *after* the `CGImagePropertyOrientation`
///    handed to the request has been applied. On a tripod that orientation is
///    never `.up`, so the axes are usually swapped relative to the buffer.
///  * **The buffer** — and AVFoundation's "capture device point", which
///    `AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)`
///    expects — is normalized with the origin **top-left**, y down, on the raw
///    rows and columns as delivered.
///
/// The two happen to be the same thing, which is what makes one helper enough
/// for both drawing a skeleton over the preview and reading joints in buffer
/// pixels offline.
///
/// The orientation cases are derived from the EXIF definitions Apple documents
/// on `CGImagePropertyOrientation` — each says where the stored image's 0th row
/// and 0th column end up on screen:
///
///  * `.up`    — 0th row top, 0th column left. Identity.
///  * `.down`  — 0th row bottom, 0th column right. 180°.
///  * `.right` — 0th row **right**, 0th column top. So a raw row index runs
///               right-to-left across the display and a raw column index runs
///               down it.
///  * `.left`  — 0th row **left**, 0th column bottom.
///
/// Mirrored variants are not produced by this app: the capture path only ever
/// hands Vision an orientation derived from `AVCaptureDevice.RotationCoordinator`,
/// and the rear camera is not mirrored. They fall through to the unrotated
/// mapping rather than silently claiming a rotation that was not applied.
enum VisionGeometry {

    /// Vision's normalized point → the buffer's normalized point (top-left
    /// origin, y down), which is also AVFoundation's capture-device point.
    static func devicePoint(fromVision point: CGPoint,
                            orientation: CGImagePropertyOrientation) -> CGPoint {
        // First to the oriented image with a top-left origin, matching how
        // every downstream convention measures.
        let dx = point.x
        let dy = 1 - point.y
        switch orientation {
        case .up, .upMirrored:
            return CGPoint(x: dx, y: dy)
        case .down, .downMirrored:
            return CGPoint(x: 1 - dx, y: 1 - dy)
        case .right, .rightMirrored:
            return CGPoint(x: dy, y: 1 - dx)
        case .left, .leftMirrored:
            return CGPoint(x: 1 - dy, y: dx)
        @unknown default:
            return CGPoint(x: dx, y: dy)
        }
    }

    /// Vision's normalized point → pixels in the buffer, y down.
    ///
    /// `width`/`height` are the **buffer's** dimensions, not the oriented
    /// image's — the whole point of the conversion above is that the caller
    /// never has to reason about which pair is which.
    static func imagePoint(fromVision point: CGPoint,
                           orientation: CGImagePropertyOrientation,
                           width: Int, height: Int) -> CGPoint {
        let d = devicePoint(fromVision: point, orientation: orientation)
        return CGPoint(x: d.x * CGFloat(width), y: d.y * CGFloat(height))
    }
}
