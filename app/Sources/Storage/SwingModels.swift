// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation
import ImageIO

/// The capture settings from `docs/CAPTURE_PROTOCOL.md`. Raw values are the
/// clip-name prefixes `spike/batch_run.py` expects, so clips pulled off the
/// phone drop straight into the Python pipeline.
enum SwingSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case teeid, tee, toss, live, cage, net, fly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teeid: return "Tee (repeatability)"
        case .tee:   return "Outdoor tee"
        case .toss:  return "Soft toss"
        case .live:  return "Field, live pitching"
        case .cage:  return "Cage (camera inside)"
        case .net:   return "Cage (through net)"
        case .fly:   return "Fly ball (ground truth)"
        }
    }

    var blurb: String {
        switch self {
        case .teeid: return "The five identical-intent swings for gate G4."
        case .tee:   return "The gate that decides the whole project (G1)."
        case .toss:  return "Normal variety off soft toss."
        case .live:  return "Also proves the pitch is separated from the hit."
        case .cage:  return "Tripod inside the cage. The main CV risk."
        case .net:   return "Expected to fail — filmed so the failure is documented."
        case .fly:   return "Pace off the landing spot and time the hang."
        }
    }

    /// G1 trackability thresholds, matching `G1_THRESHOLDS` in `batch_run.py`.
    var g1Threshold: Double? {
        switch self {
        case .tee, .teeid, .toss: return 0.90
        case .live, .fly:         return 0.80
        case .cage:               return 0.70
        case .net:                return nil   // expected failure, not a gate
        }
    }

    /// Counts toward the outdoor G2 median.
    var isOutdoor: Bool {
        switch self {
        case .cage, .net: return false
        default: return true
        }
    }
}

