// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

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

    var smashQuality: SmashQuality { SmashQuality(smash: smashFactor) }

    // G3 ground truth, entered by hand after a fly ball
    var hangS: Double?
    var carryFt: Double?

    // Placement, carried over from the wizard
    var cameraDistanceFt: Double?
    var lensHeightFt: Double?
    var cameraRollDeg: Double?

    var notes: String?

    var highConfidence: Bool { flags.isEmpty }

    /// G1 counts a clip as tracked at 12+ frames, matching `G1_MIN_FRAMES`.
    var meetsG1: Bool { trackedFrames >= 12 }

    init() {}

    init(analysis: ClipAnalysis, setting: SwingSetting, clipFilename: String?,
         autoTriggered: Bool = true) {
        self.setting = setting
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

        // Bat speed + smash factor need both the bat velocity (px/s at contact)
        // and the ball-size scale (m/px). Only compute when the bat was tracked
        // with enough confidence and the ball scale is sound.
        if let bat = analysis.bat, !bat.isLowConfidence, m.scaleBallMPerPx > 0 {
            let bs = SLA.batSpeedMps(vxPxS: bat.vxPxS, vyPxS: bat.vyPxS,
                                     scaleMPerPx: m.scaleBallMPerPx)
            self.batSpeedMph = bs * SLA.mphPerMps
            self.smashFactor = SLA.smashFactor(exitVeloMps: m.exitVeloMps,
                                               batSpeedMps: bs)
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
