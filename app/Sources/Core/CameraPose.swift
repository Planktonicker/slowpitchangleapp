// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Where the camera actually is, worked backwards from what it can see.
///
/// This exists because the on-screen batter outline was a lie by omission.
/// It asks the user to match two things — how *tall* the hitter is in frame
/// and where their *feet* land — and it is drawn for a level lens at contact
/// height, 5.25 m away. But two constraints cannot pin down three unknowns.
/// Distance sets the height in frame; tilt slides the whole picture up or
/// down. So for *any* lens height at all, including a phone lying flat on the
/// grass, there is a distance and a tilt that make the hitter fit the outline
/// perfectly. Someone who matched it exactly could still be filming from the
/// ground, and the app would show them a confident yellow figure while doing
/// it. That is not a hypothetical: it is the first real clip this app was
/// ever given.
///
/// The missing constraint is not in the picture — it is in the phone. Tilt
/// comes from the IMU, distance from the tap-the-ball measurement, and the
/// hitter's feet from the live pose. Three knowns, one unknown, and the lens
/// height falls out. Nothing here touches a measurement: it is what the setup
/// screen needs to stop giving confident advice about a camera it never
/// checked.
///
/// Sign convention throughout, matching `LevelSensor` and
/// `PlacementWizard.Placement`: **`tiltDeg` is positive aiming DOWN.**
/// Vertical screen fractions are 0 at the top, 1 at the bottom, so 0.5 is the
/// optical axis.
enum CameraPose {

    /// Half the vertical field of view of the capture buffer.
    ///
    /// `fieldOfViewDeg` from `AVCaptureDeviceFormat` is the *horizontal* angle,
    /// so the vertical one has to come off the buffer's own aspect ratio rather
    /// than being assumed — a 1920x1080 frame and a 1280x720 frame share it,
    /// but a 4:3 photo format does not.
    static func verticalHalfAngleDeg(horizontalFovDeg: Double,
                                     frameAspect: Double) -> Double? {
        guard horizontalFovDeg > 1, horizontalFovDeg < 179, frameAspect > 0.05 else { return nil }
        let hHalf = horizontalFovDeg * .pi / 360
        return atan(tan(hHalf) / frameAspect) * 180 / .pi
    }

    /// Half the vertical field of view *visible on screen*, which is a
    /// different angle from the one above whenever the preview crops.
    ///
    /// The preview fills the screen, so it throws away whichever axis does not
    /// fit. In portrait the screen's long axis carries the camera's full
    /// horizontal sweep; in landscape the screen's *width* carries it and the
    /// visible vertical angle is narrowed by the screen's aspect. Getting this
    /// wrong puts the drawn horizon in the wrong place by a factor of two
    /// between orientations, which is exactly the error the batter outline
    /// used to make before its geometry was derived rather than guessed.
    static func visibleVerticalHalfAngleDeg(horizontalFovDeg: Double,
                                            isLandscape: Bool,
                                            screenAspect: Double) -> Double? {
        guard horizontalFovDeg > 1, horizontalFovDeg < 179 else { return nil }
        let hHalf = horizontalFovDeg * .pi / 360
        guard isLandscape else { return hHalf * 180 / .pi }
        return atan(tan(hHalf) / max(0.1, screenAspect)) * 180 / .pi
    }

    /// Where the world's horizon — the level plane through the lens — crosses
    /// the frame, as a fraction from the top.
    ///
    /// Deliberately **not clamped**: a value outside 0...1 is the interesting
    /// case, meaning the camera is aimed so far off level that level is not in
    /// the picture at all, and the caller wants to say so rather than draw a
    /// line pinned to the edge as though it were a reading.
    ///
    /// Aiming down pushes the horizon *up* the frame, which is the way round
    /// that surprises people: point at the ground and you see more ground, so
    /// the sky is squeezed into the top.
    static func horizonFraction(tiltDeg: Double,
                                visibleVerticalHalfAngleDeg vHalf: Double) -> Double? {
        guard vHalf > 0.5, vHalf < 89 else { return nil }
        let t = tiltDeg * .pi / 180
        // Beyond the horizontal the projection flips through infinity; there
        // is no line to draw and no honest way to fake one.
        guard abs(tiltDeg) < 85 else { return nil }
        return 0.5 - tan(t) / (2 * tan(vHalf * .pi / 180))
    }

