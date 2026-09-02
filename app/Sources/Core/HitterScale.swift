// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import Foundation
import ImageIO

/// Camera distance from the hitter's own body, measured off the live pose.
///
/// Swift-only, like `CameraPose`: nothing here is a measurement of a swing, so
/// there is no `sla_common.py` counterpart and no parity fixture. It is
/// *placement* — `ClipAnalyzer` never reads the camera distance, because the
/// scale that reaches a launch angle comes from the ball's own diameter in the
/// flight frames. The two consumers are the sound-travel correction on contact
/// time and the lens-height estimate, and both tolerate ten percent.
///
/// Why the body rather than the ball. At 5.25 m and 68° across 1920 px the ball
/// is about 26 px wide, so two pixels of edge error is 7.7 % of the distance;
/// the nose-to-ankle span of a standing adult is about 410 px, where the same
/// two pixels are 0.5 %. It also needs no prop and no walk out to the tee,
/// which is the actual prize: a solo hitter never has to touch the phone.
///
/// What it costs is an assumption about human proportion, and that assumption
/// is **not validated on this app's footage** — see `docs/VALIDATION.md`.
enum HitterScale {

    /// Nose-to-ankle distance as a fraction of standing height.
    ///
    /// Drillis–Contini segment proportions put the nose at about 0.91 of
    /// stature and the ankle malleolus at about 0.04, so the span between them
    /// is about 0.87. Between individuals this varies by two or three percent,
    /// which lands inside every consumer's tolerance — but it is an assumption
    /// about a population, not a measurement of this hitter, and it has never
    /// been checked against a taped distance. `docs/VALIDATION.md` carries the
    /// row that would correct it.
    static let noseToAnkleStatureFraction = 0.87

    /// Knee angle at or above which a leg counts as straight.
    ///
    /// The gate exists because the fraction above describes a person standing
    /// tall. A batting crouch — 40 to 60 degrees of knee flexion with a forward
    /// lean — shortens the nose-to-ankle span by 7 to 12 %, which would read
    /// back as a camera that had moved a third of a metre. A slight squat of 20
    /// degrees costs about 1 % and is allowed through.
    static let minKneeDeg = 160.0

    /// Spine lean allowed away from vertical, in degrees.
    static let maxSpineLeanDeg = 12.0

    /// Accepted samples needed before the distance locks.
    static let samplesNeeded = 5

    /// How long an accepted sample stays in the window.
    static let windowS: TimeInterval = 3

    /// Heights a person can plausibly type. Outside this the entry is refused
    /// rather than quietly scaled, because the number multiplies straight into
    /// the distance.
    static let heightCmRange: ClosedRange<Double> = 120...230

    /// Why a sample was refused, in the words the panel shows.
    enum Rejection: Equatable {
        /// Not enough of the body is in frame, or the joints do not stack up
        /// the way a standing person's do.
        case outOfFrame
        case knees
        case leaning
    }

    enum Verdict: Equatable {
        case accepted(spanPx: Double)
        case rejected(Rejection)
    }

    // MARK: - Coordinates

    /// Device-normalized joints to upright buffer pixels.
    ///
    /// Multiplied by width and height **before** anything else, and that order
    /// is not cosmetic: the normalized axes are not isotropic. A 16:9 buffer
    /// stretches y against x by 1.78, so any angle or length taken in
    /// normalized space is wrong by the aspect ratio — the same mistake that
    /// once made the plate scale depend on how horizontal the plate happened to
    /// look in frame.
    ///
    /// `nil` in portrait, where there is no upright reading to take.
    static func uprightPixels(_ joints: [PoseJoint: CGPoint],
                              orientation: CGImagePropertyOrientation,
                              widthPx: Double, heightPx: Double) -> [PoseJoint: CGPoint]? {
        guard widthPx > 0, heightPx > 0 else { return nil }
        // Probed once, before the loop, so the answer is the same whether or
        // not the pose happened to come back empty this frame.
        guard CameraPose.uprightBufferPoint(.zero, orientation: orientation,
                                            width: widthPx, height: heightPx) != nil
        else { return nil }
        var out: [PoseJoint: CGPoint] = [:]
        out.reserveCapacity(joints.count)
        for (joint, p) in joints {
            let px = CGPoint(x: Double(p.x) * widthPx, y: Double(p.y) * heightPx)
            guard let upright = CameraPose.uprightBufferPoint(
                px, orientation: orientation, width: widthPx, height: heightPx)
            else { return nil }
            out[joint] = upright
        }
        return out
    }

    // MARK: - The gate

