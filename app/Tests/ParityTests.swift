// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
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
        var focal_px_from_fov: [FocalCase]
        var rectify_tilt: [TiltCase]
        var body_angles: [BodyAngleCase]
        var body_tilts: [BodyTiltCase]
        var body_distances: [BodyDistanceCase]
        var body_strides: [BodyStrideCase]
        var body_drift_gate: [BodyDriftCase]
        var trigger_calibration: [TriggerCalCase]
        var track_straightness: [StraightnessCase]
        var select_track: [SelectCase]
        var build_tracks: [BuildCase]
        var stitch_tracks: [StitchCase]
        var seed_track: [SeedCase]
    }

    struct SeedCase: Decodable {
        struct Obs: Decodable {
            var frame: Int; var t: Double; var x: Double; var y: Double
            var diameter_px: Double; var area_px: Double
        }
        var name: String
        var fps: Double
        var seed_t: Double
        var seed_x: Double
        var seed_y: Double
        var per_frame: [String: [Obs]]
        var expected_len: Int
        var expected_first_frame: Int?
        var expected_last_frame: Int?
    }

    struct StitchCase: Decodable {
        struct Obs: Decodable {
            var frame: Int; var t: Double; var x: Double; var y: Double
            var diameter_px: Double; var area_px: Double
        }
        var name: String
        var tracks: [[Obs]]
        var expected_chain_count: Int
        var expected_chain_lens: [Int]
        var expected_longest_first_frame: Int
        var expected_longest_last_frame: Int
    }

    struct BuildCase: Decodable {
        struct Obs: Decodable {
            var frame: Int; var t: Double; var x: Double; var y: Double
            var diameter_px: Double; var area_px: Double
        }
        var name: String
        var fps: Double
        var per_frame: [String: [Obs]]
        var expected_track_count: Int
        var expected_longest: Int
        var expected_selected_len: Int
        var expected_selected_first_x: Double?
        var expected_selected_last_x: Double?
    }

    struct SelectCase: Decodable {
        struct Obs: Decodable {
            var frame: Int; var t: Double; var x: Double; var y: Double
            var diameter_px: Double; var area_px: Double
        }
        var name: String
        var direction: String
        var tracks: [[Obs]]
        /// `nil` when the reference returns no track at all.
        var expected_index: Int?
    }

    struct StraightnessCase: Decodable {
        struct Point: Decodable { var x: Double; var y: Double }
        var name: String
        var points: [Point]
        var expected: Double
    }

    struct TriggerCalCase: Decodable {
        var name: String
        var background_peak_db: Double
        var quietest_hit_db: Double
        var expected_threshold_db: Double
        var expected_separation_db: Double
        var expected_verdict: String
    }

    /// `expected: nil` means the reference returned NaN. JSON has no NaN, and
    /// NaN is a meaningful result here — a degenerate joint must produce it
    /// rather than a plausible-looking angle — so null carries it.
    struct BodyAngleCase: Decodable {
        var name: String
        var ax: Double, ay: Double, bx: Double, by: Double, cx: Double, cy: Double
        var expected: Double?
    }

    struct BodyTiltCase: Decodable {
        var name: String
        var hip_x: Double, hip_y: Double, shoulder_x: Double, shoulder_y: Double
        var expected: Double?
    }

    struct BodyDistanceCase: Decodable {
        var name: String
        var x0: Double, y0: Double, x1: Double, y1: Double
        var scale_m_per_px: Double
        var expected: Double
    }

    struct BodyStrideCase: Decodable {
        var name: String
        var load_x: Double, contact_x: Double
        var scale_m_per_px: Double
        var expected: Double
    }

    struct BodyDriftCase: Decodable {
        var drift_m: Double?
        var expected: Bool
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
        var undercut_mm: Double
        var quality: String
    }

    struct FocalCase: Decodable {
        var name: String
        var width_px: Double
        var fov_deg: Double
        var expected: Double
    }

    struct TiltCase: Decodable {
        var name: String
        var x: Double
        var y: Double
        var diameter_px: Double
        var tilt_deg: Double
        var focal_px: Double
        var cx: Double
        var cy: Double
        var expected_x: Double
        var expected_y: Double
        var expected_magnification: Double
        var expected_diameter_px: Double
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

    /// Following the ball out from a tap — the path that makes a cluttered
    /// clip measurable at all.
    ///
    /// Pinned including the two cases that must NOT invent an answer: a tap
    /// on empty grass returns nothing (a detection failure, said plainly),
    /// and a tap on clutter follows the clutter, because the user pointed at
    /// it and the honest result is the one they asked for.
    func testSeededTrackingMatchesReference() {
        for (key, value) in [("SEED_SEARCH_RADIUS_PX", SLA.seedSearchRadiusPx),
                             ("SEED_GATE_BASE_PX", SLA.seedGateBasePx),
                             ("SEED_GATE_PREDICTED_PX", SLA.seedGatePredictedPx),
                             ("SEED_GATE_SPEED_MULT", SLA.seedGateSpeedMult),
                             ("SEED_MAX_COAST_FRAMES", Double(SLA.seedMaxCoastFrames)),
                             ("SEED_SPEED_RATIO_MAX", SLA.seedSpeedRatioMax),
                             ("SEED_MAX_TURN_DEG", SLA.seedMaxTurnDeg),
                             ("SEED_OUTLIER_MIN_PX", SLA.seedOutlierMinPx),
                             ("SEED_OUTLIER_SIGMA", SLA.seedOutlierSigma)] {
            XCTAssertEqual(value, Self.fixtures.constants[key]!, accuracy: 1e-12, key)
        }

        let cases = Self.fixtures.seed_track
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            var perFrame: [Int: [BallObservation]] = [:]
            for (key, obs) in c.per_frame {
                guard let f = Int(key) else { continue }
                perFrame[f] = obs.map {
                    BallObservation(frame: $0.frame, t: $0.t, x: $0.x, y: $0.y,
                                    diameterPx: $0.diameter_px, areaPx: $0.area_px)
                }
            }
            let track = TrackBuilder.trackFromSeed(perFrame: perFrame, fps: c.fps,
                                                   t: c.seed_t, x: c.seed_x, y: c.seed_y)
            XCTAssertEqual(track?.count ?? 0, c.expected_len, "seeded length \(c.name)")
            XCTAssertEqual(track?.first?.frame, c.expected_first_frame, "seeded start \(c.name)")
            XCTAssertEqual(track?.last?.frame, c.expected_last_frame, "seeded end \(c.name)")
        }
    }

    /// Re-joining fragments of one flight, and refusing the joins that would
    /// corrupt a measurement: pitch into hit (reverses at contact), descent
    /// into bounce (reverses at the ground), clutter onto anything.
    ///
    /// Pinned because the constants and the greedy order both matter — a port
    /// that stitched in a different order would produce different chains from
    /// identical fragments, and nothing downstream would notice.
    func testStitchTracksMatchesReference() {
        XCTAssertEqual(SLA.stitchMaxGapS,
                       Self.fixtures.constants["STITCH_MAX_GAP_S"]!, accuracy: 1e-12)
        XCTAssertEqual(SLA.stitchBaseTolPx,
                       Self.fixtures.constants["STITCH_BASE_TOL_PX"]!, accuracy: 1e-12)
        XCTAssertEqual(SLA.stitchTolPxPerS,
                       Self.fixtures.constants["STITCH_TOL_PX_PER_S"]!, accuracy: 1e-12)
        XCTAssertEqual(SLA.stitchAccelK,
                       Self.fixtures.constants["STITCH_ACCEL_K"]!, accuracy: 1e-12)
        XCTAssertEqual(SLA.stitchVelocityNoisePxS,
                       Self.fixtures.constants["STITCH_VELOCITY_NOISE_PX_S"]!, accuracy: 1e-12)
        XCTAssertEqual(SLA.stitchMaxAngleDeg,
                       Self.fixtures.constants["STITCH_MAX_ANGLE_DEG"]!, accuracy: 1e-12)
        XCTAssertEqual(Double(SLA.stitchVelocityWindow),
                       Self.fixtures.constants["STITCH_VELOCITY_WINDOW"]!, accuracy: 1e-12)

        let cases = Self.fixtures.stitch_tracks
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let tracks = c.tracks.map { tr in
                tr.map { BallObservation(frame: $0.frame, t: $0.t, x: $0.x, y: $0.y,
                                         diameterPx: $0.diameter_px, areaPx: $0.area_px) }
            }
            let chains = TrackBuilder.stitchTracks(tracks)
            XCTAssertEqual(chains.count, c.expected_chain_count, "chain count \(c.name)")
            XCTAssertEqual(chains.map(\.count).sorted(), c.expected_chain_lens,
                           "chain lengths \(c.name)")
            if let longest = chains.max(by: { $0.count < $1.count }) {
                XCTAssertEqual(longest.first?.frame, c.expected_longest_first_frame,
                               "longest start \(c.name)")
                XCTAssertEqual(longest.last?.frame, c.expected_longest_last_frame,
                               "longest end \(c.name)")
            }
        }
    }

    /// Linking candidates into tracks, on the frame layout that actually
    /// failed in the field: a ball crossing at 30-odd px per frame through a
    /// lawn of stationary clutter blobs, dozens of which sit inside the
    /// association gate of its path.
    ///
    /// Pinned because a ball that survives detection and then fails to LINK is
    /// indistinguishable, from outside, from one that was never detected.
    func testTrackBuildingMatchesReference() {
        let cases = Self.fixtures.build_tracks
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            var perFrame: [Int: [BallObservation]] = [:]
            for (key, obs) in c.per_frame {
                guard let f = Int(key) else { continue }
                perFrame[f] = obs.map {
                    BallObservation(frame: $0.frame, t: $0.t, x: $0.x, y: $0.y,
                                    diameterPx: $0.diameter_px, areaPx: $0.area_px)
                }
            }
            let built = TrackBuilder.buildTracks(perFrame: perFrame, fps: c.fps)
            XCTAssertEqual(built.count, c.expected_track_count, "track count \(c.name)")
            XCTAssertEqual(built.map(\.count).max() ?? 0, c.expected_longest,
                           "longest track \(c.name)")

            let picked = TrackBuilder.selectOutboundTrack(built, direction: .right)
            XCTAssertEqual(picked?.count ?? 0, c.expected_selected_len,
                           "selected length \(c.name)")
            if let first = c.expected_selected_first_x, let last = c.expected_selected_last_x {
                assertClose(picked?.first?.x ?? .nan, first, "selected start \(c.name)")
                assertClose(picked?.last?.x ?? .nan, last, "selected end \(c.name)")
            }
        }
    }

    /// Which track in a clip is the hit.
    ///
    /// The pitch case is the one worth pinning. A lobbed slow-pitch is slow
    /// and hangs in frame for two seconds; a hit is several times faster and
    /// gone in a fraction of one. Scoring on speed TIMES LENGTH cancelled
    /// exactly that difference — the two came out within a percent of each
    /// other — and the pipeline spent a field session measuring the pitch.
    func testTrackSelectionMatchesReference() {
        let cases = Self.fixtures.select_track
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let tracks = c.tracks.map { tr in
                tr.map { BallObservation(frame: $0.frame, t: $0.t, x: $0.x, y: $0.y,
                                         diameterPx: $0.diameter_px, areaPx: $0.area_px) }
            }
            let direction = TrackBuilder.Direction(rawValue: c.direction) ?? .auto
            let picked = TrackBuilder.selectOutboundTrack(tracks, direction: direction)
            if let expected = c.expected_index {
                XCTAssertEqual(picked, tracks[expected], "selection \(c.name)")
            } else {
                XCTAssertNil(picked, "selection \(c.name) should pick nothing")
            }
        }
    }

    /// The gate that separates a ball flight from clutter that merely persists.
    ///
    /// Pinned case by case rather than by spot-check because the failure it
    /// prevents is silent: without it the longest track in a clip wins, and
    /// the longest track is a patch of grass being re-detected for two seconds
    /// while the ball crosses the frame in a fraction of one.
    func testTrackStraightnessMatchesReference() {
        let cases = Self.fixtures.track_straightness
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let track = c.points.enumerated().map { i, p in
                BallObservation(frame: i, t: Double(i) / 240.0,
                                x: p.x, y: p.y, diameterPx: 10, areaPx: 80)
            }
            assertClose(TrackBuilder.straightness(track), c.expected,
                        "straightness \(c.name)")
        }
    }

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

        // Detector defaults are mirrored by hand from sla_common.py. Without
        // these assertions that mirror is convention only, and a venue tuned
        // on the Mac would stop transferring to the app.
        assertClose(SLA.hsvLoDefault.h, c["HSV_LO_H"]!, "hsv lo H")
        assertClose(SLA.hsvLoDefault.s, c["HSV_LO_S"]!, "hsv lo S")
        assertClose(SLA.hsvLoDefault.v, c["HSV_LO_V"]!, "hsv lo V")
        assertClose(SLA.hsvHiDefault.h, c["HSV_HI_H"]!, "hsv hi H")
        assertClose(SLA.hsvHiDefault.s, c["HSV_HI_S"]!, "hsv hi S")
        assertClose(SLA.hsvHiDefault.v, c["HSV_HI_V"]!, "hsv hi V")
        assertClose(SLA.minRadiusPxDefault, c["MIN_RADIUS_PX_DEFAULT"]!, "min radius")
        assertClose(SLA.trackStraightnessMin, c["TRACK_STRAIGHTNESS_MIN"]!, "track straightness min")
        assertClose(SLA.maxRadiusPxDefault, c["MAX_RADIUS_PX_DEFAULT"]!, "max radius")

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
            assertClose(u * 1000, c.undercut_mm, rel: 1e-9,
                        "\(c.name) undercut mm")
            XCTAssertEqual(ContactQuality(undercutM: u).rawValue, c.quality,
                           "\(c.name) quality")
        }
        XCTAssertEqual(ContactQuality(undercutM: nil), .unknown)
    }

    // MARK: - Camera tilt rectification

    func testFocalFromFOVMatchesReference() {
        for c in Self.fixtures.focal_px_from_fov {
            let f = TiltRectifier.focalPx(widthPx: c.width_px, fovDeg: c.fov_deg)
            assertClose(f, c.expected, rel: 1e-9, "\(c.name) focal px")
        }
    }

    func testTiltRectificationMatchesReference() {
        for c in Self.fixtures.rectify_tilt {
            let r = TiltRectifier.rectify(x: c.x, y: c.y, tiltDeg: c.tilt_deg,
                                          focalPx: c.focal_px, cx: c.cx, cy: c.cy)
            assertClose(r.x, c.expected_x, rel: 1e-9, "\(c.name) x")
            assertClose(r.y, c.expected_y, rel: 1e-9, "\(c.name) y")
            assertClose(r.magnification, c.expected_magnification, rel: 1e-9,
                        "\(c.name) magnification")
            assertClose(c.diameter_px * r.magnification, c.expected_diameter_px,
                        rel: 1e-9, "\(c.name) diameter")
        }
    }

    /// The track-level wrapper must agree with the point-level one, and must
    /// leave a zero-tilt track byte-identical — every clip recorded before the
    /// correction existed re-analyses through this path.
    func testTiltRectificationOfATrackIsIdentityAtZeroTilt() {
        let track = Self.fixtures.analyze_track[0].track.map(\.observation)
        let same = TiltRectifier.rectify(track: track, tiltDeg: 0,
                                         focalPx: 1662.77, cx: 960, cy: 540)
        XCTAssertEqual(same, track)
        let noOptics = TiltRectifier.rectify(track: track, tiltDeg: 8,
                                             focalPx: 0, cx: 960, cy: 540)
        XCTAssertEqual(noOptics, track)

        let warped = TiltRectifier.rectify(track: track, tiltDeg: 8,
                                           focalPx: 1662.77, cx: 960, cy: 540)
        XCTAssertEqual(warped.count, track.count)
        for (a, b) in zip(track, warped) {
            let r = TiltRectifier.rectify(x: a.x, y: a.y, tiltDeg: 8,
                                          focalPx: 1662.77, cx: 960, cy: 540)
            assertClose(b.x, r.x, rel: 1e-12, "track x")
            assertClose(b.y, r.y, rel: 1e-12, "track y")
            assertClose(b.diameterPx, a.diameterPx * r.magnification, rel: 1e-12,
                        "track diameter")
            XCTAssertEqual(b.t, a.t)
            XCTAssertEqual(b.frame, a.frame)
        }
    }

    /// Rectifying a tilted view of a level camera's frame must give that frame
    /// back. This is the property the whole correction rests on, and it is not
    /// something a fixture can express — it needs a round trip.
    func testTiltRectificationInvertsAForwardProjection() {
        let f = 1662.77, cx = 960.0, cy = 540.0
        let tilt = 11.0
        let t = tilt * Double.pi / 180
        for level in [(x: 200.0, y: 150.0), (x: 960.0, y: 540.0),
                      (x: 1500.0, y: 820.0), (x: 700.0, y: 960.0)] {
            // Forward: where a camera pitched DOWN by `tilt` would see a point
            // the level camera sees at `level`. Inverse of the rectification.
            let u = level.x - cx, v = level.y - cy
            let d = f * cos(t) + v * sin(t)
            let tiltedX = cx + f * u / d
            let tiltedY = cy + f * (v * cos(t) - f * sin(t)) / d

            let back = TiltRectifier.rectify(x: tiltedX, y: tiltedY,
                                             tiltDeg: tilt, focalPx: f,
                                             cx: cx, cy: cy)
            assertClose(back.x, level.x, rel: 1e-9, abs: 1e-7, "round trip x")
            assertClose(back.y, level.y, rel: 1e-9, abs: 1e-7, "round trip y")
        }
    }

    // MARK: - Body metrics (sagittal plane only)

    func testBodyGeometryMatchesReference() {
        for c in Self.fixtures.body_angles {
            let a = BodyAnalyzer.sagittalAngleDeg(a: CGPoint(x: c.ax, y: c.ay),
                                                  b: CGPoint(x: c.bx, y: c.by),
                                                  c: CGPoint(x: c.cx, y: c.cy))
            guard let expected = c.expected else {
                XCTAssertTrue(a.isNaN, "\(c.name): expected NaN for a degenerate joint")
                continue
            }
            assertClose(a, expected, rel: 1e-9, "\(c.name) angle")
        }
        for c in Self.fixtures.body_tilts {
            let t = BodyAnalyzer.spineTiltDeg(hip: CGPoint(x: c.hip_x, y: c.hip_y),
                                              shoulder: CGPoint(x: c.shoulder_x, y: c.shoulder_y))
            guard let expected = c.expected else {
                XCTAssertTrue(t.isNaN, "\(c.name): expected NaN")
                continue
            }
            assertClose(t, expected, rel: 1e-9, "\(c.name) tilt")
        }
        for c in Self.fixtures.body_distances {
            let d = BodyAnalyzer.planarDistanceM(CGPoint(x: c.x0, y: c.y0),
                                                 CGPoint(x: c.x1, y: c.y1),
                                                 scaleMPerPx: c.scale_m_per_px)
            assertClose(d, c.expected, rel: 1e-9, "\(c.name) distance")
        }
        for c in Self.fixtures.body_strides {
            let d = BodyAnalyzer.strideLengthM(loadX: c.load_x, contactX: c.contact_x,
                                               scaleMPerPx: c.scale_m_per_px)
            assertClose(d, c.expected, rel: 1e-9, "\(c.name) stride")
        }
        for c in Self.fixtures.body_drift_gate {
            XCTAssertEqual(BodyAnalyzer.headDriftPlausible(c.drift_m), c.expected,
                           "drift gate at \(String(describing: c.drift_m))")
        }
    }

    // MARK: - Trigger calibration

    func testTriggerCalibrationMatchesReference() {
        for c in Self.fixtures.trigger_calibration {
            let r = SLA.suggestTriggerDb(backgroundPeakDb: c.background_peak_db,
                                         quietestHitDb: c.quietest_hit_db)
            assertClose(r.thresholdDb, c.expected_threshold_db, rel: 1e-9,
                        "\(c.name) threshold")
            assertClose(r.separationDb, c.expected_separation_db, rel: 1e-9,
                        "\(c.name) separation")
            XCTAssertEqual(r.verdict.rawValue, c.expected_verdict, "\(c.name) verdict")
            // The property the arithmetic exists to guarantee: whatever the
            // inputs, the threshold sits above the background it must clear.
            // Without the floor clamp an inverted measurement would put it
            // underneath and the trigger would fire continuously.
            XCTAssertGreaterThan(r.thresholdDb, c.background_peak_db,
                                 "\(c.name): threshold must clear the background")
        }
    }

    func testTriggerCalibrationConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA.triggerMarginFraction, c["TRIGGER_MARGIN_FRACTION"]!, "margin fraction")
        assertClose(SLA.triggerMinSeparationDb, c["TRIGGER_MIN_SEPARATION_DB"]!, "min separation")
    }

    func testBodyConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA.jointConfidenceMin, c["JOINT_CONFIDENCE_MIN"]!, "joint confidence")
        assertClose(SLA.headDriftImplausibleM, c["HEAD_DRIFT_IMPLAUSIBLE_M"]!, "head drift limit")
    }

    func testContactConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA.batBarrelDiameterM, c["BAT_BARREL_DIAMETER_M"]!, "barrel diameter")
        assertClose(SLA.contactPlausibleM, c["CONTACT_PLAUSIBLE_M"]!, "plausibility limit")
        assertClose(SLA.undercutToppedBelowM, c["UNDERCUT_TOPPED_BELOW_M"]!, "topped band")
        assertClose(SLA.undercutCenteredMaxM, c["UNDERCUT_CENTERED_MAX_M"]!, "centered band")
        assertClose(SLA.undercutCarryMaxM, c["UNDERCUT_CARRY_MAX_M"]!, "carry band")
        assertClose(SLA.tiltCorrectableMaxDeg, c["TILT_CORRECTABLE_MAX_DEG"]!,
                    "tilt correctable limit")
    }
}
