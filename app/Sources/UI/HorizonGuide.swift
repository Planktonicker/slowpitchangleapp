// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// An artificial horizon drawn across the live preview.
///
/// The setup screen already had a bubble level and a chip reading "aiming up
/// 31°". Both were true and both were ignored, because they sit in the corner
/// in degrees while the thing being judged is a picture. A line drawn *on the
/// picture*, at the place where level actually falls, is the same reading in
/// the units the eye is already using: put the line on the target band and the
/// camera is level, and you can see at a glance that the phone is aimed at the
/// dirt without knowing what 31° looks like.
///
/// It is derived from the same tilt the maths corrects with, so it cannot
/// drift away from what the app believes. When the camera is aimed so steeply
/// that level is off the bottom or top of the frame, it says exactly that
/// instead of pinning a line to the edge and pretending.
struct HorizonGuide: View {
    /// Positive aiming down, matching `LevelSensor`.
    var tiltDeg: Double?
    /// Half the *visible* vertical field of view, in degrees.
    var visibleVerticalHalfDeg: Double?
    /// Tilt inside this is treated as aimed level.
    var toleranceDeg: Double
    /// Tilt beyond this cannot be honestly rectified.
    var correctableMaxDeg: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if let tiltDeg, let vHalf = visibleVerticalHalfDeg {
                let fraction = CameraPose.horizonFraction(
                    tiltDeg: tiltDeg, visibleVerticalHalfAngleDeg: vHalf)
                let bandLo = CameraPose.horizonFraction(
                    tiltDeg: toleranceDeg, visibleVerticalHalfAngleDeg: vHalf)
                let bandHi = CameraPose.horizonFraction(
                    tiltDeg: -toleranceDeg, visibleVerticalHalfAngleDeg: vHalf)

                ZStack {
                    // The band the horizon should land in. Drawn first and
                    // always, so there is a target on screen even when the
                    // line itself has left the frame — otherwise the one case
                    // that most needs guidance is the one with nothing to aim at.
                    if let lo = bandLo, let hi = bandHi {
                        let top = CGFloat(min(lo, hi)) * h
                        let bottom = CGFloat(max(lo, hi)) * h
                        Rectangle()
                            .fill(colour(for: tiltDeg).opacity(0.12))
                            .frame(width: w, height: max(2, bottom - top))
                            .position(x: w / 2, y: (top + bottom) / 2)
                    }

                    if let fraction, fraction > -0.15, fraction < 1.15 {
                        horizonLine(fraction: fraction, tiltDeg: tiltDeg, w: w, h: h)
                    } else {
                        offFrameMarker(tiltDeg: tiltDeg, w: w, h: h)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Pieces

    private func horizonLine(fraction: Double, tiltDeg: Double,
                             w: CGFloat, h: CGFloat) -> some View {
        // Clamped only for *drawing*: a horizon a little past the edge is
        // still worth showing pressed against it, because the direction it
        // went is the instruction.
        let y = CGFloat(min(max(fraction, 0.01), 0.99)) * h
        let c = colour(for: tiltDeg)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
            }
            .stroke(.black.opacity(0.5), style: StrokeStyle(lineWidth: 4))
            Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
            }
            .stroke(c, style: StrokeStyle(lineWidth: 2, dash: [14, 8]))
            // Gap in the middle so the dashes never cut through the hitter's
            // head, which is where the eye is.
            Text(label(for: tiltDeg))
                .font(Theme.label(10))
                .tracking(1.3)
                .foregroundStyle(c)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .position(x: w * 0.5, y: y)
        }
        .animation(.easeOut(duration: 0.15), value: y)
    }

    /// Level is not in the picture. Say which way it went and by how much —
    /// an edge-pinned line would read as "nearly there".
    private func offFrameMarker(tiltDeg: Double, w: CGFloat, h: CGFloat) -> some View {
        let up = tiltDeg < 0
        return VStack(spacing: 3) {
            Image(systemName: up ? "arrow.down" : "arrow.up")
                .font(.system(size: 17, weight: .black))
            Text(String(format: "LEVEL IS OFF FRAME — AIMING %@ %.0f°",
                        up ? "UP" : "DOWN", abs(tiltDeg)))
                .font(Theme.label(10)).tracking(1.2)
        }
        .foregroundStyle(Theme.fail)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .position(x: w * 0.5, y: up ? h * 0.86 : h * 0.14)
    }

    private func label(for tiltDeg: Double) -> String {
        if abs(tiltDeg) <= toleranceDeg { return "LEVEL ✓" }
        return String(format: "LEVEL — AIMING %@ %.0f°",
                      tiltDeg > 0 ? "DOWN" : "UP", abs(tiltDeg))
    }

    private func colour(for tiltDeg: Double) -> Color {
        if abs(tiltDeg) <= toleranceDeg { return Theme.pass }
        if abs(tiltDeg) <= correctableMaxDeg { return Theme.warn }
        return Theme.fail
    }
}
