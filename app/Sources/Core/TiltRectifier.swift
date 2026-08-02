// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Undoes camera tilt before the measurement runs.
///
/// Line-for-line port of `focal_px_from_fov` / `rectify_tilt_point` /
/// `rectify_tilt` in `spike/sla_common.py`, pinned by `ParityTests`. Change the
/// Python first, regenerate the fixtures, then mirror here.
///
/// Why this exists: every number the app reports assumes the sensor plane is
/// parallel to the plane the ball flies in, because only then does one vertical
/// pixel mean the same number of vertical metres everywhere in frame.
///
/// A tripod that cannot reach contact height does **not** break that. Sliding a
/// level camera down its legs is a pure translation of the viewpoint — the ball
/// lands higher in frame at the same scale, and nothing needs correcting.
/// Aiming the camera *up* to compensate is what breaks it, and that part is a
/// pure rotation of a pinhole camera about its own optical centre. Tilted and
/// level views of the same world are then related by a homography that depends
/// on nothing but the tilt angle and the focal length: the IMU measures the
/// first, the capture format's field of view gives the second.
///
/// See the derivation comment in `sla_common.py`; the short version is, with
/// image coordinates measured from the principal point and
/// `D = f·cos t − v·sin t`:
///
///     u' = f·u / D
///     v' = f·(v·cos t + f·sin t) / D
///     d' = d·f / D
///
/// The diameter rectifies too, and that is not a detail: the diameter is what
/// sets metres-per-pixel, so correcting the geometry while leaving the ruler
/// alone would trade one error for another.
enum TiltRectifier {

    /// Pinhole focal length in pixels from the capture format's horizontal
    /// field of view. Returns 0 for unusable inputs, which every caller reads
    /// as "no rectification possible".
    static func focalPx(widthPx: Double, fovDeg: Double) -> Double {
        guard widthPx > 0, fovDeg > 0, fovDeg < 180 else { return 0 }
        return (widthPx / 2) / tan(fovDeg * Double.pi / 180 / 2)
    }

    /// Maps one image point into the virtual level camera.
    ///
    /// `magnification` is `du'/du` at that point: multiply any length measured
    /// there — a ball diameter — by it.
    ///
    /// `tiltDeg` is positive when the camera aims **down**, matching the
    /// convention `LevelSensor` publishes.
    static func rectify(x: Double, y: Double,
                        tiltDeg: Double, focalPx: Double,
                        cx: Double, cy: Double) -> (x: Double, y: Double, magnification: Double) {
        guard tiltDeg != 0, focalPx > 0 else { return (x, y, 1) }
        let t = tiltDeg * Double.pi / 180
        let cosT = cos(t), sinT = sin(t)
        let u = x - cx
        let v = y - cy
        let d = focalPx * cosT - v * sinT
        // At or past the rectified view's horizon. Only reachable at tilts far
        // beyond anything a tripod produces, and there is nothing sensible to
        // map such a point to, so leave it where it is.
        guard d > 0 else { return (x, y, 1) }
        let mag = focalPx / d
        return (cx + u * mag,
                cy + (v * cosT + focalPx * sinT) * mag,
                mag)
    }

    /// Rectifies a whole ball track. Frame index, time and area carry through
    /// untouched — area only ever fed candidate ranking, which happened long
    /// before this.
    static func rectify(track: [BallObservation],
                        tiltDeg: Double, focalPx: Double,
                        cx: Double, cy: Double) -> [BallObservation] {
        guard tiltDeg != 0, focalPx > 0 else { return track }
        return track.map { o in
            let r = rectify(x: o.x, y: o.y, tiltDeg: tiltDeg, focalPx: focalPx, cx: cx, cy: cy)
            return BallObservation(frame: o.frame, t: o.t, x: r.x, y: r.y,
                                   diameterPx: o.diameterPx * r.magnification,
                                   areaPx: o.areaPx)
        }
    }
}
