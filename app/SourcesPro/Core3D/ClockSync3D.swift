// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// One ping exchange. `t1`/`t4` are on the master's clock, `t2`/`t3` on the
/// worker's — the classic NTP four-timestamp shape.
struct ClockSample: Equatable, Codable, Sendable {
    var t1: Double
    var t2: Double
    var t3: Double
    var t4: Double

    /// Round trip with the worker's own processing time removed.
    var rtt: Double { (t4 - t1) - (t3 - t2) }
    /// This exchange's estimate of (worker − master).
    var offset: Double { ((t2 - t1) + (t3 - t4)) / 2.0 }
    /// Worker-clock abscissa, for fitting skew against.
    var tau: Double { (t2 + t3) / 2.0 }
}

/// A worker's clock expressed relative to the master's.
///
/// `offsetS` is (worker − master) measured at worker time `tRefS`; `skew` is
/// its rate of change. `ciS` is a robust half-width of the fit residuals —
/// what the sync HUD shows, not part of the mapping.
struct ClockModel: Equatable, Codable, Sendable {
    var offsetS: Double
    var skew: Double
    var tRefS: Double
    var rttMinS: Double
    var nUsed: Int
    var ciS: Double

    static let identity = ClockModel(offsetS: 0, skew: 0, tRefS: 0,
                                     rttMinS: 0, nUsed: 0, ciS: 0)

    /// Good enough to trust 3D with.
    var isWithinBudget: Bool { ciS <= SLA3D.syncBudgetS }
    var isDegraded: Bool { ciS > SLA3D.syncDegradedS }
}

enum ClockSync3D {

    /// Worker timestamp → master timeline.
    static func mapToMaster(_ tRemote: Double, _ m: ClockModel) -> Double {
        tRemote - (m.offsetS + m.skew * (tRemote - m.tRefS))
    }

    /// Fit offset and skew from a burst of ping exchanges.
    ///
    /// Only near-minimum-RTT exchanges are kept. MultipeerConnectivity's
    /// median round trip is a few milliseconds but its tail reaches
    /// hundreds, and a delayed ping is not slightly wrong — it is garbage,
    /// so averaging it in would be too. Skew then comes from a Theil–Sen fit
    /// (median of pairwise slopes) over what survives, because one more bad
    /// sample must move the answer by roughly nothing: there is no operator
    /// watching for outliers at a ball field.
    static func fit(_ samples: [ClockSample]) -> ClockModel? {
        guard samples.count >= 2 else { return nil }
        let valid = samples.filter { $0.rtt >= 0 && $0.rtt.isFinite && $0.offset.isFinite }
        guard valid.count >= 2 else { return nil }

        let rttMin = valid.map(\.rtt).min() ?? 0
        // The 1e-6 keeps the multiplicative window from collapsing onto a
        // single sample when rttMin is ~0 (loopback, or a synthetic test).
        let kept = valid.filter { $0.rtt <= rttMin * SLA3D.minRTTKeepFactor + 1e-6 }
        guard kept.count >= 1 else { return nil }

        let offs = kept.map(\.offset)
        let taus = kept.map(\.tau)

        var skew = 0.0
        if kept.count >= 2, let lo = taus.min(), let hi = taus.max(), hi - lo > 1e-9 {
            var slopes: [Double] = []
            slopes.reserveCapacity(kept.count * (kept.count - 1) / 2)
            for i in 0..<kept.count {
                for j in (i + 1)..<kept.count {
                    let dt = taus[j] - taus[i]
                    if dt > 1e-9 { slopes.append((offs[j] - offs[i]) / dt) }
                }
            }
            if !slopes.isEmpty { skew = median(slopes) }
        }

        let tRef = median(taus)
        let residuals = zip(offs, taus).map { $0 - skew * ($1 - tRef) }
        let offset = median(residuals)
        let ci = 1.4826 * median(residuals.map { abs($0 - offset) })
        return ClockModel(offsetS: offset, skew: skew, tRefS: tRef,
                          rttMinS: rttMin, nUsed: kept.count, ciS: ci)
    }

    /// Median with the same tie-breaking as NumPy's: the mean of the two
    /// middle values on an even count. Parity depends on this.
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
