// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Physical and tuning constants, ported from `spike/sla_common.py`.
///
/// `sla_common.py` is the single source of truth. Every value here has a
/// counterpart there, and `SwingLabTests/ParityTests` asserts they still
/// agree against `app/Tests/Fixtures/parity.json` (regenerate with
/// `python spike/gen_parity_fixtures.py`). Do not "improve" a number here
/// without changing the Python and regenerating the fixtures.
enum SLA {

    // MARK: - Physical constants

    static let g = 9.80665                                  // m/s^2
    static let ballCircumferenceM = 12.0 * 0.0254           // 12 in slow-pitch softball
    static let ballDiameterM = ballCircumferenceM / Double.pi   // 0.09702 m — 9.7 cm across
    static let ballMassKg = 0.190                           // 6.25-7.0 oz ball -> ~190 g
    static let airDensity = 1.225                           // kg/m^3, sea level
    static let dragCd = 0.47                                // smooth-ish sphere
    static let mphPerMps = 2.23694

    /// Drag coefficient bundled with the ball's frontal area and mass: the
    /// `k/m` that appears throughout the drag model. A softball flies at
    /// roughly its terminal velocity (~30 m/s), so this term is comparable to
    /// gravity and can never be dropped.
    static let kOverM = 0.5 * airDensity * dragCd * Double.pi
        * (ballDiameterM / 2) * (ballDiameterM / 2) / ballMassKg

    // MARK: - Detection defaults

    /// Optic yellow in OpenCV HSV convention (H: 0-179, S/V: 0-255).
    ///
    /// Still generous — tighten per venue in Settings — but no longer wide
    /// enough to swallow grass, which the first window did. Measured on real
    /// field footage: sunlit grass sits at about H36 S89 V133, and the old
    /// ceiling (H<=48, S>=70, V>=120) admitted it wholesale. 18% of the frame
    /// passed the colour test and the largest "ball-coloured" blob in the
    /// picture was the lawn, with the actual ball a speck inside the noise.
    ///
    /// The ball measured H29-34, S~170, V~240. Saturation is the separator that
    /// costs nothing: fluorescent yellow is far more saturated than any
    /// vegetation, so S>=100 splits them cleanly while H<=40 still clears real
    /// optic yellow (~22-35 in this convention) with margin.
    static let hsvLoDefault = HSVBounds(h: 18, s: 100, v: 120)
    static let hsvHiDefault = HSVBounds(h: 40, s: 255, v: 255)

    /// Fluorescent pink/orange barrel tape (Phase 3 bat tracking).
    static let batHSVLoDefault = HSVBounds(h: 160, s: 90, v: 110)
    static let batHSVHiDefault = HSVBounds(h: 179, s: 255, v: 255)

    static let minRadiusPxDefault = 4.0
    static let maxRadiusPxDefault = 60.0

    /// Sub-pixel diameter profile sampling step. See `BallDetector`: mask
    /// contours over-read the compression halo around the ball by ~6%, which
    /// lands directly in exit velocity, so the reference measurement samples
    /// the intensity profile instead of trusting the threshold.
    static let diameterProfileStepPx = 0.25

    // MARK: - Analysis defaults

    static let velocityWindowS = 0.12      // LA/EV fit window at contact (~29 frames @240)
    static let gravityWindowS = 0.35       // longer: curvature needs time to accumulate
    static let minTrackFrames = 8

    /// How directed a track has to be before it is treated as a flight: the
    /// straight line from first sighting to last, over the distance actually
    /// walked. A ball in flight is essentially 1.0 — it curves, but it never
    /// turns back. Clutter that is merely being re-detected in place scores
    /// near 0.
    ///
    /// 0.55 is deliberately loose. It has to survive a genuine flight that is
    /// partly occluded, detected raggedly, or caught near its apex where the
    /// horizontal motion is smallest, and the cost of being loose is only that
    /// a wandering track has to wander a bit more obviously before it goes.
    static let trackStraightnessMin = 0.55

    /// Stitching: re-joining fragments of one flight that detection gaps broke
    /// apart. See `stitch_tracks` in `sla_common.py` for the full reasoning;
    /// the short version is that a ball crossing a busy background drops out
    /// of detection for longer than the builder can coast, each burst becomes
    /// its own short track, and on real footage every piece of the hit died on
    /// the minimum-length gate while a slow landing bounce won selection.
    static let stitchMaxGapS = 0.10
    static let stitchBaseTolPx = 30.0
    static let stitchTolPxPerS = 0.35
    static let stitchMaxAngleDeg = 40.0
    /// Velocity agreement bounded by physics rather than taste: over the gap,
    /// gravity can change a real flight's velocity by g·gap and no more. The
    /// old 2x-and-40-degree pair was ~two orders of magnitude looser and
    /// admitted a passing bird, a shallow bounce, and an eight-burst
    /// 160-degree arc. See `_stitch_error` in `spike/sla_common.py`.
    static let stitchAccelK = 3.0
    static let stitchVelocityNoisePxS = 400.0
    /// Points in the least-squares endpoint-velocity window. Enough to average
    /// detection noise down; few enough to stay local on a curving track.
    static let stitchVelocityWindow = 6

