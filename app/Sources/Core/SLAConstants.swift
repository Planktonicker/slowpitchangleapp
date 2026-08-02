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
    /// Wide on purpose; tighten per venue in Settings.
    static let hsvLoDefault = HSVBounds(h: 18, s: 70, v: 120)
    static let hsvHiDefault = HSVBounds(h: 48, s: 255, v: 255)

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
    static let minGravityTrackS = 0.20     // below this the gravity scale is unreliable
    static let scaleDisagreeTol = 0.08     // G2 tolerance
    static let diameterDriftTol = 0.10     // depth-motion (cosine error) flag threshold
    static let residualTolPx = 3.0

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
    static let preRollS = 0.75
    static let postRollS = 1.50
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