    /// The tilt implied by a horizon at this height in the frame — the inverse
    /// of `horizonFraction`.
    ///
    /// This is how a clip the app did not film can still be corrected. Tilt
    /// normally comes from the IMU at capture time, and an imported clip has
    /// none: it was filmed by the stock Camera app, which records no such
    /// thing. But the horizon is *in the picture*, and where it sits is a
    /// direct reading of where the lens was pointing. Somebody dragging a line
    /// onto the tree line is measuring the same angle the accelerometer would
    /// have, by hand.
    ///
    /// Roughly right is worth a great deal here. The rectification degrades
    /// smoothly — it is a homography in the tilt angle, with no cliff — so a
    /// horizon placed a few degrees out leaves a reading far closer to the
    /// truth than assuming a level camera that was never level.
    static func tiltDeg(forHorizonFraction fraction: Double,
                        visibleVerticalHalfAngleDeg vHalf: Double) -> Double? {
        guard vHalf > 0.5, vHalf < 89, fraction.isFinite else { return nil }
        let t = atan((0.5 - fraction) * 2 * tan(vHalf * .pi / 180))
        return t * 180 / .pi
    }

    /// How high the lens is above the ground, from where the hitter's feet
    /// land in the frame.
    ///
    /// The feet stand on the ground at `distanceM`, so their depression below
    /// the level plane is `atan(height / distance)` — and the frame shows that
    /// depression directly, once the optical axis has been swung by the tilt.
    /// Inverting gives the height.
    ///
    /// - Parameters:
    ///   - feetFraction: the feet's vertical position in the *capture buffer*,
    ///     0 at the top and 1 at the bottom.
    ///   - vHalf: half the vertical field of view of that same buffer — the
    ///     buffer's, not the screen's, because that is the frame the pose came
    ///     back in.
    ///
    /// Returns `nil` when the answer is not a height: feet at or above the
    /// horizon put the ground above eye level, which means the tilt reading,
    /// the distance or the pose disagree with each other, and a made-up number
    /// would be worse than none.
    static func lensHeightM(feetFraction: Double,
                            distanceM: Double,
                            tiltDeg: Double,
                            verticalHalfAngleDeg vHalf: Double) -> Double? {
        guard distanceM > 0.3, distanceM < 60, vHalf > 0.5, vHalf < 89 else { return nil }
        guard feetFraction.isFinite, feetFraction >= -0.5, feetFraction <= 1.5 else { return nil }
        let t = tiltDeg * .pi / 180
        let offAxis = atan((0.5 - feetFraction) * 2 * tan(vHalf * .pi / 180))
        let depression = t - offAxis
        // Below the horizon by a real angle, or it is not ground being seen.
        guard depression > 0.002 else { return nil }
        let h = distanceM * tan(depression)
        guard h.isFinite, h < 12 else { return nil }
        return h
    }

    /// Contact height, and the height the batter outline is drawn for.
    static let idealLensHeightM = 1.1

    /// How far the lens may sit from contact height before the framing stops
    /// being the one the outline describes.
    ///
    /// Generous on purpose. A level camera low to the ground sees the same
    /// geometry as a level camera at belt height — the ball just rides higher
    /// in the picture — so height alone costs no accuracy. What it costs is
    /// the *outline*, which stops being a valid target, and the temptation it
    /// creates: someone whose tripod is too short aims the phone up to put the
    /// hitter back inside the figure, and aiming up is what actually breaks
    /// the measurement.
    static let lensHeightToleranceM = 0.55

    /// Whether the batter outline is currently a target worth matching.
    ///
    /// It is drawn for one specific camera — level, at contact height — so it
    /// only means anything when the camera is that camera. Everywhere else it
    /// is decoration that looks like instruction.
    static func outlineIsValid(tiltDeg: Double?,
                               tiltToleranceDeg: Double,
                               lensHeightM: Double?) -> Bool {
        guard let tiltDeg, abs(tiltDeg) <= tiltToleranceDeg else { return false }
        // An unmeasured height is not a failed one: the pose or the distance
        // may simply not be available yet, and refusing to draw the outline
        // until a hitter is standing in it would be a deadlock.
        guard let lensHeightM else { return true }
        return abs(lensHeightM - idealLensHeightM) <= lensHeightToleranceM
    }
}