    // MARK: - Seeded tracking
    //
    /// Following the ball out from a point a human pointed at. See
    /// `track_from_seed` in `spike/sla_common.py`: automatic SELECTION is the
    /// part that cannot be made reliable on cluttered footage, and it is the
    /// part one tap settles outright. The gates are looser than the generic
    /// builder's because the expensive ambiguity — which object is the ball —
    /// is already answered.
    /// How near the tap a candidate must be to BE the ball — frame-relative,
    /// because a fixed 45 px is a target 14 POINTS wide on a phone while a
    /// fingertip is about 44. See `seed_search_radius_px` in sla_common.py.
    static let seedSearchRadiusPx = 45.0
    static let seedSearchRadiusFrac = 0.06

    /// Association may not reverse a moving track — see `TrackBuilder`. The
    /// guard that keeps the incoming pitch out of the outgoing hit.
    static let buildMaxTurnDeg = 60.0
    /// Per FRAME, not per second: centroid noise is a fixed number of
    /// pixels between frames however fast the camera runs.
    static let buildTurnMinStepPx = 5.0

    /// Motion gating — see `MotionMask`. The largest single source of false
    /// candidates on real footage is stationary scenery that shares the ball's
    /// colour; a ball is the one ball-coloured thing that moves.
    static let motionDiffThreshold = 18.0
    static let motionDilatePx = 3.0

    static func seedSearchRadius(frameWidthPx: Double) -> Double {
        max(seedSearchRadiusPx, frameWidthPx * seedSearchRadiusFrac)
    }
    static let seedGateBasePx = 70.0
    static let seedGatePredictedPx = 22.0
    static let seedGateSpeedMult = 0.6
    static let seedMaxCoastFrames = 8
    static let seedSpeedRatioMax = 1.8
    static let seedMaxTurnDeg = 25.0
    static let seedOutlierMinPx = 4.0
    static let seedOutlierSigma = 3.0
    static let minGravityTrackS = 0.20     // below this the gravity scale is unreliable
    static let scaleDisagreeTol = 0.08     // G2 tolerance
    static let diameterDriftTol = 0.10     // depth-motion (cosine error) flag threshold
    static let residualTolPx = 3.0

    // MARK: - Contact-trigger calibration

    /// Where between the venue's noise floor and its quietest hit to put the
    /// threshold. Below the midpoint on purpose: a missed swing is lost data,
    /// while a false trigger is a clip discarded in review, so the asymmetry
    /// favours firing.
    static let triggerMarginFraction = 0.35

    /// Separation below which no threshold is trustworthy — the loudest
    /// background and the quietest hit overlap closely enough that any line
    /// between them will both miss swings and fire on noise.
    static let triggerMinSeparationDb = 6.0

    /// Threshold, separation and verdict from one venue measurement. Port of
    /// `suggest_trigger_db`.
    ///
    /// `backgroundPeakDb` is the LOUDEST the background reached, not its
    /// average: the threshold has to clear the worst moment, because a single
    /// passing car is what produces a false trigger and an average hides it.
    /// `quietestHitDb` is the same reasoning inverted — the threshold has to
    /// catch the softest swing, not the best one.
    static func suggestTriggerDb(backgroundPeakDb: Double,
                                 quietestHitDb: Double)
        -> (thresholdDb: Double, separationDb: Double, verdict: TriggerCalibrationVerdict) {
        let separation = quietestHitDb - backgroundPeakDb
        var threshold = backgroundPeakDb + triggerMarginFraction * separation
        // Never below the floor it is meant to sit above: a negative separation
        // would otherwise put the threshold under the background and fire
        // continuously.
        threshold = max(threshold, backgroundPeakDb + 1.0)

        let verdict: TriggerCalibrationVerdict
        if separation < triggerMinSeparationDb {
            verdict = .unusable
        } else if separation < 2 * triggerMinSeparationDb {
            verdict = .marginal
        } else {
            verdict = .good
        }
        return (threshold, separation, verdict)
    }

    // MARK: - Body pose

    /// Below this Vision confidence a joint is treated as absent rather than as
    /// a guess. Apple's pose model reports low-confidence joints at
    /// plausible-looking positions, so using them silently would produce a body
    /// metric with no body behind it.
    static let jointConfidenceMin = 0.30

