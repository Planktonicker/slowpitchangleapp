// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// CSV export.
///
/// Two shapes on purpose:
///
///  * `summaryCSV` reproduces `spike/batch_run.py`'s `out/summary.csv` column
///    for column, so device numbers can be diffed directly against numbers
///    the Python produced from the same clips.
///  * `fullCSV` adds everything the app knows that the spike has no place for
///    (placement, ground truth, bat angle, trigger source).
enum CSVExport {

    // MARK: - batch_run.py-compatible summary

    static let summaryColumns = [
        "clip", "setting", "tracked", "la_deg", "ev_mph", "scale_ball_mm_px",
        "scale_grav_mm_px", "disagree_pct", "drift_pct", "fit_rms_px",
        "flags", "verdict",
    ]

    static func summaryCSV(_ swings: [SwingDTO]) -> String {
        var out = summaryColumns.joined(separator: ",") + "\n"
        for s in swings.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let fields: [String] = [
                s.clipFilename ?? "",
                s.setting.rawValue,
                String(s.trackedFrames),
                round2(s.launchAngleDeg),
                round2(s.exitVeloMph),
                round3(s.scaleBallMPerPx * 1000),
                s.scaleGravityMPerPx.map { round3($0 * 1000) } ?? "",
                s.scaleDisagreement.map { round1($0 * 100) } ?? "",
                round1(s.diameterDrift * 100),
                round2(s.fitRmsPx),
                s.flags.map(\.rawValue).joined(separator: "|"),
                s.highConfidence ? "ok" : "low-conf",
            ]
            out += fields.map(escape).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - Everything the app knows

    static let fullColumns = summaryColumns + [
        "captured_at", "fps", "contact_time_s", "track_duration_s",
        "auto_triggered", "used_vision_hint", "bat_attack_angle_deg",
        "bat_frames", "bat_speed_mph", "smash_factor", "undercut_mm",
        "hang_s", "carry_m", "model_hang_s", "model_carry_m",
        "hang_err_pct", "carry_err_pct", "camera_distance_m", "lens_height_m",
        "camera_roll_deg", "camera_tilt_deg", "capture_flags", "track_csv", "notes",
    ]

    static func fullCSV(_ swings: [SwingDTO]) -> String {
        let iso = ISO8601DateFormatter()
        var out = fullColumns.joined(separator: ",") + "\n"
        for s in swings.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let flight = FlightModel.simulate(evMps: s.exitVeloMps, laDeg: s.launchAngleDeg)
            let hangErr = s.hangS.map { ($0 > 0) ? (flight.hangS - $0) / $0 * 100 : 0 }
            let carryErr = s.carryM.map { ($0 > 0) ? (flight.carryM - $0) / $0 * 100 : 0 }
            let fields: [String] = [
                s.clipFilename ?? "",
                s.setting.rawValue,
                String(s.trackedFrames),
                round2(s.launchAngleDeg),
                round2(s.exitVeloMph),
                round3(s.scaleBallMPerPx * 1000),
                s.scaleGravityMPerPx.map { round3($0 * 1000) } ?? "",
                s.scaleDisagreement.map { round1($0 * 100) } ?? "",
                round1(s.diameterDrift * 100),
                round2(s.fitRmsPx),
                s.flags.map(\.rawValue).joined(separator: "|"),
                s.highConfidence ? "ok" : "low-conf",
                iso.string(from: s.capturedAt),
                round1(s.fps),
                round3(s.contactTime),
                round3(s.trackDurationS),
                s.autoTriggered ? "auto" : "manual",
                s.usedVisionHint ? "1" : "0",
                s.batAttackAngleDeg.map(round2) ?? "",
                s.batFrames.map(String.init) ?? "",
                s.batSpeedMph.map(round1) ?? "",
                s.smashFactor.map(round2) ?? "",
                s.undercutMm.map(round1) ?? "",
                s.hangS.map(round2) ?? "",
                s.carryM.map(round1) ?? "",
                round2(flight.hangS),
                round1(flight.carryM),
                hangErr.map(round1) ?? "",
                carryErr.map(round1) ?? "",
                s.cameraDistanceM.map(round2) ?? "",
                s.lensHeightM.map(round2) ?? "",
                s.cameraRollDeg.map(round2) ?? "",
                s.cameraTiltDeg.map(round2) ?? "",
                s.captureFlags.map(\.rawValue).joined(separator: "|"),
                s.trackCSVFilename ?? "",
                s.notes ?? "",
            ]
            out += fields.map(escape).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - VALIDATION.md scoreboard, as text

    static func scoreboardText(_ board: ValidationScoreboard) -> String {
        var out = "=== SwingLab go/no-go scoreboard ===\n\n"
        out += "G1 trackability (>=12 tracked frames):\n"
        for row in board.g1 {
            let mark: String
            if let p = row.passes {
                mark = p ? "  PASS" : "  FAIL (need \(pct(row.threshold ?? 0)))"
            } else {
                mark = "  n/a"
            }
            out += "  \(row.setting.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)): "
            out += "\(row.tracked)/\(row.total) = \(pct(row.fraction))\(mark)\n"
        }

        out += "\nG2 scale agreement (outdoor median over \(board.g2Count) clips): "
        if let median = board.g2MedianPct {
            out += String(format: "%.1f%%  %@ (tol %.0f%%)\n",
                          median,
                          (board.g2Passes ?? false) ? "PASS" : "FAIL",
                          SLA.scaleDisagreeTol * 100)
        } else {
            out += "no clips with a usable gravity check yet\n"
        }

        out += "\nG3 fly-ball physics:\n"
        if board.g3.isEmpty {
            out += "  no fly balls with hang time or carry entered yet\n"
        } else {
            for row in board.g3 {
                out += "  \(row.label): "
                out += "hang \(row.hangErrorPct.map { String(format: "%+.1f%%", $0) } ?? "-"), "
                out += "carry \(row.carryErrorPct.map { String(format: "%+.1f%%", $0) } ?? "-")\n"
            }
        }

        out += "\nG4 repeatability (teeid_*, \(board.g4Count) swings): "
        if let ev = board.g4EvSd, let la = board.g4LaSd {
            out += String(format: "EV sd=%.2f mph %@ | LA sd=%.2f deg %@\n",
                          ev, (board.g4EvPasses ?? false) ? "PASS" : "FAIL",
                          la, (board.g4LaPasses ?? false) ? "PASS" : "FAIL")
        } else {
            out += "need at least 3 tracked teeid_ swings\n"
        }

        out += "\nG5 audio trigger: \(board.g5AutoTriggered)/\(board.g5Total) auto-triggered"
        if let f = board.g5Fraction {
            out += " = \(pct(f)) \((board.g5Passes ?? false) ? "PASS" : "FAIL") (need 90%)"
        }
        out += "\n\nVERDICT: \(board.verdict.rawValue)\n\(board.verdictExplanation)\n"
        return out
    }

    // MARK: - Helpers

    private static func pct(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
    private static func round1(_ d: Double) -> String { String(format: "%.1f", d) }
    private static func round2(_ d: Double) -> String { String(format: "%.2f", d) }
    private static func round3(_ d: Double) -> String { String(format: "%.3f", d) }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Write a text file into Documents/Exports and hand back its URL.
    static func write(_ text: String, filename: String) throws -> URL {
        let url = ClipStore.exportsDirectory.appendingPathComponent(filename)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
