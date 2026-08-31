// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Constants and small vector maths for the two-phone 3D reconstruction.
///
/// A port of `spike/sla_multiview.py`, pinned number-for-number by
/// `ParityMultiviewTests` against `parity_multiview.json` — the same law that
/// governs `SLA` and `parity.json`, applied to a second reference module. It
/// lives in `SourcesPro/` and compiles only into SwingLabPro, so none of it
/// reaches the shipping app.
///
/// Shared physics constants come from `SLA`; nothing here restates one.
enum SLA3D {

    // MARK: Sync budgets

    /// 1 ms of clock error moves a 30 m/s bat head 30 mm — about the floor
    /// set by 2D keypoint noise, so below this sync stops being the dominant
    /// error and buying more precision buys nothing.
    static let syncBudgetS = 0.001
    /// Above this, 3D metrics are gated (`ProCaptureFlag.syncDegraded`).
    static let syncDegradedS = 0.003

    /// Rolling-shutter readout at 1080p240 — close to the entire 4.17 ms
    /// frame period, so the bottom of the frame is nearly a frame older than
    /// the top. Replaced per device model once measured on an LED bench.
    static let readoutDefaultS = 0.004

    // MARK: Rig geometry

    static let camSeparationMinDeg = 60.0
    static let camSeparationIdealDeg = 90.0
    static let camSeparationMaxDeg = 110.0

    static let minViews = 2
    static let reprojectionRMSMaxPx = 3.0
    static let scaleCheckTol = 0.05
    static let plateWidthM = 0.4318
    static let coverageMin3D = 0.60
    static let resampleMaxGapS = 0.05
    static let segmentAzimuthMinHoriz = 0.2
    /// Deliberately NOT looser than the 2D path: triangulating changes where
    /// positions come from, not how long a parabola must be watched before
    /// its quadratic term is conditioned.
    static let gravityMinSpanS = SLA.minGravityTrackS
    static let launchMinSamples = 8
    /// Ping filter: keep only round trips within this factor of the fastest.
    static let minRTTKeepFactor = 1.25
}

/// Conditions the 3D reference maths can compute from its own inputs.
///
/// Kept separate from `ProCaptureFlag` for the same reason `SwingFlag` and
/// `CaptureFlag` are separate: these are parity-pinned and the fixtures must
/// be able to provoke every one of them.
enum Swing3DFlag: String, Codable, CaseIterable, Sendable {
    case oneViewOnly = "ONE_VIEW_ONLY"
    case lowCoverage = "LOW_COVERAGE_3D"
    case highReprojection = "HIGH_REPROJECTION"
    case resampleGap = "RESAMPLE_GAP"

    var explanation: String {
        switch self {
        case .oneViewOnly:
            return "Only one camera saw this. Two are needed for any 3D reading."
        case .lowCoverage:
            return "The cameras between them saw too little of the movement."
        case .highReprojection:
            return "The two views disagree about where things were — check the rig."
        case .resampleGap:
            return "A camera lost the subject mid-clip; those instants are absent."
        }
    }
}

/// A point or direction in the world frame: metres, +Z up, origin at the
/// resting ball both phones anchored on.
struct Vec3: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    static let zero = Vec3(0, 0, 0)
    static let up = Vec3(0, 0, 1)
    static let down = Vec3(0, 0, -1)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }

    var norm: Double { (x * x + y * y + z * z).squareRoot() }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    static let nan = Vec3(.nan, .nan, .nan)

    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }

    func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    /// `nil` rather than a divide-by-zero: a zero-length direction has no
    /// unit vector, and inventing one hides the caller's real problem.
    func normalized() -> Vec3? {
        let n = norm
        guard n > 1e-12, n.isFinite else { return nil }
        return Vec3(x / n, y / n, z / n)
    }
}

/// Row-major 3x3. Rows of a rotation are the camera's axes in world
/// coordinates — see `CameraExtrinsics`.
struct Mat3: Equatable, Sendable {
    var r0: Vec3
    var r1: Vec3
    var r2: Vec3

    init(_ r0: Vec3, _ r1: Vec3, _ r2: Vec3) { self.r0 = r0; self.r1 = r1; self.r2 = r2 }

    func times(_ v: Vec3) -> Vec3 { Vec3(r0.dot(v), r1.dot(v), r2.dot(v)) }
}
