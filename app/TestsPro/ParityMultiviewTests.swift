// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import XCTest
@testable import SwingLabPro

/// Pins the Swift 3D port to `spike/sla_multiview.py`, number for number.
///
/// The sibling of `ParityTests`, for the second reference module. If a value
/// exists in both places and they drift, this is the only thing that will
/// notice — and only if the value is in the fixtures, so new maths adds
/// cases here as well as code there.
///
///     cd spike && python gen_parity_multiview.py
final class ParityMultiviewTests: XCTestCase {

    // MARK: Fixture decoding

    struct Fixtures: Decodable {
        var constants: [String: Double]
        var flag_strings: [String]
        var clock: [ClockCase]
        var resample: [ResampleCase]
        var projection: [ProjectionCase]
        var row_delay: [RowDelayCase]
        var triangulation: [TriangulationCase]
        var rotation: [RotationCase]
        var flight: [FlightCase]
        var series_flags: [SeriesCase]
    }

    struct SampleJSON: Decodable { var t1, t2, t3, t4: Double }
    struct ClockExpect: Decodable {
        var offset_s, skew, t_ref_s, rtt_min_s, ci_s: Double
        var n_used: Int
        var probe_t: [Double]
        var probe_mapped: [Double]
    }
    struct ClockCase: Decodable { var name: String; var samples: [SampleJSON]; var expected: ClockExpect }

    struct ResampleCase: Decodable {
        var name: String; var ts: [Double]; var vs: [Double]
        var grid: [Double]; var expected: [Double?]
    }

    struct ProjectionCase: Decodable {
        var name: String; var fov_deg: Double; var width: Int; var height: Int
        var cam_pos: [Double]; var target: [Double]
        var points: [[Double]]; var expected_uv: [[Double]?]
        var expected_r: [[Double]]; var expected_t: [Double]
    }

    struct RowDelayCase: Decodable { var y, height, readout_s, expected: Double }

    struct RayJSON: Decodable { var az, u, v, w: Double }
    struct TriangulationCase: Decodable {
        var name: String; var separation_deg: Double; var az_a: Double
        var rays: [RayJSON]; var expected_xyz: [Double]; var expected_reproj_px: Double
    }

    struct RotationCase: Decodable {
        var name: String
        var hip_l: [Double]; var hip_r: [Double]; var sh_l: [Double]; var sh_r: [Double]
        var expected_pelvis_az: Double?; var expected_thorax_az: Double?
        var expected_separation: Double?
    }

    struct FlightExpect: Decodable {
        var ev_mph: Double?; var la_deg: Double?; var spray_deg: Double?
        var n_samples: Int?; var gravity_mag: Double?; var gravity_tilt_deg: Double?
    }
    struct FlightCase: Decodable {
        var name: String; var t: [Double]; var xyz: [[Double]]
        var contact_t: Double; var expected: FlightExpect
    }

    struct ViewJSON: Decodable { var az: Double; var us: [Double?]; var vs: [Double?]; var ws: [Double?] }
    struct SeriesExpect: Decodable { var coverage: Double; var flags: [String]; var xyz: [[Double?]] }
    struct SeriesCase: Decodable {
        var name: String; var grid: [Double]; var had_gap: Bool
        var views: [ViewJSON]; var expected: SeriesExpect
    }

    static var fixtures: Fixtures = {
        let url = Bundle(for: ParityMultiviewTests.self)
            .url(forResource: "parity_multiview", withExtension: "json")!
        return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }()

    // MARK: Helpers

    /// Relative comparison with an absolute floor — the same shape
    /// `ParityTests` uses, so a near-zero expected value does not demand
    /// impossible relative precision.
    func assertClose(_ actual: Double, _ expected: Double,
                     rel: Double = 1e-9, abs absTol: Double = 1e-12,
                     _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        if expected.isNaN {
            XCTAssertTrue(actual.isNaN, "\(label): expected NaN, got \(actual)", file: file, line: line)
            return
        }
        let tol = max(absTol, rel * Swift.abs(expected))
        XCTAssertEqual(actual, expected, accuracy: tol, label, file: file, line: line)
    }

    /// Rebuilds the same camera the generator used. `cam()` in
    /// gen_parity_multiview.py is the other half of this pair; both must
    /// change together.
    func camera(az: Double, dist: Double = 6.0, height: Double = 1.1,
                target: Vec3 = Vec3(0, 0, 1)) -> Camera3D {
        let a = az * .pi / 180
        let pos = Vec3(target.x + dist * sin(a), target.y - dist * cos(a), height)
        let intr = CameraIntrinsics.fromFOV(widthPx: 1920, heightPx: 1080, fovDeg: 60)!
        let extr = CameraExtrinsics.lookAt(pos: pos, target: target)!
        return Camera3D(intrinsics: intr, extrinsics: extr)
    }

