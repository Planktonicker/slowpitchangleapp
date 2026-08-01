import Foundation

/// Point-mass flight with quadratic drag — the physics that stands in for a
/// radar gun (validation gate G3).
///
/// Port of `simulate_flight` / `vy0_from_hang_time` in `sla_common.py`.
enum FlightModel {

    struct Flight: Equatable, Sendable {
        var carryM: Double
        var hangS: Double
        var apexM: Double

        var carryFt: Double { carryM * 3.28084 }
        var apexFt: Double { apexM * 3.28084 }
    }

    /// Integrate a batted ball from contact to landing. No spin/Magnus — the
    /// G3 tolerances (±15% hang, ±20% carry) are wide enough to absorb it.
    ///
    /// Fixed-step Euler at `dt`, matching the Python step for step so the two
    /// produce identical numbers.
    static func simulate(evMps: Double,
                         laDeg: Double,
                         contactHeightM: Double = 0.9,
                         dt: Double = 0.002) -> Flight {
        let k = 0.5 * SLA.airDensity * SLA.dragCd * Double.pi
            * (SLA.ballDiameterM / 2) * (SLA.ballDiameterM / 2)
        let la = laDeg * Double.pi / 180
        var vx = evMps * cos(la)
        var vy = evMps * sin(la)
        var x = 0.0
        var y = contactHeightM
        var t = 0.0
        var apex = contactHeightM

        while y > 0.0 && t < 20.0 {
            let v = (vx * vx + vy * vy).squareRoot()
            let ax = -k / SLA.ballMassKg * v * vx
            let ay = -SLA.g - k / SLA.ballMassKg * v * vy
            vx += ax * dt
            vy += ay * dt
            x += vx * dt
            y += vy * dt
            t += dt
            apex = max(apex, y)
        }
        return Flight(carryM: x, hangS: t, apexM: apex)
    }

    /// Vacuum estimate of initial vertical speed from hang time (`vy0 = gT/2`).
    ///
    /// Drag makes the true `vy0` somewhat larger; the ±15% G3 tolerance
    /// absorbs that. This is an independent cross-check, not a calibration.
    static func vy0FromHangTime(_ hangS: Double) -> Double {
        SLA.g * hangS / 2.0
    }

    /// Compare a measured swing against stopwatch hang time and paced-off
    /// carry — the G3 gate, per clip.
    struct GroundTruthCheck: Equatable, Sendable {
        var model: Flight
        var measuredHangS: Double?
        var measuredCarryFt: Double?

        var hangErrorPct: Double? {
            guard let h = measuredHangS, h > 0 else { return nil }
            return (model.hangS - h) / h * 100
        }
        var carryErrorPct: Double? {
            guard let c = measuredCarryFt, c > 0 else { return nil }
            return (model.carryFt - c) / c * 100
        }
        var hangPasses: Bool? { hangErrorPct.map { abs($0) <= 15 } }
        var carryPasses: Bool? { carryErrorPct.map { abs($0) <= 20 } }
    }

    static func check(metrics: SwingMetrics,
                      hangS: Double?,
                      carryFt: Double?,
                      contactHeightM: Double = 0.9) -> GroundTruthCheck {
        GroundTruthCheck(
            model: simulate(evMps: metrics.exitVeloMps,
                            laDeg: metrics.launchAngleDeg,
                            contactHeightM: contactHeightM),
            measuredHangS: hangS,
            measuredCarryFt: carryFt
        )
    }
}
