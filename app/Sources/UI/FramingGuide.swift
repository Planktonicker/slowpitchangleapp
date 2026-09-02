// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// A picture of the shot to set up, rather than an abstraction.
///
/// This replaces a dashed rectangle labelled HITTER and a small circle labelled
/// BALL, which told you where two things belonged without ever saying which way
/// the hitter faced or which way the ball went — so it could be matched exactly
/// while still filming the wrong shot.
///
/// The geometry it draws is not a style choice. Launch angle and exit velocity
/// are measured from the ball's path across the image, so the flight has to run
/// ACROSS the frame, not toward or away from the lens: a ball flying at the
/// camera is foreshortened, reads slow, and gets flagged for depth motion.
/// Hence hitter near one edge, tee in front of them, and most of the frame left
/// empty for the ball to travel through.
///
/// What it is NOT is a placement check. Two constraints — how tall the hitter
/// is in frame, and where their feet land — cannot pin down three unknowns, so
/// a phone lying in the grass and aimed up matches this outline exactly. See
/// `CameraPose`. The stages measure; this is a picture.
///
/// Every input is a plain value and the whole thing is `Equatable`, so SwiftUI
/// can skip the body when the setup overlay is re-evaluated by a sensor tick
/// that changed none of them. Handed the wizard instead, it would redraw every
/// `Path` here ten times a second, forever, while a hitter stood in frame.
struct FramingGuide: View, Equatable {
    /// Horizontal field of view of the capture format, in degrees.
    var fov: Double
    var isLandscape: Bool
    var screenAspect: Double
    var hitterOnLeft: Bool
    /// The hitter's own height, so the figure is drawn at the size that person
    /// actually appears. It used to be a hardcoded 1.75 m, which made the
    /// outline a target for somebody else.
    var hitterHeightM: Double
    /// Fractions of the frame the control panels cover. Everything drawn here
    /// stays out of them, so nothing has to be nudged by hand when a panel
    /// changes size.
    var rightInset: Double
    var topInset: Double
    var bottomInset: Double
    /// Whether the outline is a target worth matching from this camera.
    var outlineValid: Bool

    var body: some View {
        GeometryReader { geo in
            drawing(in: geo.size)
        }
        // Critical: the whole point of the overlay is that taps reach the
        // preview underneath so the user can tap the ball.
        .allowsHitTesting(false)
    }