    // MARK: Constants

    func testConstantsMatchReference() {
        let c = Self.fixtures.constants
        assertClose(SLA3D.syncBudgetS, c["sync_budget_s"]!, rel: 0, abs: 1e-12, "syncBudgetS")
        assertClose(SLA3D.syncDegradedS, c["sync_degraded_s"]!, rel: 0, abs: 1e-12, "syncDegradedS")
        assertClose(SLA3D.readoutDefaultS, c["readout_default_s"]!, rel: 0, abs: 1e-12, "readoutDefaultS")
        assertClose(SLA3D.camSeparationMinDeg, c["cam_sep_min_deg"]!, rel: 0, abs: 1e-12, "sepMin")
        assertClose(SLA3D.camSeparationIdealDeg, c["cam_sep_ideal_deg"]!, rel: 0, abs: 1e-12, "sepIdeal")
        assertClose(SLA3D.camSeparationMaxDeg, c["cam_sep_max_deg"]!, rel: 0, abs: 1e-12, "sepMax")
        XCTAssertEqual(SLA3D.minViews, Int(c["min_views"]!))
        assertClose(SLA3D.reprojectionRMSMaxPx, c["reproj_rms_max_px"]!, rel: 0, abs: 1e-12, "reproj")
        assertClose(SLA3D.scaleCheckTol, c["scale_check_tol"]!, rel: 0, abs: 1e-12, "scaleTol")
        assertClose(SLA3D.plateWidthM, c["plate_width_m"]!, rel: 0, abs: 1e-12, "plate")
        assertClose(SLA3D.coverageMin3D, c["coverage_min_3d"]!, rel: 0, abs: 1e-12, "coverage")
        assertClose(SLA3D.resampleMaxGapS, c["resample_max_gap_s"]!, rel: 0, abs: 1e-12, "gap")
        assertClose(SLA3D.segmentAzimuthMinHoriz, c["segment_azimuth_min_horiz"]!, rel: 0, abs: 1e-12, "azMin")
        assertClose(SLA3D.gravityMinSpanS, c["gravity_min_span_s"]!, rel: 0, abs: 1e-12, "gravSpan")
        XCTAssertEqual(SLA3D.launchMinSamples, Int(c["launch_min_samples"]!))
        assertClose(SLA3D.minRTTKeepFactor, c["min_rtt_keep_factor"]!, rel: 0, abs: 1e-12, "rttKeep")
    }

    /// Every flag the Swift enum can produce must have a fixture that
    /// provokes it. The 3D mirror of `testFixturesCoverEveryFlag`.
    func testFixturesCoverEvery3DFlag() {
        var seen = Set<String>()
        for c in Self.fixtures.series_flags { seen.formUnion(c.expected.flags) }
        for flag in Swing3DFlag.allCases {
            XCTAssertTrue(seen.contains(flag.rawValue),
                          "no parity fixture produces \(flag.rawValue)")
        }
        XCTAssertEqual(Set(Self.fixtures.flag_strings),
                       Set(Swing3DFlag.allCases.map(\.rawValue)),
                       "the Swift enum and the reference disagree about the flag vocabulary")
    }

    // MARK: Clock

    func testClockModelMatchesReference() {
        for c in Self.fixtures.clock {
            let samples = c.samples.map { ClockSample(t1: $0.t1, t2: $0.t2, t3: $0.t3, t4: $0.t4) }
            guard let m = ClockSync3D.fit(samples) else {
                XCTFail("\(c.name): fit returned nil"); continue
            }
            assertClose(m.offsetS, c.expected.offset_s, rel: 1e-9, abs: 1e-12, "\(c.name) offset")
            assertClose(m.skew, c.expected.skew, rel: 1e-9, abs: 1e-15, "\(c.name) skew")
            assertClose(m.tRefS, c.expected.t_ref_s, rel: 1e-9, abs: 1e-12, "\(c.name) tRef")
            assertClose(m.rttMinS, c.expected.rtt_min_s, rel: 1e-9, abs: 1e-15, "\(c.name) rttMin")
            assertClose(m.ciS, c.expected.ci_s, rel: 1e-9, abs: 1e-15, "\(c.name) ci")
            XCTAssertEqual(m.nUsed, c.expected.n_used, "\(c.name) nUsed — the RTT filter kept a different set")
            for (i, t) in c.expected.probe_t.enumerated() {
                assertClose(ClockSync3D.mapToMaster(t, m), c.expected.probe_mapped[i],
                            rel: 1e-9, abs: 1e-12, "\(c.name) map[\(i)]")
            }
        }
    }