/// One measured swing. A plain value type: the storage layer maps this to and
/// from whatever database is underneath, so SwiftData stays swappable.
struct SwingDTO: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var capturedAt: Date = Date()
    var setting: SwingSetting = .tee

    // Files (names only; directories are resolved at read time so the record
    // survives the container path changing between installs).
    var clipFilename: String?
    var trackCSVFilename: String?

    // Measurement
    var fps: Double = SLA.targetFPS
    var contactTime: Double = 0
    var launchAngleDeg: Double = 0
    var exitVeloMph: Double = 0
    var exitVeloMps: Double = 0
    var scaleBallMPerPx: Double = 0
    var scaleGravityMPerPx: Double?
    var scaleDisagreement: Double?
    var diameterDrift: Double = 0
    var trackedFrames: Int = 0
    var trackDurationS: Double = 0
    var fitRmsPx: Double = 0
    var flags: [SwingFlag] = []
    var usedVisionHint: Bool = false
    /// False when the clip was started by the manual button. This is what
    /// makes gate G5 (audio-trigger reliability) measurable in the field:
    /// the app triggers on exactly the test `check_audio_trigger.py` runs, so
    /// the auto-trigger rate per venue *is* the G5 number.
    var autoTriggered: Bool = true

    // Phase 3
    var batAttackAngleDeg: Double?
    var batFrames: Int?
    /// Barrel-tape speed at contact (mph). The tape sits on the barrel, so this
    /// is bat speed "at the tape marker" — a disclosed bat point, the way
    /// Statcast reports "at the sweet spot". `nil` when the bat was not tracked.
    var batSpeedMph: Double?
    /// Exit velocity ÷ bat speed (collision efficiency / b4-app's "flush"),
    /// exact off a tee and approximate off live pitching. `nil` without bat.
    var smashFactor: Double?
    /// Vertical contact offset in millimetres: how far the barrel centre
    /// passed BELOW the ball centre at contact (Nathan's "undercut"). Positive
    /// = backspin/loft, negative = over the ball. `nil` when the bat was not
    /// tracked or the reading failed the geometric plausibility gate.
    var undercutMm: Double?
    /// The barrel-tape path in raw buffer pixels, kept so the swing arc can be
    /// drawn on a replay or burned into an export. Raw, not rectified — see
    /// `ClipAnalysis.tapePathPx`. Empty when no bat was tracked.
    var batPathPx: [CGPoint] = []

    var smashQuality: SmashQuality { SmashQuality(smash: smashFactor) }
    var contactQuality: ContactQuality {
        ContactQuality(undercutM: undercutMm.map { $0 / 1000 })
    }

    // G3 ground truth, entered by hand after a fly ball
    var hangS: Double?
    var carryM: Double?

    // Placement, carried over from the wizard
    var cameraDistanceM: Double?
    var lensHeightM: Double?
    var cameraRollDeg: Double?
    /// Camera pitch at capture, positive aiming down. Corrected, not merely
    /// recorded: `TiltRectifier` warps the track into the view a level camera
    /// would have seen before any number is taken from it.
    var cameraTiltDeg: Double?
    /// Horizontal field of view of the capture format. Stored because the tilt
    /// correction is meaningless without it — re-analysing an old clip has to
    /// use the optics it was actually filmed with, not whatever lens the phone
    /// happens to be on today.
    var cameraFovDeg: Double?
    /// Sagittal-plane body measurements. Nil when the body pass was off or the
    /// pose model never found the hitter. Deliberately no rotation and no
    /// torque — see `BodyMetrics` and `docs/BIOMECHANICS.md`.
    var body: BodyMetrics?
    /// Pose track file, alongside the ball track CSV. Kept for the same reason:
    /// when a body number looks wrong, the frames it came from are the only way
    /// to find out why.
    var poseFilename: String?
    /// What the detector saw before the track was chosen — every candidate and
    /// the region searched. The one file that can tell "never looked there"
    /// apart from "looked and rejected it". See `DetectionTrace`.
    var traceFilename: String?
    /// Where the user tapped the ball, if they did: clip time and buffer
    /// pixels. Persisted so re-analysis keeps following the object they
    /// pointed at rather than falling back to scoring.
    var ballSeedT: Double?
    var ballSeedX: Double?
    var ballSeedY: Double?
    /// Which way was up in the recorded frames. Stored because re-analysis has
    /// to show Vision the same scene the capture did; guessing `.up` on a
    /// sideways clip finds no hitter at all.
    /// `Int`, not `CGImagePropertyOrientation.RawValue` (`UInt32`): this is
    /// what actually lands in the database and the CSV, and every other integer
    /// column is an Int. 1 is `.up`.
    var visionOrientationRaw: Int = 1
    var visionOrientation: CGImagePropertyOrientation {
        get { CGImagePropertyOrientation(rawValue: UInt32(max(0, visionOrientationRaw))) ?? .up }
        set { visionOrientationRaw = Int(newValue.rawValue) }
    }
    /// Conditions the camera was in, kept beside the measurement `flags`.
    /// Level no longer blocks arming, so this is what keeps a reading taken on
    /// an off-level tripod honest instead of merely absent.
    var captureFlags: [CaptureFlag] = []

    /// The stage-by-stage analysis report, written for EVERY swing rather
    /// than only for imports. It is the file that says which stage failed, and
    /// a swing captured live is exactly the one you cannot re-run to find out.
    var diagnosticsFilename: String?

    /// The round this swing belongs to, if it was taken inside one. `nil` for
    /// imported clips and for anything captured before sessions existed —
    /// those still appear in the full history, they just have no round to be
    /// collated into.
    var sessionID: UUID?

    var notes: String?

    /// High confidence means the measurement is clean *and* it was taken in
    /// conditions worth trusting. Two flags are excluded because both name a
    /// condition that is *corrected* rather than merely recorded: roll is
    /// rotated out of the velocity vector, and tilt inside
    /// `SLA.tiltCorrectableMaxDeg` is rectified out of the whole track before
    /// anything is measured. Steeper tilt arrives as `.cameraTilted`, which
    /// still demotes the reading.
    var highConfidence: Bool {
        flags.isEmpty && captureFlags.allSatisfy { $0 == .notLevel || $0 == .tiltCorrected }
    }

    /// False when the pipeline concluded the track it measured was not a ball.
    ///
    /// The distinction `TrackPlausibility` exists to draw, in the words of its
    /// own comment: flags qualify a MEASUREMENT, and this is the case where
    /// there is no measurement to qualify. Everything that shows a reading asks
    /// this first — a launch angle for a patch of grass is not a doubtful
    /// number, it is not a number, and printing it beside a warning chip still
    /// puts a figure in front of somebody who will read it.
    /// `trackedFrames == 0` is the OTHER way there is no ball: analysis
    /// failed outright rather than measuring the wrong thing, so `confirmBall`
    /// never ran and `.ballUnconfirmed` was never set. Those records carry the
    /// defaults, and a round summary printed them as "0.0 mph +0°" — a
    /// reading of zero rather than the absence of one.
    var ballIdentified: Bool {
        trackedFrames > 0 && !captureFlags.contains(.ballUnconfirmed)
    }

    /// Written by `AppModel.confirmBall`, read back by
    /// `ballNotIdentifiedReason`. One constant, because two copies of a magic
    /// prefix that must match is a bug waiting for someone to reword one.
    static let ballNotIdentifiedPrefix = "Ball not identified: "

    /// Why, in the words meant for the person who filmed it. Carried in
    /// `notes` because that is where `AppModel.confirmBall` writes it.
    var ballNotIdentifiedReason: String? {
        guard !ballIdentified else { return nil }
        let prefix = Self.ballNotIdentifiedPrefix
        for line in (notes ?? "").split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return "the tracked object does not behave like a struck ball"
    }

    /// G1 counts a clip as tracked at 12+ frames, matching `G1_MIN_FRAMES`.
    var meetsG1: Bool { trackedFrames >= 12 }

    init() {}

    init(analysis: ClipAnalysis, setting: SwingSetting, clipFilename: String?,
         autoTriggered: Bool = true, sessionID: UUID? = nil) {
        self.setting = setting
        self.sessionID = sessionID
        self.clipFilename = clipFilename
        self.autoTriggered = autoTriggered
        self.fps = analysis.fps
        self.contactTime = analysis.contactTime
        self.usedVisionHint = analysis.usedVisionHint
        let m = analysis.metrics
        self.launchAngleDeg = m.launchAngleDeg
        self.exitVeloMph = m.exitVeloMph
        self.exitVeloMps = m.exitVeloMps
        self.scaleBallMPerPx = m.scaleBallMPerPx
        self.scaleGravityMPerPx = m.scaleGravityMPerPx
        self.scaleDisagreement = m.scaleDisagreement
        self.diameterDrift = m.diameterDrift
        self.trackedFrames = m.nFrames
        self.trackDurationS = m.trackDurationS
        self.fitRmsPx = m.fitRmsPx
        self.flags = m.flags
        self.batAttackAngleDeg = analysis.bat?.attackAngleDeg
        self.batFrames = analysis.bat?.nFrames
        self.batPathPx = analysis.tapePathPx
        // Only kept when it actually says something: a BodyMetrics with every
        // field nil is a row of dashes pretending to be a measurement.
        self.body = (analysis.body?.hasAnything ?? false) ? analysis.body : nil

        // Bat speed + smash factor need both the bat velocity (px/s at contact)
        // and the ball-size scale (m/px). Only compute when the bat was tracked
        // with enough confidence and the ball scale is sound.
        if let bat = analysis.bat, !bat.isLowConfidence, m.scaleBallMPerPx > 0 {
            let bs = SLA.batSpeedMps(vxPxS: bat.vxPxS, vyPxS: bat.vyPxS,
                                     scaleMPerPx: m.scaleBallMPerPx)
            self.batSpeedMph = bs * SLA.mphPerMps
            self.smashFactor = SLA.smashFactor(exitVeloMps: m.exitVeloMps,
                                               batSpeedMps: bs)

            // Contact offset: tape centroid vs ball centre, both extrapolated
            // to the contact instant. Implausible gaps (centres farther apart
            // than the two radii) are discarded, not displayed.
            let u = SLA.undercutM(ballY0Px: m.y0Px, batY0Px: bat.contactYPx,
                                  scaleMPerPx: m.scaleBallMPerPx)
            if abs(u) <= SLA.contactPlausibleM {
                self.undercutMm = u * 1000
            }
        }
    }
}

/// Abstract persistence so SwiftData can be replaced without touching the UI.
protocol SwingStoring: AnyObject {
    func all() throws -> [SwingDTO]
    func save(_ swing: SwingDTO) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}