    /// Head movement beyond this is almost certainly the pose model losing the
    /// hitter rather than the hitter moving. A swing that really moved the head
    /// 40 cm toward the pitcher would be a lunge past any coaching reference;
    /// the far likelier explanation is a joint jumping to the umpire.
    static let headDriftImplausibleM = 0.40

    /// Beyond this much camera tilt the rectification is still applied, but the
    /// reading stays flagged: the homography is exact for a pinhole and lens
    /// distortion is not, and a big tilt is exactly what pushes the flight into
    /// the distorted part of the frame.
    static let tiltCorrectableMaxDeg = 20.0

    // MARK: - Capture defaults

    static let targetFPS = 240.0
    static let targetWidth = 1920
    static let targetHeight = 1080
    /// Seconds of video kept before the contact trigger fires. The bat is
    /// visible in this window, which is what Phase 3 attack angle needs.
    /// Pre-roll covers the swing, not just the barrel: load and stride are
    /// what the body metrics are measured from, and the incoming pitch is what
    /// independently confirms the contact instant — on a field clip the pitch
    /// track and the hit track cross within 4 ms of each other, which is a
    /// tighter contact time than the audio gives.
    static let preRollS = 1.50
    /// Post-roll only has to outlast the ball's time in frame. Measured on two
    /// field clips the flight lasted 79 ms and 146 ms; two seconds is generous
    /// margin, and every second past that is storage bought for nothing —
    /// at 240fps it is 240 more frames of an empty field.
    static let postRollS = 2.00
    /// The pre-roll ring is sized to this, so the setting can be raised
    /// mid-session without tearing down a running capture.
    static let maxPreRollS = 3.0
    /// Contact impulse must stand this far above the rolling noise floor.
    /// Matches `PASS_DB` in `spike/check_audio_trigger.py` (G5).
    static let triggerDb = 15.0

    // MARK: - Bat / contact quality (Phase 3+)

    /// Smash-factor (collision-efficiency) reference band, matching
    /// `sla_common.py`. Coaching references (Driveline: good ~1.35-1.40, poor
    /// below ~1.20), NOT slow-pitch population norms — used only to colour a
    /// reading. See `docs/BIOMECHANICS.md` for why these are guidance, not gates.
    static let smashPoorBelow = 1.20
    static let smashGoodLo = 1.35
    static let smashGoodHi = 1.45

    /// Slow-pitch line-drive launch window (degrees). MLB's 25-35° guidance
    /// misleads slow-pitch hitters — a heavier ball at low bat speed makes high
    /// fly balls die. Guidance for display, not a validated norm.
    static let slowpitchLaunchLo = 10.0
    static let slowpitchLaunchHi = 25.0

    /// Barrel-tape speed at contact in m/s, using the ball-size scale the ball
    /// pipeline already trusts. Port of `bat_speed_mps`.
    static func batSpeedMps(vxPxS: Double, vyPxS: Double, scaleMPerPx: Double) -> Double {
        (vxPxS * vxPxS + vyPxS * vyPxS).squareRoot() * scaleMPerPx
    }

    /// Exit velocity ÷ bat speed — collision efficiency. `nil` when the bat was
    /// not tracked (non-positive speed). Port of `smash_factor`.
    static func smashFactor(exitVeloMps: Double, batSpeedMps: Double) -> Double? {
        batSpeedMps <= 0 ? nil : exitVeloMps / batSpeedMps
    }

    /// True when a launch angle sits in the slow-pitch line-drive band.
    static func inSlowpitchLaunchWindow(_ launchAngleDeg: Double) -> Bool {
        launchAngleDeg >= slowpitchLaunchLo && launchAngleDeg <= slowpitchLaunchHi
    }

    // MARK: - Contact offset ("undercut")

    /// Max legal slow-pitch barrel (2.25 in). Matches `sla_common.py`.
    static let batBarrelDiameterM = 2.25 * 0.0254   // 57 mm

    /// Centres farther apart than the two radii cannot have touched: the tape
    /// was not at the contact point, or a fit went wrong. Reading discarded.
    static let contactPlausibleM = (ballDiameterM + batBarrelDiameterM) / 2

    /// Undercut bands (metres), positive = barrel centre BELOW ball centre.
    /// Nathan's collision model puts max-carry undercut around 13-30 mm;
    /// coaching guidance for labels, not validated slow-pitch norms.
    static let undercutToppedBelowM = -0.006
    static let undercutCenteredMaxM = 0.010
    static let undercutCarryMaxM = 0.030

