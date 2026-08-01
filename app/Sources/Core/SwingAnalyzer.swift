import Foundation

/// Turns a tracked ball path into launch angle + exit velocity, with the
/// confidence flags that decide whether the reading is trustworthy.
///
/// Line-for-line port of `analyze_track` in `spike/sla_common.py`, pinned by
/// `ParityTests`. If you change the logic here, change the Python first,
/// regenerate the fixtures, and let the tests confirm the two still agree.
enum SwingAnalyzer {

    /// - Parameters:
    ///   - track: observations in frame order.
    ///   - contactTime: seconds. When `nil`, the first tracked point is used.
    ///     The batter's body often hides the ball for the first few frames
    ///     after contact, so passing an earlier `contactTime` lets the
    ///     quadratic extrapolate back to the real moment of contact.
    ///   - rollDeg: camera roll correction, CCW positive.
    static func analyze(track: [BallObservation],
                        contactTime: Double? = nil,
                        velocityWindowS: Double = SLA.velocityWindowS,
                        gravityWindowS: Double = SLA.gravityWindowS,
                        rollDeg: Double = 0) -> SwingMetrics {
        precondition(!track.isEmpty, "analyze: empty track")

        var flags: [SwingFlag] = []
        let n = track.count
        let t0 = contactTime ?? track[0].t
        let ts = track.map { $0.t - t0 }
        let xs = track.map { $0.x }
        let ys = track.map { $0.y }
        let ds = track.map { $0.diameterPx }
        let duration = ts[n - 1] - ts[0]

        if n < SLA.minTrackFrames { flags.append(.shortTrack) }

        // --- velocity fit (short window from t0) ---
        // Short on purpose: a constant-acceleration model stays honest against
        // drag only over a brief window right after contact.
        var velSel: [Int]
        if duration > velocityWindowS {
            let cutoff = ts[0] + velocityWindowS
            velSel = (0..<n).filter { ts[$0] <= cutoff }
        } else {
            velSel = Array(0..<n)
        }
        if velSel.count < 3 { velSel = Array(0..<n) }

        let tSel = velSel.map { ts[$0] }
        let fitX = Geometry.fitQuadratic(ts: tSel, vs: velSel.map { xs[$0] })
        let fitY = Geometry.fitQuadratic(ts: tSel, vs: velSel.map { ys[$0] })
        let fitRms = (fitX.rms * fitX.rms + fitY.rms * fitY.rms).squareRoot()
        if fitRms > SLA.residualTolPx { flags.append(.highResidual) }

        // d/dt of (a t^2 + b t + c) at t = 0 (i.e. at t0) is b.
        var vx = fitX.b
        var vy = fitY.b     // down-positive

        if rollDeg != 0 {
            let r = rollDeg * Double.pi / 180
            let cosR = cos(r), sinR = sin(r)
            let rx = vx * cosR - vy * sinR
            let ry = vx * sinR + vy * cosR
            vx = rx
            vy = ry
        }

        // --- diameter scale + depth drift ---
        let q = max(2, n / 4)
        let dFirst = Geometry.median(ds[0..<min(q, n)])
        let dLast = Geometry.median(ds[max(0, n - q)..<n])
        let diameterDrift = dFirst > 0 ? (dLast - dFirst) / dFirst : 0
        if abs(diameterDrift) > SLA.diameterDriftTol { flags.append(.depthMotion) }
        let scaleBall = dFirst > 0 ? SLA.ballDiameterM / dFirst : Double.nan

        // --- gravity fit (longer window, drag-aware) ---
        // y(t) curvature needs time to accumulate (~1/2 g t^2); a short
        // line-drive window has too little sag for a per-swing gravity scale.
        let gravCutoff = ts[0] + gravityWindowS
        let gravSel = (0..<n).filter { ts[$0] <= gravCutoff }
        var scaleGravity: Double?
        if duration >= SLA.minGravityTrackS && gravSel.count >= 6 {
            let tg = gravSel.map { ts[$0] }
            let fitYG = Geometry.fitQuadratic(ts: tg, vs: gravSel.map { ys[$0] })
            let fitXG = Geometry.fitQuadratic(ts: tg, vs: gravSel.map { xs[$0] })
            let ay = 2.0 * fitYG.a                      // px/s^2, down-positive
            // Velocities at the window midpoint, where a quadratic's mean
            // slope lives.
            let tm = (tg[0] + tg[tg.count - 1]) / 2.0
            let vxMid = 2.0 * fitXG.a * tm + fitXG.b
            let vyMid = 2.0 * fitYG.a * tm + fitYG.b
            scaleGravity = Geometry.solveGravityScale(ayPx: ay,
                                                      vxPxMid: vxMid,
                                                      vyPxMid: vyMid,
                                                      scaleHint: scaleBall)
        }
        if scaleGravity == nil { flags.append(.noGravityCheck) }

        var disagreement: Double?
        if let sg = scaleGravity, scaleBall > 0 {
            let d = abs(sg - scaleBall) / scaleBall
            disagreement = d
            if d > SLA.scaleDisagreeTol { flags.append(.scaleDisagree) }
        }

        // --- metrics (launch angle up-positive regardless of hit direction) ---
        let la = atan2(-vy, abs(vx)) * 180 / Double.pi
        let speedMps = (vx * vx + vy * vy).squareRoot() * scaleBall

        return SwingMetrics(
            launchAngleDeg: la,
            exitVeloMph: speedMps * SLA.mphPerMps,
            exitVeloMps: speedMps,
            scaleBallMPerPx: scaleBall,
            scaleGravityMPerPx: scaleGravity,
            scaleDisagreement: disagreement,
            diameterDrift: diameterDrift,
            nFrames: n,
            trackDurationS: duration,
            fitRmsPx: fitRms,
            t0: t0,
            vxPxS: vx,
            vyPxS: vy,
            flags: flags
        )
    }
}
