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
    // No `trackBat`. The switch was removed in 5679885 because it bought
    // nothing and silently cost the hitter the whole bat panel on every clip
    // they forgot to flip it — but the stored property outlived its only UI
    // writer, and the resilient decoder went on restoring a persisted `false`
    // from before the update on every launch, gating the bat pass off forever
    // with no control anywhere to turn it back on. The analyzer decides for
    // itself whether a bat was tracked; that is the whole point of that commit.
    /// Whether the setup overlay has ever been opened. It auto-opens once, on
    /// a first run, and never again — it used to auto-open whenever no
    /// distance was set, which is now the normal state rather than an unfinished
    /// one.
    var hasCompletedFirstSetup = false
    /// Run the body-pose pass over each clip. On by default — the sagittal
    /// metrics are the point of it — but a switch, because it is a third decode
    /// pass and a phone already at 240fps is the phone most likely to be hot.
    var trackBody = true
    /// Which generation of the DEFAULTS this blob was written against.
    ///
    /// Only for one-time migrations of a default that turned out to be wrong,
    /// and it exists because of the `trackBat` lesson: a stored value outlives
    /// the default it was copied from, so changing a default reaches nobody
    /// who has ever opened Settings. Bumped when a default changes in a way
    /// that must reach existing installs.
    var defaultsGeneration = 2
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

    /// The hitter's standing height, in centimetres.
    ///
    /// Typed once, in Settings, and used by the setup screen to turn the pose's
    /// nose-to-ankle span into a camera distance — see `HitterScale`. Optional
    /// because there is no sensible default height: guessing one would produce
    /// a confident distance for a person nobody measured. One height, not a
    /// per-athlete profile; the app has no athlete identity anywhere.
    var hitterHeightCm: Double?

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
        o.trackBody = trackBody
        // An explicit choice in Settings still wins; "auto" now means "work it
        // out from the hitter's side" rather than "let the fastest track vote".
        o.direction = direction == .auto ? outboundDirection : direction
        o.forceFallbackDetector = forceFallbackDetector
        o.fpsOverride = fpsOverride
        return o
    }
}


// MARK: - Resilient decoding

/// Declared in an extension, NOT in the struct body, and that placement is
/// load-bearing: an initializer written inside a struct's own declaration
/// suppresses the synthesised memberwise and no-argument initialisers. That
/// would remove `AppSettings()` — which this decoder itself calls to source
/// its defaults, and which "Reset settings to defaults" is built on.
extension AppSettings {

    /// Field-by-field decoding, every key optional, every miss falling back to
    /// the property's own default.
    ///
    /// Swift's SYNTHESISED `Decodable` does not do this, and the difference is
    /// not academic. A synthesised decoder calls `decode` — not
    /// `decodeIfPresent` — for every non-optional property, and a default value
    /// written at the declaration is invisible to it. So the moment a new field
    /// is added to this struct, every previously saved blob fails to decode
    /// ENTIRELY, `load()` swallows the error, and the user silently gets
    /// factory settings back. Someone who had spent a session tuning an HSV
    /// window for their venue would lose it to an app update, with no message
    /// and nothing to point at.
    ///
    /// It also made the "Reset settings to defaults" button look broken: after
    /// any such update the settings were already default, so pressing it
    /// changed nothing visible.
    ///
    /// `try?` on each field rather than one `try` for the lot, so a single
    /// corrupt or renamed value costs that one setting instead of all of them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func take<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        detector = take(.detector, d.detector)
        bat = take(.bat, d.bat)
        hasCompletedFirstSetup = take(.hasCompletedFirstSetup, d.hasCompletedFirstSetup)
        trackBody = take(.trackBody, d.trackBody)
        defaultsGeneration = take(.defaultsGeneration, 0)
        // Trigger threshold: 15 -> 20, once.
        //
        // 15 was the G5 validation GATE being used as an operating default,
        // and on both field clips it fired on the wrong sound — a 17 dB noise
        // half a second before contact, after which the refractory window
        // covered the real 37 dB crack. A stored 15 is indistinguishable from
        // "never changed it", and it is the same thing here: 15 was the
        // default, so nobody chose it over anything. Migrated once, and the
        // generation marker means a 15 typed in deliberately after this update
        // is kept.
        let storedTrigger = take(.triggerDb, d.triggerDb)
        if defaultsGeneration < 2, storedTrigger == 15.0 {
            triggerDb = d.triggerDb
        } else {
            triggerDb = storedTrigger
        }
        defaultsGeneration = max(defaultsGeneration, 2)
        preRollS = take(.preRollS, d.preRollS)
        postRollS = take(.postRollS, d.postRollS)
        direction = take(.direction, d.direction)
        requireHitter = take(.requireHitter, d.requireHitter)
        forceFallbackDetector = take(.forceFallbackDetector, d.forceFallbackDetector)
        keepClips = take(.keepClips, d.keepClips)
        // Genuinely optional: absent and null both mean "measure it".
        fpsOverride = (try? c.decodeIfPresent(Double.self, forKey: .fpsOverride)) ?? nil
        // Genuinely optional too: absent and null both mean "nobody has said".
        hitterHeightCm = (try? c.decodeIfPresent(Double.self, forKey: .hitterHeightCm)) ?? nil
        importFovDeg = take(.importFovDeg, d.importFovDeg)
        visionOrientation = take(.visionOrientation, d.visionOrientation)
        speedUnit = take(.speedUnit, d.speedUnit)
        hitterOnLeft = take(.hitterOnLeft, d.hitterOnLeft)
    }
}
