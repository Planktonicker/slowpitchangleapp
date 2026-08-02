// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import XCTest
@testable import SwingLab

/// Asserts the Swift measurement core reproduces `spike/sla_common.py`
/// number-for-number.
///
/// The fixtures are generated from the Python itself:
///
///     python spike/gen_parity_fixtures.py
///
/// If one of these fails, the Swift and the reference have diverged. Fix the
/// Swift — or change the Python first, regenerate, and let the new numbers
/// land here deliberately.
final class ParityTests: XCTestCase {

    // MARK: - Fixture model

    struct Fixtures: Decodable {
        var constants: [String: Double]
        var fit_quadratic: [FitCase]
        var solve_gravity_scale: [GravityCase]
        var analyze_track: [AnalyzeCase]
        var simulate_flight: [FlightCase]
        var vy0_from_hang_time: [Vy0Case]
        var bat_metrics: [BatCase]
        var contact_offset: [ContactCase]
    }

    struct FitCase: Decodable {
        var name: String
        var ts: [Double]
        var vs: [Double]
        var a: Double
        var b: Double
        var c: Double
        var rms: Double
    }

    struct GravityCase: Decodable {
        var name: String
        var ay_px: Double
        var vx_px_mid: Double
        var vy_px_mid: Double
        var scale_hint: Double?
        var expected: Double?
    }

    struct ObsFixture: Decodable {
        var frame: Int
        var t: Double
        var x: Double
        var y: Double
        var diameter_px: Double
        var area_px: Double

        var observation: BallObservation {
            BallObservation(frame: frame, t: t, x: x, y: y,
                            diameterPx: diameter_px, areaPx: area_px)
        }
    }

    struct MetricsFixture: Decodable {
        var launch_angle_deg: Double
        var exit_velo_mph: Double
        var exit_velo_mps: Double
        var scale_ball_m_per_px: Double
        var scale_gravity_m_per_px: Double?
        var scale_disagreement: Double?
        var diameter_drift: Double
        var n_frames: Int
        var track_duration_s: Double
        var fit_rms_px: Double
        var t0: Double
        var vx_px_s: Double
        var vy_px_s: Double
        var x0_px: Double
        var y0_px: Double
        var flags: [String]
    }

    struct AnalyzeCase: Decodable {
        var name: String
        var contact_time: Double?
        var roll_deg: Double
        var track: [ObsFixture]
        var expected: MetricsFixture
    }

    struct FlightCase: Decodable {
        var name: String
        var ev_mps: Double
        var la_deg: Double
        var contact_height_m: Double
        var carry_m: Double
        var hang_s: Double
        var apex_m: Double
    }

    struct Vy0Case: Decodable {
        var hang_s: Double
        var expected: Double
    }

    struct BatCase: Decodable {
        var name: String
        var vx_px_s: Double
        var vy_px_s: Double
        var scale_m_per_px: Double
        var exit_velo_mps: Double
        var bat_speed_mps: Double
        var bat_speed_mph: Double
        var smash_factor: Double?
        var smash_quality: String
    }

    struct ContactCase: Decodable {
        var name: String
        var ball_y0_px: Double
        var bat_y0_px: Double
        var scale_m_per_px: Double
        var undercut_m: Double
        var undercut_in: Double
        var quality: String
    }

    private static var fixtures: Fixtures!

    override class func setUp() {
        super.setUp()
        let bundle = Bundle(for: ParityTests.self)
        guard let url = bundle.url(forResource: "parity", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("parity.json missing from the test bundle — run `python spike/gen_parity_fixtures.py` and make sure app/Tests/Fixtures is in the test target's resources.")
        }
        do {
            fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
        } catch {
            fatalError("parity.json could not be decoded: \(error)")
        }
    }

    /// Relative comparison with an absolute floor, so values legitimately near
    /// zero (a launch angle of 0.0001 degrees) do not fail on noise.
    private func assertClose(_ actual: Double, _ expected: Double,
                             rel: Double = 1e-6, abs absTol: Double = 1e-9,
                             _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        if actual == expected { return }
        XCTAssertFalse(actual.isNaN && !expected.isNaN, "\(label): got NaN, expected \(expected)",
                       file: file, line: line)
        let tolerance = max(absTol, rel * Swift.abs(expected))
        XCTAssertEqual(actual, expected, accuracy: tolerance,
                       "\(label): Swift \(actual) vs Python \(expected)",
                       file: file, line: line)
    }

    // MARK: - Constants

