// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// How ball and bat speed are shown.
///
/// Everything else in the app is metric. Speed is the exception because the
/// sport's own reference numbers are in miles per hour — every published exit
/// velocity, every bat-sensor benchmark, every slow-pitch rule of thumb — so a
/// reading in m/s would be unusable for comparison. Both options are offered
/// rather than one imposed.
enum SpeedUnit: String, Codable, CaseIterable, Sendable {
    case mph
    case kmh

    var displayName: String {
        switch self {
        case .mph: return "Miles per hour"
        case .kmh: return "Kilometres per hour"
        }
    }

    var suffix: String {
        switch self {
        case .mph: return "mph"
        case .kmh: return "km/h"
        }
    }

    var perMps: Double {
        switch self {
        case .mph: return SLA.mphPerMps
        case .kmh: return 3.6
        }
    }

    func from(mps: Double) -> Double { mps * perMps }

    /// Convert a value already in mph, which is how speeds are stored so the
    /// exported CSV stays column-comparable with the Python pipeline.
    func fromMph(_ mph: Double) -> Double {
        switch self {
        case .mph: return mph
        case .kmh: return mph / SLA.mphPerMps * 3.6
        }
    }

    func format(mph: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", fromMph(mph))
    }
}

/// Display formatting for the metric quantities.
///
/// Internally every length in the measurement core is already in metres — the
/// physics was written that way — so these are display helpers, not a
/// conversion layer.
enum Fmt {

    /// Metres, e.g. "5.8 m".
    static func m(_ metres: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f m", metres)
    }

    /// Centimetres, for things a person would measure with a ruler.
    static func cm(_ metres: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f cm", metres * 100)
    }

    /// Millimetres, signed — used for the bat-to-ball contact offset, where
    /// the sign carries the meaning (under the ball versus over it).
    static func signedMm(_ metres: Double) -> String {
        String(format: "%+.0f mm", metres * 1000)
    }

    /// Millimetres per pixel, the scale readout.
    static func mmPerPx(_ metresPerPixel: Double) -> String {
        String(format: "%.3f mm/px", metresPerPixel * 1000)
    }
}
