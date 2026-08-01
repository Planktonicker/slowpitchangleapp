// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// User-tunable settings, persisted in `UserDefaults`.
///
/// The colour ranges and radii mirror `track_ball.py`'s command-line flags on
/// purpose: a venue tuned on the Mac can be typed in here, and vice versa.
struct AppSettings: Codable, Equatable {
    var detector = DetectorSettings()
    var bat = BatTracker.Settings()
    var trackBat = true
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
        o.direction = direction
        o.forceFallbackDetector = forceFallbackDetector
        o.fpsOverride = fpsOverride
        return o
    }
}