    func testConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA.g, c["G"]!, "G")
        assertClose(SLA.ballCircumferenceM, c["BALL_CIRCUMFERENCE_M"]!, "ball circumference")
        assertClose(SLA.ballDiameterM, c["BALL_DIAMETER_M"]!, "ball diameter")
        assertClose(SLA.ballMassKg, c["BALL_MASS_KG"]!, "ball mass")
        assertClose(SLA.airDensity, c["AIR_DENSITY"]!, "air density")
        assertClose(SLA.dragCd, c["DRAG_CD"]!, "drag Cd")
        assertClose(SLA.mphPerMps, c["MPH_PER_MPS"]!, "mph per m/s")
        assertClose(SLA.velocityWindowS, c["VELOCITY_WINDOW_S"]!, "velocity window")
        assertClose(SLA.gravityWindowS, c["GRAVITY_WINDOW_S"]!, "gravity window")
        assertClose(SLA.minGravityTrackS, c["MIN_GRAVITY_TRACK_S"]!, "min gravity track")
        assertClose(SLA.scaleDisagreeTol, c["SCALE_DISAGREE_TOL"]!, "scale disagree tol")
        assertClose(SLA.diameterDriftTol, c["DIAMETER_DRIFT_TOL"]!, "diameter drift tol")
        assertClose(SLA.residualTolPx, c["RESIDUAL_TOL_PX"]!, "residual tol")
        assertClose(SLA.diameterProfileStepPx, c["DIAMETER_PROFILE_STEP_PX"]!, "profile step")
        XCTAssertEqual(SLA.minTrackFrames, Int(c["MIN_TRACK_FRAMES"]!))

        // The bundled drag term is the one finding #1 hangs on.
        assertClose(SLA.kOverM, c["k_over_m"]!, rel: 1e-12, "k/m")

        assertClose(SLA.smashPoorBelow, c["SMASH_POOR_BELOW"]!, "smash poor")
        assertClose(SLA.smashGoodLo, c["SMASH_GOOD_LO"]!, "smash good lo")
        assertClose(SLA.smashGoodHi, c["SMASH_GOOD_HI"]!, "smash good hi")
        assertClose(SLA.slowpitchLaunchLo, c["SLOWPITCH_LAUNCH_LO"]!, "slow-pitch launch lo")
        assertClose(SLA.slowpitchLaunchHi, c["SLOWPITCH_LAUNCH_HI"]!, "slow-pitch launch hi")
    }

    // MARK: - Least squares

    func testFitQuadraticMatchesNumPy() {
        for c in Self.fixtures.fit_quadratic {
            let fit = Geometry.fitQuadratic(ts: c.ts, vs: c.vs)
            assertClose(fit.a, c.a, rel: 1e-6, abs: 1e-9, "\(c.name) a")
            assertClose(fit.b, c.b, rel: 1e-6, abs: 1e-9, "\(c.name) b")
            assertClose(fit.c, c.c, rel: 1e-6, abs: 1e-9, "\(c.name) c")
            assertClose(fit.rms, c.rms, rel: 1e-6, abs: 1e-9, "\(c.name) rms")
        }
    }

    // MARK: - Drag-aware scale (finding #1)

    func testSolveGravityScaleMatchesReference() {
        for c in Self.fixtures.solve_gravity_scale {
            let got = Geometry.solveGravityScale(ayPx: c.ay_px,
                                                 vxPxMid: c.vx_px_mid,
                                                 vyPxMid: c.vy_px_mid,
                                                 scaleHint: c.scale_hint)
            switch (got, c.expected) {
            case (nil, nil):
                break
            case let (.some(a), .some(e)):
                assertClose(a, e, rel: 1e-9, "\(c.name)")
            default:
                XCTFail("\(c.name): Swift \(String(describing: got)) vs Python \(String(describing: c.expected))")
            }
        }
    }

    /// The naive scale is what this whole branch of the code exists to avoid.
    /// If someone ever "simplifies" `solveGravityScale` back to `g / ay`, this
    /// says how wrong that is rather than just going red.
    func testNaiveGravityScaleIsMateriallyWrong() {
        guard let c = Self.fixtures.solve_gravity_scale.first(where: { $0.name == "rising_two_roots" }),
              let expected = c.expected else {
            return XCTFail("missing the rising_two_roots fixture")
        }
        let naive = SLA.g / c.ay_px
        let error = abs(naive - expected) / expected
        XCTAssertGreaterThan(error, 0.20,
            "Naive g/ay is only \(error * 100)% off here; the fixture no longer demonstrates why the drag-aware solve is needed.")
    }

    // MARK: - Full analysis

    func testAnalyzeTrackMatchesReference() {
        for c in Self.fixtures.analyze_track {
            let track = c.track.map(\.observation)
            let m = SwingAnalyzer.analyze(track: track,
                                          contactTime: c.contact_time,
                                          rollDeg: c.roll_deg)
            let e = c.expected

            assertClose(m.launchAngleDeg, e.launch_angle_deg, "\(c.name) launch angle")
            assertClose(m.exitVeloMph, e.exit_velo_mph, "\(c.name) exit velo mph")
            assertClose(m.exitVeloMps, e.exit_velo_mps, "\(c.name) exit velo m/s")
            assertClose(m.scaleBallMPerPx, e.scale_ball_m_per_px, "\(c.name) ball scale")
            assertClose(m.diameterDrift, e.diameter_drift, "\(c.name) diameter drift")
            assertClose(m.trackDurationS, e.track_duration_s, "\(c.name) duration")
            assertClose(m.fitRmsPx, e.fit_rms_px, "\(c.name) fit rms")
            assertClose(m.t0, e.t0, "\(c.name) t0")
            assertClose(m.vxPxS, e.vx_px_s, "\(c.name) vx")
            assertClose(m.vyPxS, e.vy_px_s, "\(c.name) vy")
            assertClose(m.x0Px, e.x0_px, "\(c.name) x0")
            assertClose(m.y0Px, e.y0_px, "\(c.name) y0")
            XCTAssertEqual(m.nFrames, e.n_frames, "\(c.name) frame count")

            switch (m.scaleGravityMPerPx, e.scale_gravity_m_per_px) {
            case (nil, nil): break
            case let (.some(a), .some(b)): assertClose(a, b, "\(c.name) gravity scale")
            default: XCTFail("\(c.name): gravity scale presence differs")
            }

            switch (m.scaleDisagreement, e.scale_disagreement) {
            case (nil, nil): break
            case let (.some(a), .some(b)): assertClose(a, b, "\(c.name) disagreement")
            default: XCTFail("\(c.name): disagreement presence differs")
            }

            // Order matters: the flags are appended in a fixed sequence and
            // the CSV export writes them in that order.
            XCTAssertEqual(m.flags.map(\.rawValue), e.flags, "\(c.name) flags")
        }
    }

    /// Every flag should be exercised by at least one fixture, otherwise a
    /// broken flag could go unnoticed.
    func testFixturesCoverEveryFlag() {
        let seen = Set(Self.fixtures.analyze_track.flatMap(\.expected.flags))
        for flag in SwingFlag.allCases {
            XCTAssertTrue(seen.contains(flag.rawValue),
                          "no parity fixture produces \(flag.rawValue)")
        }
    }

    // MARK: - Flight model

    func testSimulateFlightMatchesReference() {
        for c in Self.fixtures.simulate_flight {
            let f = FlightModel.simulate(evMps: c.ev_mps,
                                         laDeg: c.la_deg,
                                         contactHeightM: c.contact_height_m)
            assertClose(f.carryM, c.carry_m, rel: 1e-9, "\(c.name) carry")
            assertClose(f.hangS, c.hang_s, rel: 1e-9, "\(c.name) hang")
            assertClose(f.apexM, c.apex_m, rel: 1e-9, "\(c.name) apex")
        }
    }

    func testVy0FromHangTimeMatchesReference() {
        for c in Self.fixtures.vy0_from_hang_time {
            assertClose(FlightModel.vy0FromHangTime(c.hang_s), c.expected,
                        rel: 1e-12, "vy0(\(c.hang_s))")
        }
    }

    // MARK: - Bat speed + smash factor (learned from b4-app)

    func testBatMetricsMatchReference() {
        for c in Self.fixtures.bat_metrics {
            let bs = SLA.batSpeedMps(vxPxS: c.vx_px_s, vyPxS: c.vy_px_s,
                                     scaleMPerPx: c.scale_m_per_px)
            assertClose(bs, c.bat_speed_mps, rel: 1e-9, "\(c.name) bat speed m/s")
            assertClose(bs * SLA.mphPerMps, c.bat_speed_mph, rel: 1e-9, "\(c.name) bat speed mph")

            let smash = SLA.smashFactor(exitVeloMps: c.exit_velo_mps, batSpeedMps: bs)
            switch (smash, c.smash_factor) {
            case (nil, nil): break
            case let (.some(a), .some(e)): assertClose(a, e, rel: 1e-9, "\(c.name) smash")
            default: XCTFail("\(c.name): smash presence differs")
            }

            XCTAssertEqual(SmashQuality(smash: smash).rawValue, c.smash_quality,
                           "\(c.name) smash quality")
        }
    }

    // MARK: - Contact offset / undercut (side-view-honest Bat Contact Point)

    func testContactOffsetMatchesReference() {
        for c in Self.fixtures.contact_offset {
            let u = SLA.undercutM(ballY0Px: c.ball_y0_px, batY0Px: c.bat_y0_px,
                                  scaleMPerPx: c.scale_m_per_px)
            assertClose(u, c.undercut_m, rel: 1e-9, "\(c.name) undercut m")
            assertClose(u * SLA.inchesPerM, c.undercut_in, rel: 1e-9,
                        "\(c.name) undercut in")
            XCTAssertEqual(ContactQuality(undercutM: u).rawValue, c.quality,
                           "\(c.name) quality")
        }
        XCTAssertEqual(ContactQuality(undercutM: nil), .unknown)
    }

    func testContactConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA.batBarrelDiameterM, c["BAT_BARREL_DIAMETER_M"]!, "barrel diameter")
        assertClose(SLA.inchesPerM, c["INCHES_PER_M"]!, "inches per m")
        assertClose(SLA.contactPlausibleM, c["CONTACT_PLAUSIBLE_M"]!, "plausibility limit")
        assertClose(SLA.undercutToppedBelowM, c["UNDERCUT_TOPPED_BELOW_M"]!, "topped band")
        assertClose(SLA.undercutCenteredMaxM, c["UNDERCUT_CENTERED_MAX_M"]!, "centered band")
        assertClose(SLA.undercutCarryMaxM, c["UNDERCUT_CARRY_MAX_M"]!, "carry band")
    }
}