    // MARK: Resampling

    func testResamplerMatchesReference() {
        for c in Self.fixtures.resample {
            let got = Resampler3D.pchip(ts: c.ts, vs: c.vs, grid: c.grid)
            XCTAssertEqual(got.count, c.expected.count, "\(c.name) length")
            for (i, e) in c.expected.enumerated() {
                if let e {
                    assertClose(got[i], e, rel: 1e-9, abs: 1e-12, "\(c.name)[\(i)]")
                } else {
                    XCTAssertTrue(got[i].isNaN,
                                  "\(c.name)[\(i)]: reference says absent, port produced \(got[i])")
                }
            }
        }
    }

    // MARK: Camera

    func testProjectionMatchesReference() {
        for c in Self.fixtures.projection {
            let cam = camera(az: 0)
            let r = cam.extrinsics.r
            let rows = [[r.r0.x, r.r0.y, r.r0.z], [r.r1.x, r.r1.y, r.r1.z], [r.r2.x, r.r2.y, r.r2.z]]
            for i in 0..<3 {
                for j in 0..<3 {
                    assertClose(rows[i][j], c.expected_r[i][j], rel: 1e-9, abs: 1e-12,
                                "\(c.name) r[\(i)][\(j)]")
                }
            }
            let t = cam.extrinsics.t
            for (j, v) in [t.x, t.y, t.z].enumerated() {
                assertClose(v, c.expected_t[j], rel: 1e-9, abs: 1e-12, "\(c.name) t[\(j)]")
            }
            for (i, p) in c.points.enumerated() {
                let uv = cam.project(Vec3(p[0], p[1], p[2]))
                if let e = c.expected_uv[i] {
                    XCTAssertNotNil(uv, "\(c.name) point \(i) should project")
                    assertClose(uv!.x, e[0], rel: 1e-9, abs: 1e-9, "\(c.name) u[\(i)]")
                    assertClose(uv!.y, e[1], rel: 1e-9, abs: 1e-9, "\(c.name) v[\(i)]")
                } else {
                    XCTAssertNil(uv, "\(c.name) point \(i) is behind the camera and must not project")
                }
            }
        }
    }

    func testRowDelayMatchesReference() {
        for c in Self.fixtures.row_delay {
            assertClose(Camera3D.rowDelayS(y: c.y, heightPx: c.height, readoutS: c.readout_s),
                        c.expected, rel: 1e-12, abs: 1e-15, "rowDelay y=\(c.y)")
        }
    }

    // MARK: Triangulation

    func testTriangulationMatchesReference() {
        for c in Self.fixtures.triangulation {
            let rays = c.rays.map {
                Ray3D(camera: camera(az: $0.az), u: $0.u, v: $0.v, weight: $0.w)
            }
            guard let got = Triangulator3D.triangulate(rays) else {
                XCTFail("\(c.name): triangulate returned nil"); continue
            }
            // Looser than the other suites on purpose: the eigen solve is a
            // fixed-sweep Jacobi here and LAPACK in NumPy, so the two agree
            // on the answer rather than on the arithmetic path to it.
            assertClose(got.point.x, c.expected_xyz[0], rel: 1e-6, abs: 1e-9, "\(c.name) x")
            assertClose(got.point.y, c.expected_xyz[1], rel: 1e-6, abs: 1e-9, "\(c.name) y")
            assertClose(got.point.z, c.expected_xyz[2], rel: 1e-6, abs: 1e-9, "\(c.name) z")
            assertClose(got.reprojectionPx, c.expected_reproj_px, rel: 1e-4, abs: 1e-6,
                        "\(c.name) reprojection")
        }
    }

    func testMismatchedCorrespondenceIsCaught() {
        guard let c = Self.fixtures.triangulation
            .first(where: { $0.name.contains("mismatched") }) else {
            XCTFail("the mismatched-correspondence case is missing"); return
        }
        XCTAssertGreaterThan(c.expected_reproj_px, SLA3D.reprojectionRMSMaxPx * 10,
                             "two views following different objects must blow up the reprojection — that is the guard two cameras have and one never did")
    }

    // MARK: Rotation

