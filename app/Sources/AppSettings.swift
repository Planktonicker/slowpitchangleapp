// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation
import ImageIO

/// Manual override for the orientation handed to Vision.
///
/// Auto derives it from the device's rotation coordinator and is right in
/// almost every case. The escape hatch exists because the angle-to-EXIF
/// mapping is the classic thing to get backwards, and discovering that on a
/// tripod at a field — where every trigger is silently suppressed because the
/// pose model sees a sideways human — should cost a tap, not a trip.
enum VisionOrientationSetting: String, Codable, CaseIterable, Sendable {
    case auto, up, right, down, left

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .up: return "Up (0°)"
        case .right: return "Right (90°)"
        case .down: return "Down (180°)"
        case .left: return "Left (270°)"
        }
    }

    var orientation: CGImagePropertyOrientation? {
        switch self {
        case .auto: return nil
        case .up: return .up
        case .right: return .right
        case .down: return .down
        case .left: return .left
        }
    }
}

/// User-tunable settings, persisted in `UserDefaults`.
///
/// The colour ranges and radii mirror `track_ball.py`'s command-line flags on
/// purpose: a venue tuned on the Mac can be typed in here, and vice versa.
struct AppSettings: Codable, Equatable {
    var detector = DetectorSettings()
    var bat = BatTracker.Settings()
    var trackBat = true
    /// Run the body-pose pass over each clip. On by default — the sagittal
    /// metrics are the point of it — but a switch, because it is a third decode
    /// pass and a phone already at 240fps is the phone most likely to be hot.
    var trackBody = true
    var triggerDb = SLA.triggerDb
    var preRollS = SLA.preRollS
    var postRollS = SLA.postRollS
    var direction: TrackBuilder.Direction = .auto
    /// Audio triggers only fire when a person has been seen in frame within
    /// the last second and a half. Kills the no-human false trigger; manual
    /// capture always bypasses it.
    var requireHitter = true
    var forceFallbackDetector = false
    /// Keep clips after analysis. Off would save space, but the whole point
    /// of Phase 0 is being able to go back to the footage when a number looks
    /// wrong — so this defaults on and warns about space instead.
    var keepClips = true
    var fpsOverride: Double?

    /// Horizontal field of view assumed for imported clips, in degrees.
    ///
    /// A clip this app filmed carries its own optics. One from the stock
    /// Camera app carries none — and without a field of view there is no focal
    /// length, and without a focal length camera tilt cannot be undone at all,
    /// because the correction is a homography in the tilt angle AND the focal
    /// length. Imports were therefore given zero and got no tilt correction
    /// whatsoever, which is the one thing they need most: nobody levels a
    /// phone they are holding.
    ///
    /// 68 degrees is the main wide camera on every recent iPhone. It is an
    /// assumption, so it is a setting rather than a constant, and swings
    /// measured with it are flagged.
    var importFovDeg: Double = 68

    var visionOrientation: VisionOrientationSetting = .auto
    /// Everything else in the app is metric; ball and bat speed are the one
    /// exception, because the sport's published reference numbers are in mph.
    var speedUnit: SpeedUnit = .mph
    /// Which way round the framing guide is drawn: hitter near the left edge
    /// with the ball flying right, or mirrored. Purely a setup aid — the
    /// measurement itself is direction-agnostic (`SwingAnalyzer` reports launch
    /// angle up-positive whichever way the ball leaves).
    var hitterOnLeft = true

    /// Which way the HIT ball crosses the frame, from where the hitter stands.
    ///
    /// The setup guide already asks the user which side the hitter is on, and
    /// draws the flight arrow accordingly — the app has known the answer all
    /// along and was not using it. It matters because an inbound slow-pitch is
    /// a perfectly good track: straight, fast enough to clear every filter,
    /// and crossing the frame the OPPOSITE way. Direction is the one thing
    /// that separates the two for certain, and leaving it on "auto" left the
    /// choice to a speed comparison between a lob and a line drive.
    var outboundDirection: TrackBuilder.Direction {
        // Hitter on the left means the ball leaves to the right.
        hitterOnLeft ? .right : .left
    }

    static let storageKey = "swinglab.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var analyzerOptions: ClipAnalyzer.Options {
        var o = ClipAnalyzer.Options()
        o.detector = detector
        o.bat = bat
        o.trackBat = trackBat
        o.trackBody = trackBody
        // An explicit choice in Settings still wins; "auto" now means "work it
        // out from the hitter's side" rather than "let the fastest track vote".
        o.direction = direction == .auto ? outboundDirection : direction
        o.forceFallbackDetector = forceFallbackDetector
        o.fpsOverride = fpsOverride
        return o
    }
}