    /// Judge one pose: is this person standing tall enough to measure, and how
    /// long is their nose-to-ankle span in the level camera's view?
    ///
    /// **Every** joint is rectified for camera tilt first, before any angle or
    /// length is taken. Rectifying only the span would leave the knee and spine
    /// gates reading a projected picture while the measurement read a level
    /// one — two frames, one verdict, and no way to tell afterwards which had
    /// been used. Angles and span share one frame or the answer means nothing.
    static func evaluate(upright: [PoseJoint: CGPoint], tiltDeg: Double,
                         focalPx: Double, cx: Double, cy: Double) -> Verdict {
        var r: [PoseJoint: CGPoint] = [:]
        r.reserveCapacity(upright.count)
        for (joint, p) in upright {
            let t = TiltRectifier.rectify(x: Double(p.x), y: Double(p.y),
                                          tiltDeg: tiltDeg, focalPx: focalPx,
                                          cx: cx, cy: cy)
            r[joint] = CGPoint(x: t.x, y: t.y)
        }

        guard let nose = r[.nose],
              let leftHip = r[.leftHip], let rightHip = r[.rightHip],
              let leftShoulder = r[.leftShoulder], let rightShoulder = r[.rightShoulder]
        else { return .rejected(.outOfFrame) }

        let ankles = [r[.leftAnkle], r[.rightAnkle]].compactMap { $0 }
        guard !ankles.isEmpty else { return .rejected(.outOfFrame) }

        let midHip = midpoint(leftHip, rightHip)
        let midShoulder = midpoint(leftShoulder, rightShoulder)
        // y is down. A standing person stacks nose above shoulders above hips;
        // anything else is the pose model having attached joints to scenery, or
        // a hitter bent double, and neither is a person to measure.
        guard Double(nose.y) < Double(midShoulder.y),
              Double(midShoulder.y) < Double(midHip.y) else { return .rejected(.outOfFrame) }

        func kneeAngle(hip: PoseJoint, knee: PoseJoint, ankle: PoseJoint) -> Double? {
            guard let h = r[hip], let k = r[knee], let a = r[ankle] else { return nil }
            return BodyAnalyzer.sagittalAngleDeg(a: h, b: k, c: a)
        }
        let knees = [kneeAngle(hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle),
                     kneeAngle(hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle)]
            .compactMap { $0 }
        // At least one complete leg, and no NaN. `sagittalAngleDeg` returns NaN
        // for coincident points rather than a plausible zero, so a NaN here is
        // a lost joint, not a folded one.
        guard !knees.isEmpty, knees.allSatisfy({ $0.isFinite }) else {
            return .rejected(.outOfFrame)
        }
        guard knees.allSatisfy({ $0 >= minKneeDeg }) else { return .rejected(.knees) }

        let lean = BodyAnalyzer.spineTiltDeg(hip: midHip, shoulder: midShoulder)
        guard lean.isFinite else { return .rejected(.outOfFrame) }
        guard abs(lean) <= maxSpineLeanDeg else { return .rejected(.leaning) }

        let ankleX = ankles.reduce(0.0) { $0 + Double($1.x) } / Double(ankles.count)
        let ankleY = ankles.reduce(0.0) { $0 + Double($1.y) } / Double(ankles.count)
        let span = hypot(Double(nose.x) - ankleX, Double(nose.y) - ankleY)
        guard span.isFinite, span > 1 else { return .rejected(.outOfFrame) }
        return .accepted(spanPx: span)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (Double(a.x) + Double(b.x)) / 2, y: (Double(a.y) + Double(b.y)) / 2)
    }

    // MARK: - Optics

    /// Pixels per metre implied by a nose-to-ankle span on a hitter of this
    /// height. The scale is only true in the hitter's own plane, which is
    /// roughly 0.7 m behind the plate from a camera on the open side.
    static func pxPerM(spanPx: Double, hitterHeightM: Double) -> Double {
        let reference = hitterHeightM * noseToAnkleStatureFraction
        guard reference > 0 else { return 0 }
        return spanPx / reference
    }

    /// `d = focal × H_span / span_px`.
    static func distanceM(spanPx: Double, hitterHeightM: Double, focalPx: Double) -> Double? {
        guard spanPx > 1, focalPx > 0, hitterHeightM > 0 else { return nil }
        let scale = pxPerM(spanPx: spanPx, hitterHeightM: hitterHeightM)
        guard scale > 0 else { return nil }
        let d = focalPx / scale
        guard d.isFinite else { return nil }
        return d
    }

    /// Median rather than mean. One frame where the pose model puts an ankle on
    /// the fence is an outlier of arbitrary size, and a mean carries it into
    /// the answer in proportion to how wrong it was.
    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let mid = s.count / 2
        if s.count % 2 == 1 { return s[mid] }
        return (s[mid - 1] + s[mid]) / 2
    }

    // MARK: - Sampling

    /// One accepted span and when it was taken.
    ///
    /// A struct rather than the tuple this started as: an array of labelled
    /// tuples is not `Equatable`, and the sampler has to be, so the wizard's
    /// state can be compared in a test without reaching inside it.
    struct Sample: Equatable {
        var t: TimeInterval
        var spanPx: Double
    }

    /// A rolling window of accepted samples.
    ///
    /// A value type on purpose: the lock decision is then testable without
    /// standing up the `@MainActor` wizard, a camera, or a pose model.
    struct Sampler: Equatable {
        private(set) var samples: [Sample] = []

        init() {}

        mutating func add(spanPx: Double, at t: TimeInterval) {
            samples.append(Sample(t: t, spanPx: spanPx))
            samples.removeAll { t - $0.t > HitterScale.windowS }
        }

        func count(at t: TimeInterval) -> Int { live(at: t).count }

        /// `nil` until the window holds enough samples. Five over three seconds
        /// is about half a second of standing still at the pose model's ~10 Hz,
        /// which is short enough not to be a chore and long enough that a
        /// single bad inference cannot carry the lock on its own.
        func medianIfReady(at t: TimeInterval) -> Double? {
            let spans = live(at: t)
            guard spans.count >= HitterScale.samplesNeeded else { return nil }
            return HitterScale.median(spans)
        }

        mutating func reset() { samples.removeAll() }

        private func live(at t: TimeInterval) -> [Double] {
            samples.filter { t - $0.t <= HitterScale.windowS }.map { $0.spanPx }
        }
    }
}