    /// Vertical offset of barrel centre below ball centre at contact, metres.
    /// Image y grows down, so bat below ball -> positive -> backspin/loft.
    /// Port of `undercut_m`.
    static func undercutM(ballY0Px: Double, batY0Px: Double,
                          scaleMPerPx: Double) -> Double {
        (batY0Px - ballY0Px) * scaleMPerPx
    }
}

/// Where the barrel met the ball vertically. Raw values match the strings
/// returned by `contact_quality` in `sla_common.py` so fixtures compare
/// directly. This is the side-view-honest half of b4-app's Bat Contact Point:
/// knob-to-tip position is foreshortened from a side-on camera, but the
/// vertical miss — the thing that decides topped vs flush vs popup — is
/// exactly what a side view measures well.
enum ContactQuality: String, Codable, Sendable {
    case unknown, implausible, topped, centered
    case underCarry = "under_carry"
    case underPopup = "under_popup"

    init(undercutM u: Double?) {
        guard let u else { self = .unknown; return }
        if abs(u) > SLA.contactPlausibleM { self = .implausible }
        else if u < SLA.undercutToppedBelowM { self = .topped }
        else if u <= SLA.undercutCenteredMaxM { self = .centered }
        else if u <= SLA.undercutCarryMaxM { self = .underCarry }
        else { self = .underPopup }
    }

    var label: String {
        switch self {
        case .unknown: return "—"
        case .implausible: return "Not readable"
        case .topped: return "Over the ball"
        case .centered: return "Centered"
        case .underCarry: return "Under it — carry"
        case .underPopup: return "Way under it"
        }
    }
}

/// Coarse label for a smash-factor reading. Raw values match the strings
/// returned by `smash_quality` in `sla_common.py` so fixtures compare directly.
/// "flush" borrows b4-app's framing for a well-struck ball.
enum SmashQuality: String, Codable, Sendable {
    case unknown, poor, fair, flush

    init(smash: Double?) {
        guard let s = smash else { self = .unknown; return }
        if s < SLA.smashPoorBelow { self = .poor }
        else if s < SLA.smashGoodLo { self = .fair }
        else { self = .flush }
    }

    var label: String {
        switch self {
        case .unknown: return "—"
        case .poor: return "Poor contact"
        case .fair: return "Fair contact"
        case .flush: return "Flush"
        }
    }
}

/// A point in OpenCV's HSV convention, so venue tuning transfers directly
/// between the Python spike (`--hsv-lo/--hsv-hi`) and the app.
struct HSVBounds: Equatable, Codable, Sendable {
    var h: Double   // 0..179
    var s: Double   // 0..255
    var v: Double   // 0..255
}

/// Confidence flags. Raw values match the string constants in
/// `sla_common.py` so device CSVs and Python CSVs are directly comparable.
enum SwingFlag: String, Codable, CaseIterable, Sendable {
    case shortTrack = "SHORT_TRACK"
    case noGravityCheck = "NO_GRAVITY_CHECK"
    case scaleDisagree = "SCALE_DISAGREE"
    case depthMotion = "DEPTH_MOTION"
    case highResidual = "HIGH_RESIDUAL"

    /// Plain-language explanation shown next to a low-confidence reading.
    var explanation: String {
        switch self {
        case .shortTrack:
            return "The ball was only tracked for a handful of frames. Numbers are a rough estimate."
        case .noGravityCheck:
            return "Flight was too brief to cross-check scale against gravity. Exit velocity rests on ball size alone."
        case .scaleDisagree:
            return "The two independent scale estimates disagree. Something is off — check camera distance and that the ball is in focus."
        case .depthMotion:
            return "The ball changed size through the track, so it flew toward or away from the camera. Stand more square to the line of play."
        case .highResidual:
            return "The tracked path was jittery. Likely a busy background or a partly hidden ball."
        }
    }
}

/// How well a venue separates contact from its own noise. Raw values match the
/// strings `suggest_trigger_db` returns, so fixtures compare directly.
enum TriggerCalibrationVerdict: String, Codable, Sendable {
    case good, marginal, unusable

    var label: String {
        switch self {
        case .good: return "Clear"
        case .marginal: return "Workable"
        case .unusable: return "Too noisy"
        }
    }

    /// Said plainly, because the honest answer for `unusable` is "use the
    /// manual button", not a threshold dressed up as a solution.
    var advice: String {
        switch self {
        case .good:
            return "Contact stands well clear of the background here. The trigger should be reliable."
        case .marginal:
            return "Contact is only just above the background. Expect the odd missed swing or false start — keep an eye on the ignored count."
        case .unusable:
            return "Contact is not louder than this venue's own noise, so no threshold can separate them. Use the manual button, or move somewhere quieter. Turning the threshold down would only fire on everything."
        }
    }
}
