// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation

/// Putting measured points back on top of the picture they were measured from.
///
/// Everything this app measures — ball centres, diameters, pose joints — is in
/// **encoded buffer pixels**, y down, because that is the frame the detector
/// walked. What a player shows is not that frame. A video track carries a
/// `preferredTransform` that rotates and flips the encoded pixels into the
/// picture a viewer sees, and iPhone footage uses it constantly: the sensor
/// reads out landscape whichever way the phone was held, and the transform is
/// what makes a portrait clip portrait.
///
/// Skipping that step does not produce a slightly wrong overlay. It produces
/// one rotated ninety degrees, drawn confidently, which reads as "the tracker
/// is broken" when the tracker was right and the drawing was wrong. That is
/// the opposite of what an overlay is for.
///
/// Everything here is pure and pinned by `VideoOverlayGeometryTests`, because
/// the failure mode is a picture that looks plausible and is not.
enum VideoOverlayGeometry {

    /// How big the video is once the transform has been applied — the size a
    /// player actually lays out.
    static func displaySize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let t = natural.applying(transform)
        return CGSize(width: abs(t.width), height: abs(t.height))
    }

    /// Where the picture sits inside a view, letterboxed.
    ///
    /// `AVPlayerLayer` and AVKit's `VideoPlayer` both default to
    /// `.resizeAspect`, so the video is centred with bars on two sides and the
    /// overlay has to land in the same rect rather than on the whole view.
    static func videoRect(displaySize: CGSize, in viewSize: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / displaySize.width,
                        viewSize.height / displaySize.height)
        let w = displaySize.width * scale
        let h = displaySize.height * scale
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2,
                      width: w, height: h)
    }

    /// Points per encoded pixel. Aspect-fit is uniform, so one number does for
    /// both axes — and for lengths like a ball diameter.
    static func scale(natural: CGSize, transform: CGAffineTransform,
                      in viewSize: CGSize) -> CGFloat {
        let display = displaySize(natural: natural, transform: transform)
        let rect = videoRect(displaySize: display, in: viewSize)
        guard display.width > 0 else { return 0 }
        return rect.width / display.width
    }

    /// A point in the view, back to encoded buffer pixels — the inverse of
    /// `viewPoint`. Returns nil for taps outside the picture (the letterbox
    /// bars), which is a real answer: there is nothing there to point at.
    static func bufferPoint(viewPoint p: CGPoint, natural: CGSize,
                            transform: CGAffineTransform,
                            in viewSize: CGSize) -> CGPoint? {
        let display = displaySize(natural: natural, transform: transform)
        let rect = videoRect(displaySize: display, in: viewSize)
        guard rect.width > 0, rect.height > 0, rect.contains(p) else { return nil }
        let dx = (p.x - rect.minX) * (display.width / rect.width)
        let dy = (p.y - rect.minY) * (display.height / rect.height)
        // Undo the preferred transform to land back in encoded coordinates.
        guard transform.isInvertible else { return CGPoint(x: dx, y: dy) }
        return CGPoint(x: dx, y: dy).applying(transform.inverted())
    }

    /// Whether the transform turns the picture a quarter turn, so the
    /// displayed VERTICAL spans the buffer's width rather than its height.
    ///
    /// A lens's field of view is quoted horizontally for the sensor's own
    /// landscape frame. Working out what vertical angle a viewer is seeing
    /// therefore depends on which way the picture was turned, and getting it
    /// backwards on a portrait clip scales every angle read off the screen by
    /// the frame's aspect ratio — nearly a factor of two on 16:9.
    static func isQuarterTurned(natural: CGSize, transform: CGAffineTransform) -> Bool {
        let d = displaySize(natural: natural, transform: transform)
        return abs(d.width - natural.height) < 1 && abs(d.height - natural.width) < 1
    }

    /// The whole job: an encoded buffer pixel, as a point in the view.
    ///
    /// The transform already carries the translation that keeps the rotated
    /// picture in positive coordinates, so applying it to a point lands
    /// directly in display space — no separate flip or offset to get wrong.
    static func viewPoint(bufferPoint: CGPoint, natural: CGSize,
                          transform: CGAffineTransform,
                          in viewSize: CGSize) -> CGPoint {
        let display = displaySize(natural: natural, transform: transform)
        let rect = videoRect(displaySize: display, in: viewSize)
        guard display.width > 0, display.height > 0 else { return .zero }
        let p = bufferPoint.applying(transform)
        return CGPoint(x: rect.minX + p.x * (rect.width / display.width),
                       y: rect.minY + p.y * (rect.height / display.height))
    }
}
