// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Reads and writes the track CSV format of `sla_common.write_track_csv`.
///
/// This is the bridge back to the Python spike: a track exported from the
/// phone can be dropped straight into `spike/out/` and re-analyzed with
///
///     python analyze_swing.py out/<clip>.csv --flyball --hang 4.1 --carry-ft 185
///
/// so the Mac pipeline stays the referee whenever an on-device number looks
/// wrong. Keep the format byte-compatible.
enum TrackCSV {

    static func serialize(track: [BallObservation],
                          fps: Double,
                          meta: [(key: String, value: String)] = []) -> String {
        var out = ""
        for (k, v) in meta {
            out += "# \(k)=\(v)\n"
        }
        out += "# fps=\(fmt(fps))\n"
        out += "frame,t,x_px,y_px,diameter_px,area_px\n"
        for o in track {
            out += "\(o.frame),"
            out += String(format: "%.6f,", o.t)
            out += String(format: "%.2f,", o.x)
            out += String(format: "%.2f,", o.y)
            out += String(format: "%.2f,", o.diameterPx)
            out += String(format: "%.1f\n", o.areaPx)
        }
        return out
    }

    /// Python writes `fps=240.0` for a float and `fps=240` for an int; either
    /// parses fine on the way back, but keep whole numbers clean.
    private static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.1f", d) : String(d)
    }

    struct Parsed {
        var track: [BallObservation]
        var meta: [String: String]

        var fps: Double? { meta["fps"].flatMap(Double.init) }
        var contactTime: Double? { meta["contact_time"].flatMap(Double.init) }
    }

    static func parse(_ text: String) -> Parsed {
        var meta: [String: String] = [:]
        var rows: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let eq = body.firstIndex(of: "=") {
                    let k = body[body.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                    let v = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    meta[k] = v
                }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            rows.append(line)
        }
        guard let header = rows.first else { return Parsed(track: [], meta: meta) }
        let cols = header.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        func idx(_ name: String) -> Int? { cols.firstIndex(of: name) }
        guard let iFrame = idx("frame"), let iT = idx("t"), let iX = idx("x_px"),
              let iY = idx("y_px"), let iD = idx("diameter_px") else {
            return Parsed(track: [], meta: meta)
        }
        let iA = idx("area_px")

        var track: [BallObservation] = []
        for row in rows.dropFirst() {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= cols.count,
                  let frame = Int(f[iFrame]), let t = Double(f[iT]),
                  let x = Double(f[iX]), let y = Double(f[iY]),
                  let d = Double(f[iD]) else { continue }
            let area = iA.flatMap { Double(f[$0]) } ?? (Double.pi * (d / 2) * (d / 2))
            track.append(BallObservation(frame: frame, t: t, x: x, y: y,
                                         diameterPx: d, areaPx: area))
        }
        return Parsed(track: track, meta: meta)
    }
}