    /// Deliberately a plain function rather than a `@ViewBuilder` body: it
    /// declares local helpers and returns explicitly, neither of which a result
    /// builder allows.
    private func drawing(in size: CGSize) -> some View {
        let w = size.width, h = size.height
        let flip = hitterOnLeft ? 1.0 : -1.0
        // Mirror about the centre when the hitter works the other way.
        func px(_ nx: Double) -> Double { (0.5 + (nx - 0.5) * flip) * w }
        func py(_ ny: Double) -> Double { ny * h }
        func pt(_ nx: Double, _ ny: Double) -> CGPoint { CGPoint(x: px(nx), y: py(ny)) }

        // Both the size AND the height in frame come from the real optics.
        // Guessing either would be wrong by a factor of two between portrait
        // and landscape, because filling the screen crops a different amount of
        // the sensor in each.
        let g = geometry()
        let figureH = g.heightFraction
        let figureW = figureH * BatterOutline.aspect * (h / max(1, w))
        // Where a standing hitter's feet actually land, not where a panel
        // leaves room. An earlier version picked this from the panel layout and
        // switched between two values, so the whole guide jumped down the
        // screen the moment the distance card collapsed. The panels are drawn
        // over the guide instead — that is what the z-order is for.
        let footY = g.footFraction
        let headY = footY - figureH
        let centreX = 0.22
        // Contact happens around belt height, a little over half way up.
        let ballY = footY - figureH * 0.46
        let teeX = centreX + figureW * 0.62
        // Where the flight arrow may run.
        let flightEndX = min(0.93, 1 - rightInset - 0.04)
        let arrowTopY = max(topInset + 0.03, ballY - (isLandscape ? 0.30 : 0.22))
        let ink = outlineValid ? Theme.yellow : Theme.fail

        return ZStack {
            BatterOutline()
                .foregroundStyle(ink.opacity(0.9))
                .frame(width: figureW * w, height: figureH * h)
                .scaleEffect(x: flip, y: 1, anchor: .center)
                .position(pt(centreX, (headY + footY) / 2))
                .shadow(color: .black.opacity(0.55), radius: 4)

            // Tee and ball, in front of the hitter at contact height.
            Path { p in
                p.move(to: pt(teeX, footY))
                p.addLine(to: pt(teeX, ballY + 0.012))
            }
            .stroke(ink.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            Circle()
                .strokeBorder(ink, lineWidth: 2.5)
                .frame(width: 0.042 * min(w, h), height: 0.042 * min(w, h))
                .position(pt(teeX, ballY))
            // One short word, clear of the artwork. "BALL ON TEE" was long
            // enough to reach back across the batter's shoulder, and below the
            // ball is where the hitter's caption goes — that pair collided into
            // "STAND HERETEE".
            label("BALL", at: pt(teeX, ballY - 0.075), small: true, ink: ink)

            // Where the ball goes — the whole reason the frame is composed
            // this way, and the thing the old guide never said.
            Path { p in
                p.move(to: pt(teeX + 0.05, ballY - 0.01))
                p.addQuadCurve(to: pt(flightEndX, arrowTopY),
                               control: pt(teeX + (flightEndX - teeX) * 0.55,
                                           arrowTopY + 0.06))
            }
            .stroke(ink.opacity(0.75),
                    style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
            // Arrowhead in points, not in fractions of each axis. Fractions
            // are stretched by the screen's own aspect, which in landscape
            // turned the head into a flat wedge.
            Path { p in
                let tip = pt(flightEndX, arrowTopY)
                let a = 0.032 * min(w, h)
                p.move(to: CGPoint(x: tip.x - flip * a * 1.15, y: tip.y - a * 0.5))
                p.addLine(to: tip)
                p.addLine(to: CGPoint(x: tip.x - flip * a * 0.85, y: tip.y + a * 1.05))
            }
            .stroke(ink,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            // Tucked under the arrowhead, a third of the way along rather than
            // halfway. Halfway and low put it inside the control column once
            // the column was allowed to be short, and above the arc put it on
            // the level bar; between the two is the one band that is clear in
            // every orientation and both panel states.
            label("BALL FLIES THIS WAY",
                  at: pt(teeX + (flightEndX - teeX) * 0.35, arrowTopY + 0.06),
                  ink: ink)

            // Two short lines rather than one long one. A single 30-character
            // caption centred on the batter — who stands near the edge, which
            // is the whole point of the framing — ran off the side of the
            // screen in portrait, and nothing clips or wraps a positioned Text.
            VStack(spacing: 1) {
                Text("STAND HERE")
                    .font(Theme.label(11)).tracking(1.4)
                Text("FACING CAMERA")
                    .font(Theme.label(9)).tracking(1.2)
                    .opacity(0.8)
            }
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(0.9), radius: 3)
            // Clamped above the bottom panel. The FIGURE is never moved to fit
            // — its size and position are the distance check, and shifting it
            // would quietly change what the user is calibrating against — but
            // the caption is only a caption, so it rides up onto the legs
            // rather than disappearing behind a translucent card and reading
            // through the body text underneath it.
            .position(pt(centreX, min(footY + 0.045, 1 - bottomInset - 0.02)))
        }
    }

    /// How a hitter of this height, standing 5.25 m from a level, contact-height
    /// camera appears: how tall, as a fraction of screen height, and where their
    /// feet land in the frame.
    ///
    /// Both numbers come from the same projection, which is the point — the
    /// outline is a picture of one specific shot, so its size and its position
    /// have to be the same claim about the same geometry. The preview fills the
    /// screen and crops the sensor differently in each orientation: in portrait
    /// the screen's long axis spans the camera's full horizontal field of view,
    /// while in landscape the screen's *width* spans it and the visible vertical
    /// angle is narrowed by the screen's aspect ratio. The same person is
    /// therefore about a third of the height in portrait and roughly two thirds
    /// in landscape.
    private func geometry() -> (heightFraction: Double, footFraction: Double) {
        let targetDistanceM = 5.25      // middle of the 4.5-6 m window
        let lensHeightM = CameraPose.idealLensHeightM
        let fallback = (heightFraction: isLandscape ? 0.62 : 0.30,
                        footFraction: isLandscape ? 0.80 : 0.64)
        guard fov > 5 else { return fallback }

        // Through CameraPose, which also places the horizon guide on this same
        // preview. Two framing aids deriving the crop independently is how a
        // future correction moves one and not the other, and the two contradict
        // each other on the one screen meant to be trusted.
        guard let vHalfDeg = CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg: fov, isLandscape: isLandscape,
            screenAspect: screenAspect) else { return fallback }
        let visibleMetres = 2 * targetDistanceM * tan(vHalfDeg * .pi / 180)
        guard visibleMetres > 0.1 else { return fallback }

        // The lens is at contact height, so the ground is `lensHeightM` below
        // the optical axis — which is the centre of the frame.
        let height = min(0.80, max(0.15, hitterHeightM / visibleMetres))
        let foot = min(0.90, max(height + 0.12, 0.5 + lensHeightM / visibleMetres))
        return (height, foot)
    }

    private func label(_ text: String, at point: CGPoint,
                       small: Bool = false, ink: Color) -> some View {
        Text(text)
            .font(Theme.label(small ? 9 : 11))
            .tracking(1.4)
            .foregroundStyle(ink.opacity(small ? 0.7 : 0.9))
            .shadow(color: .black.opacity(0.9), radius: 3)
            .position(point)
    }
}