    func testRotationMetricsMatchReference() {
        for c in Self.fixtures.rotation {
            let hl = Vec3(c.hip_l[0], c.hip_l[1], c.hip_l[2])
            let hr = Vec3(c.hip_r[0], c.hip_r[1], c.hip_r[2])
            let sl = Vec3(c.sh_l[0], c.sh_l[1], c.sh_l[2])
            let sr = Vec3(c.sh_r[0], c.sh_r[1], c.sh_r[2])

            let pelvis = Metrics3D.segmentAzimuthDeg(left: hl, right: hr)
            if let e = c.expected_pelvis_az {
                assertClose(pelvis ?? .nan, e, rel: 1e-9, abs: 1e-9, "\(c.name) pelvis")
            } else {
                XCTAssertNil(pelvis, "\(c.name): a near-vertical segment must have no azimuth")
            }
            let sep = Metrics3D.hipShoulderSeparationDeg(hipL: hl, hipR: hr,
                                                         shoulderL: sl, shoulderR: sr)
            if let e = c.expected_separation {
                assertClose(sep ?? .nan, e, rel: 1e-9, abs: 1e-9, "\(c.name) separation")
            } else {
                XCTAssertNil(sep, "\(c.name): separation must be absent, not guessed")
            }
        }
    }

    // MARK: Flight

    func testFlightMetricsMatchReference() {
        for c in Self.fixtures.flight {
            let xyz = c.xyz.map { Vec3($0[0], $0[1], $0[2]) }
            let lm = Metrics3D.launch(t: c.t, xyz: xyz, contactT: c.contact_t)
            if let e = c.expected.ev_mph {
                XCTAssertNotNil(lm, "\(c.name): launch fit should succeed")
                assertClose(lm!.evMph, e, rel: 1e-7, abs: 1e-9, "\(c.name) EV")
                assertClose(lm!.laDeg, c.expected.la_deg!, rel: 1e-7, abs: 1e-9, "\(c.name) LA")
                assertClose(lm!.sprayDeg, c.expected.spray_deg!, rel: 1e-7, abs: 1e-9, "\(c.name) spray")
                XCTAssertEqual(lm!.nSamples, c.expected.n_samples!, "\(c.name) sample count")
            }
            let g = Metrics3D.gravityMagnitude(t: c.t, xyz: xyz)
            if let e = c.expected.gravity_mag {
                assertClose(g ?? .nan, e, rel: 1e-7, abs: 1e-9, "\(c.name) |g|")
            } else {
                XCTAssertNil(g, "\(c.name): too short a track must report no gravity, not a bad one")
            }
            let tilt = Metrics3D.gravityTiltDeg(t: c.t, xyz: xyz)
            if let e = c.expected.gravity_tilt_deg {
                assertClose(tilt ?? .nan, e, rel: 1e-6, abs: 1e-9, "\(c.name) tilt")
            } else {
                XCTAssertNil(tilt, "\(c.name): no gravity means no tilt either")
            }
        }
    }

    /// The reason `gravityTiltDeg` exists at all: a rig rotated bodily out
    /// of the world frame preserves lengths, so |g| cannot see it.
    func testGravityMagnitudeIsBlindToRigRotation() {
        guard let c = Self.fixtures.flight.first(where: { $0.name.contains("rolled") }),
              let mag = c.expected.gravity_mag, let tilt = c.expected.gravity_tilt_deg else {
            XCTFail("the rolled-rig case is missing"); return
        }
        XCTAssertLessThan(Swift.abs(mag / SLA.g - 1), 0.01,
                          "a 5 degree roll should leave |g| looking fine — that is the blindness")
        XCTAssertGreaterThan(tilt, 4.0,
                             "...and the tilt is what actually catches it")
    }

    // MARK: Series

    func testSeriesFlagsMatchReference() {
        for c in Self.fixtures.series_flags {
            let views = c.views.map { v -> (camera: Camera3D, us: [Double], vs: [Double], ws: [Double]) in
                (camera: camera(az: v.az),
                 us: v.us.map { $0 ?? .nan },
                 vs: v.vs.map { $0 ?? .nan },
                 ws: v.ws.map { $0 ?? .nan })
            }
            let tr = Triangulator3D.series(grid: c.grid, views: views, hadGap: c.had_gap)
            assertClose(tr.coverage, c.expected.coverage, rel: 1e-9, abs: 1e-12, "\(c.name) coverage")
            XCTAssertEqual(tr.flags.map(\.rawValue), c.expected.flags,
                           "\(c.name): flags differ — order is pinned, not just membership")
            for (i, e) in c.expected.xyz.enumerated() {
                if e[0] == nil {
                    XCTAssertFalse(tr.xyz[i].isFinite,
                                   "\(c.name)[\(i)]: reference says absent, port produced a point")
                }
            }
        }
    }
}
