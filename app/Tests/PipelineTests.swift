// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreGraphics
import ImageIO
import XCTest
@testable import SwingLab

/// Tests for the parts of the app that have no Python counterpart: track
/// association, the CSV bridge back to the spike, and the go/no-go scoreboard.
final class PipelineTests: XCTestCase {

    // MARK: - Helpers

    private func straightTrack(frames: Int,
                              fps: Double = 240,
                              x0: Double = 100,
                              y0: Double = 800,
                              vx: Double = 4000,
                              vy: Double = -1200,
                              diameter: Double = 24.3,
                              startFrame: Int = 0) -> [BallObservation] {
        (0..<frames).map { i in
            let t = Double(startFrame + i) / fps
            let dt = Double(i) / fps
            return BallObservation(frame: startFrame + i, t: t,
                                   x: x0 + vx * dt,
                                   y: y0 + vy * dt + 0.5 * 2450 * dt * dt,
                                   diameterPx: diameter,
                                   areaPx: Double.pi * (diameter / 2) * (diameter / 2))
        }
    }

    private func perFrame(_ tracks: [[BallObservation]]) -> [Int: [BallObservation]] {
        var out: [Int: [BallObservation]] = [:]
        for track in tracks {
            for o in track { out[o.frame, default: []].append(o) }
        }
        return out
    }

    // MARK: - Track building

    func testBuildTracksLinksAFastBall() {
        let truth = straightTrack(frames: 30)
        let tracks = TrackBuilder.buildTracks(perFrame: perFrame([truth]), fps: 240)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.count, 30)
    }

    func testBuildTracksCoastsThroughAMissedFrame() {
        var frames = perFrame([straightTrack(frames: 30)])
        // The batter's body hides the ball for two frames.
        frames[10] = nil
        frames[11] = nil
        let tracks = TrackBuilder.buildTracks(perFrame: frames, fps: 240)
        XCTAssertEqual(tracks.count, 1, "a two-frame gap should not split the track")
        XCTAssertEqual(tracks.first?.count, 28)
    }

    func testBuildTracksRejectsStationaryClutter() {
        // A fixed bright speck — a reflection off the net, say.
        let clutter = (0..<30).map { i in
            BallObservation(frame: i, t: Double(i) / 240,
                            x: 600, y: 300, diameterPx: 12, areaPx: 113)
        }
        let tracks = TrackBuilder.buildTracks(perFrame: perFrame([straightTrack(frames: 30), clutter]),
                                              fps: 240)
        let chosen = TrackBuilder.selectOutboundTrack(tracks)
        XCTAssertNotNil(chosen)
        // The hit ball moves; the speck does not, so it must lose.
        let dt = (chosen!.last!.t - chosen!.first!.t)
        let speed = abs(chosen!.last!.x - chosen!.first!.x) / dt
        XCTAssertGreaterThan(speed, 1000)
    }

    func testSelectOutboundTrackPrefersTheHitOverThePitch() {
        // Inbound pitch: slower, travelling the other way.
        let pitch = straightTrack(frames: 20, x0: 1800, vx: -1200, vy: 200)
        let hit = straightTrack(frames: 30, x0: 200, vx: 4200, vy: -1300)
        let tracks = TrackBuilder.buildTracks(perFrame: perFrame([pitch, hit]), fps: 240)
        guard let chosen = TrackBuilder.selectOutboundTrack(tracks, direction: .right) else {
            return XCTFail("no track selected")
        }
        XCTAssertGreaterThan(chosen.last!.x, chosen.first!.x, "should have picked the outbound hit")
    }

    // MARK: - CSV bridge

    func testTrackCSVRoundTrips() {
        let track = straightTrack(frames: 12)
        let csv = TrackCSV.serialize(track: track, fps: 240,
                                     meta: [("clip", "tee_01.mov"),
                                            ("contact_time", "0.125000")])
        let parsed = TrackCSV.parse(csv)
        XCTAssertEqual(parsed.track.count, track.count)
        XCTAssertEqual(parsed.fps, 240)
        XCTAssertEqual(parsed.contactTime, 0.125)
        XCTAssertEqual(parsed.meta["clip"], "tee_01.mov")
        for (a, b) in zip(parsed.track, track) {
            XCTAssertEqual(a.frame, b.frame)
            XCTAssertEqual(a.x, b.x, accuracy: 0.01)
            XCTAssertEqual(a.y, b.y, accuracy: 0.01)
            XCTAssertEqual(a.diameterPx, b.diameterPx, accuracy: 0.01)
        }
    }

    func testTrackCSVHeaderMatchesReferenceFormat() {
        let csv = TrackCSV.serialize(track: straightTrack(frames: 3), fps: 240)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("# fps=240.0"))
        XCTAssertTrue(lines.contains("frame,t,x_px,y_px,diameter_px,area_px"),
                      "analyze_swing.py reads these exact column names")
    }

    // MARK: - Scoreboard

    private func swing(_ setting: SwingSetting,
                       frames: Int = 30,
                       ev: Double = 70,
                       la: Double = 20,
                       disagreement: Double? = 0.02,
                       auto: Bool = true) -> SwingDTO {
        var s = SwingDTO()
        s.setting = setting
        s.trackedFrames = frames
        s.exitVeloMph = ev
        s.launchAngleDeg = la
        s.scaleDisagreement = disagreement
        s.autoTriggered = auto
        return s
    }

    func testScoreboardCountsUntrackedClipsAgainstG1() {
        let swings = [swing(.tee), swing(.tee), swing(.tee, frames: 0)]
        let board = ValidationScoreboard.build(from: swings)
        let row = board.g1.first { $0.setting == .tee }
        XCTAssertEqual(row?.tracked, 2)
        XCTAssertEqual(row?.total, 3, "a clip with no track is still a clip")
        XCTAssertEqual(row?.passes, false, "2/3 is below the 90% tee threshold")
    }

    func testScoreboardG2ExcludesIndoorClips() {
        let swings = [
            swing(.tee, disagreement: 0.02),
            swing(.tee, disagreement: 0.04),
            swing(.cage, disagreement: 0.50),   // must not drag the median
        ]
        let board = ValidationScoreboard.build(from: swings)
        XCTAssertEqual(board.g2Count, 2)
        XCTAssertEqual(board.g2MedianPct!, 3.0, accuracy: 1e-9)
        XCTAssertEqual(board.g2Passes, true)
    }

    func testScoreboardG4NeedsThreeIdenticalIntentSwings() {
        var board = ValidationScoreboard.build(from: [swing(.teeid), swing(.teeid)])
        XCTAssertNil(board.g4EvSd)

        board = ValidationScoreboard.build(from: [
            swing(.teeid, ev: 70, la: 20),
            swing(.teeid, ev: 71, la: 21),
            swing(.teeid, ev: 69, la: 19),
        ])
        XCTAssertEqual(board.g4EvSd!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(board.g4LaSd!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(board.g4EvPasses, true)
    }

    func testVerdictIsFullStopWhenOutdoorTeeFails() {
        var swings = (0..<10).map { _ in swing(.tee, frames: 0) }   // nothing tracked
        swings += [swing(.teeid, ev: 70), swing(.teeid, ev: 71), swing(.teeid, ev: 69)]
        let board = ValidationScoreboard.build(from: swings)
        XCTAssertEqual(board.verdict, .noGo)
        XCTAssertTrue(board.verdictExplanation.contains("full stop"))
    }

    func testVerdictDemotesCageWithoutBlockingOutdoor() {
        var swings = (0..<10).map { _ in swing(.tee) }
        swings += [swing(.teeid, ev: 70), swing(.teeid, ev: 71), swing(.teeid, ev: 69)]
        swings += (0..<10).map { _ in swing(.cage, frames: 0) }
        let board = ValidationScoreboard.build(from: swings)
        XCTAssertEqual(board.verdict, .goOutdoorOnly)
    }

    func testThroughNetFailureDoesNotBlock() {
        var swings = (0..<10).map { _ in swing(.tee) }
        swings += [swing(.teeid, ev: 70), swing(.teeid, ev: 71), swing(.teeid, ev: 69)]
        swings += (0..<3).map { _ in swing(.net, frames: 0) }
        let board = ValidationScoreboard.build(from: swings)
        XCTAssertEqual(board.verdict, .go, "through-the-net is an expected failure, not a gate")
        XCTAssertNil(board.g1.first { $0.setting == .net }?.passes)
    }

    func testG5CountsManualTriggersAsMisses() {
        let swings = (0..<10).map { i in swing(.tee, auto: i < 8) }
        let board = ValidationScoreboard.build(from: swings)
        XCTAssertEqual(board.g5AutoTriggered, 8)
        XCTAssertEqual(board.g5Passes, false, "80% is under the 90% G5 bar")
    }

    // MARK: - Vision coordinate mapping

    /// Vision reports normalized points on the ORIENTED image with the origin
    /// bottom-left; the buffer — and AVFoundation's capture-device point — is
    /// top-left with y down. Getting this backwards does not crash or warn: the
    /// skeleton simply lands somewhere plausible-looking and every body metric
    /// is quietly measured off the wrong pixels.
    func testVisionUpMappingIsAYFlipOnly() {
        let bottomLeft = VisionGeometry.devicePoint(fromVision: CGPoint(x: 0, y: 0),
                                                    orientation: .up)
        XCTAssertEqual(bottomLeft.x, 0, accuracy: 1e-12)
        XCTAssertEqual(bottomLeft.y, 1, accuracy: 1e-12, "Vision y=0 is the BOTTOM of the image")
        let topRight = VisionGeometry.devicePoint(fromVision: CGPoint(x: 1, y: 1),
                                                  orientation: .up)
        XCTAssertEqual(topRight.x, 1, accuracy: 1e-12)
        XCTAssertEqual(topRight.y, 0, accuracy: 1e-12)
    }

    /// One corner, through every orientation the capture path can produce.
    ///
    /// The hitter's head in the top-left of the upright picture is Vision
    /// (0, 1). Where that pixel lives in the buffer depends entirely on how the
    /// phone was lying on the tripod.
    func testVisionRotationsLandTheHeadInTheRightCorner() {
        let headTopLeftOfUprightImage = CGPoint(x: 0, y: 1)
        // .up — the buffer is already upright.
        var p = VisionGeometry.devicePoint(fromVision: headTopLeftOfUprightImage, orientation: .up)
        XCTAssertEqual(p.x, 0, accuracy: 1e-12); XCTAssertEqual(p.y, 0, accuracy: 1e-12)
        // .down — the buffer is upside down, so it is the buffer's bottom-right.
        p = VisionGeometry.devicePoint(fromVision: headTopLeftOfUprightImage, orientation: .down)
        XCTAssertEqual(p.x, 1, accuracy: 1e-12); XCTAssertEqual(p.y, 1, accuracy: 1e-12)
        // .right — the buffer's 0th row displays on the right, 0th column at
        // the top, so the upright top-left is the buffer's top-right.
        p = VisionGeometry.devicePoint(fromVision: headTopLeftOfUprightImage, orientation: .right)
        XCTAssertEqual(p.x, 0, accuracy: 1e-12); XCTAssertEqual(p.y, 1, accuracy: 1e-12)
        // .left — the mirror of that.
        p = VisionGeometry.devicePoint(fromVision: headTopLeftOfUprightImage, orientation: .left)
        XCTAssertEqual(p.x, 1, accuracy: 1e-12); XCTAssertEqual(p.y, 0, accuracy: 1e-12)
    }

    /// Every rotation must be a bijection of the unit square onto itself: no
    /// orientation may fold, squash or push a point outside the frame.
    func testVisionMappingIsARigidRemapForEveryOrientation() {
        let samples = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                       CGPoint(x: 0.25, y: 0.6), CGPoint(x: 0.9, y: 0.1)]
        for orientation in [CGImagePropertyOrientation.up, .down, .left, .right] {
            var seen = Set<String>()
            for s in samples {
                let p = VisionGeometry.devicePoint(fromVision: s, orientation: orientation)
                XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y),
                              "\(orientation) sent \(s) to \(p)")
                seen.insert("\(p.x),\(p.y)")
            }
            XCTAssertEqual(seen.count, samples.count, "\(orientation) collapsed distinct points")
        }
    }

    func testVisionImagePointUsesBufferDimensions() {
        // A landscape buffer read as a portrait upright image: the helper must
        // scale by the BUFFER's width and height, not the oriented image's.
        let p = VisionGeometry.imagePoint(fromVision: CGPoint(x: 0.5, y: 0.5),
                                          orientation: .right,
                                          width: 1920, height: 1080)
        XCTAssertEqual(p.x, 960, accuracy: 1e-9)
        XCTAssertEqual(p.y, 540, accuracy: 1e-9)
    }

    // MARK: - Body metrics

    /// The front leg is picked from the ball's direction, so a hitter who bats
    /// the other way round is handled without asking them anything.
    func testFrontLegFollowsTheBallDirection() {
        let joints: [PoseJoint: PosePoint] = [
            .leftAnkle: PosePoint(x: 400, y: 900, confidence: 0.9),
            .rightAnkle: PosePoint(x: 600, y: 900, confidence: 0.9),
            .leftHip: PosePoint(x: 470, y: 560, confidence: 0.9),
            .rightHip: PosePoint(x: 560, y: 560, confidence: 0.9),
            .leftKnee: PosePoint(x: 440, y: 730, confidence: 0.9),
            .rightKnee: PosePoint(x: 590, y: 730, confidence: 0.9),
            .leftShoulder: PosePoint(x: 480, y: 330, confidence: 0.9),
            .rightShoulder: PosePoint(x: 570, y: 330, confidence: 0.9),
            .nose: PosePoint(x: 525, y: 250, confidence: 0.9),
        ]
        let track = [PoseObservation(frame: 0, t: 0.0, joints: joints),
                     PoseObservation(frame: 60, t: 0.25, joints: joints)]

        // Ball leaving toward decreasing x: the LEFT ankle (x 400) is in front.
        let left = BodyAnalyzer.analyze(track: track, contactTime: 0.25,
                                        scaleMPerPx: 1.0 / 240, ballDirectionX: -1)
        XCTAssertNotNil(left.frontKneeDeg)
        // Ball leaving toward increasing x: the RIGHT leg leads, and its knee
        // is bent differently, so the reading must change.
        let right = BodyAnalyzer.analyze(track: track, contactTime: 0.25,
                                         scaleMPerPx: 1.0 / 240, ballDirectionX: 1)
        XCTAssertNotNil(right.frontKneeDeg)
        XCTAssertNotEqual(left.frontKneeDeg!, right.frontKneeDeg!,
                          "the two legs are not mirror images here, so the readings must differ")
    }

    /// A joint below the confidence floor is absent, not a guess — otherwise a
    /// body metric gets computed off a position the model did not believe.
    func testLowConfidenceJointsAreTreatedAsMissing() {
        let obs = PoseObservation(frame: 0, t: 0, joints: [
            .leftHip: PosePoint(x: 100, y: 100, confidence: 0.9),
            .rightHip: PosePoint(x: 140, y: 100, confidence: 0.05),
        ])
        XCTAssertNotNil(obs.point(.leftHip))
        XCTAssertNil(obs.point(.rightHip), "below SLA.jointConfidenceMin")
        XCTAssertNil(obs.midpoint(.leftHip, .rightHip),
                     "a hip centre from one hip would move half a body width between frames")
    }

    /// Angles survive a missing scale; distances do not, and must not be
    /// invented from one.
    func testAnglesSurviveAMissingScaleButDistancesDoNot() {
        let joints: [PoseJoint: PosePoint] = [
            .leftAnkle: PosePoint(x: 400, y: 900, confidence: 0.9),
            .rightAnkle: PosePoint(x: 600, y: 900, confidence: 0.9),
            .leftHip: PosePoint(x: 470, y: 560, confidence: 0.9),
            .rightHip: PosePoint(x: 560, y: 560, confidence: 0.9),
            .leftKnee: PosePoint(x: 440, y: 730, confidence: 0.9),
            .leftShoulder: PosePoint(x: 480, y: 330, confidence: 0.9),
            .rightShoulder: PosePoint(x: 570, y: 330, confidence: 0.9),
            .nose: PosePoint(x: 525, y: 250, confidence: 0.9),
        ]
        let track = [PoseObservation(frame: 0, t: 0.0, joints: joints),
                     PoseObservation(frame: 60, t: 0.25, joints: joints)]
        let m = BodyAnalyzer.analyze(track: track, contactTime: 0.25,
                                     scaleMPerPx: nil, ballDirectionX: -1)
        XCTAssertNotNil(m.frontKneeDeg)
        XCTAssertNotNil(m.spineTiltDeg)
        XCTAssertNil(m.strideM)
        XCTAssertNil(m.headDriftM)
        XCTAssertNil(m.weightShiftM)
    }

    /// An implausible head reading is withheld, not shown: the hitter has no
    /// way to tell it is the pose model's mistake rather than their swing.
    func testImplausibleHeadDriftIsWithheld() {
        func obs(_ t: Double, headX: Double) -> PoseObservation {
            PoseObservation(frame: Int(t * 240), t: t, joints: [
                .nose: PosePoint(x: headX, y: 250, confidence: 0.9),
                .leftHip: PosePoint(x: 470, y: 560, confidence: 0.9),
                .rightHip: PosePoint(x: 560, y: 560, confidence: 0.9),
            ])
        }
        // 300 px at 1/240 m/px is 1.25 m of "head movement".
        let m = BodyAnalyzer.analyze(track: [obs(0, headX: 200), obs(0.25, headX: 500)],
                                     contactTime: 0.25,
                                     scaleMPerPx: 1.0 / 240, ballDirectionX: -1)
        XCTAssertNil(m.headDriftM)
        // ...but an ordinary one survives.
        let ok = BodyAnalyzer.analyze(track: [obs(0, headX: 500), obs(0.25, headX: 520)],
                                      contactTime: 0.25,
                                      scaleMPerPx: 1.0 / 240, ballDirectionX: -1)
        XCTAssertNotNil(ok.headDriftM)
    }

    // MARK: - Camera tilt sign convention

    /// Pins the one number in the tilt correction that cannot be caught by a
    /// parity fixture: which way round "tilt" points. `TiltRectifier` is pinned
    /// against the Python for a *given* angle; nothing else checks that the IMU
    /// hands it that angle with the sign it expects. Get this backwards and the
    /// rectification doubles the projection error rather than removing it, with
    /// no symptom beyond numbers being further off than before.
    func testTiltIsPositiveWhenTheLensAimsDown() {
        // Flat on a table, screen up: the rear lens stares at the table.
        XCTAssertEqual(LevelSensor.tiltDown(gravityZ: -1), 90, accuracy: 1e-9)
        // Face down: the lens stares at the sky.
        XCTAssertEqual(LevelSensor.tiltDown(gravityZ: 1), -90, accuracy: 1e-9)
        // Upright in portrait on a level tripod: the lens is horizontal.
        XCTAssertEqual(LevelSensor.tiltDown(gravityZ: 0), 0, accuracy: 1e-9)
        // Out-of-range input from a noisy sample must clamp, not produce NaN.
        XCTAssertEqual(LevelSensor.tiltDown(gravityZ: -1.0001), 90, accuracy: 1e-9)
        XCTAssertFalse(LevelSensor.tiltDown(gravityZ: 1.0001).isNaN)
    }

    /// The bug this replaced: in landscape the bubble slammed into one end of
    /// the beam and stayed there, the opposite end in each landscape, while the
    /// horizon line said the camera was level. The old code subtracted a
    /// quarter turn chosen by `switch` on `landscapeLeft` / `landscapeRight`,
    /// and with that sign inverted a landscape phone reads ±90 − (∓90) = ±180.
    ///
    /// Nothing could have caught it here: reading `interfaceOrientation` needs
    /// a live `UIApplication`. Measuring the deviation from the nearest quarter
    /// turn is the same quantity with no orientation API in it, so a test can
    /// hold it — and roll is subtracted from every launch angle, so an
    /// unpinnable roll is not an acceptable state for this to be in.
    func testRollIsMeasuredFromTheNearestQuarterTurn() {
        // Square in every orientation reads zero, including upside-down.
        for square in [-180.0, -90, 0, 90, 180] {
            XCTAssertEqual(LevelSensor.rollOffSquare(portraitDeg: square), 0,
                           accuracy: 1e-9, "\(square)° is square")
        }
        // The same 2° error, in each of the four, with the same sign.
        for square in [-90.0, 0, 90, 180] {
            XCTAssertEqual(LevelSensor.rollOffSquare(portraitDeg: square + 2), 2,
                           accuracy: 1e-9, "2° off \(square)°")
            XCTAssertEqual(LevelSensor.rollOffSquare(portraitDeg: square - 2), -2,
                           accuracy: 1e-9, "−2° off \(square)°")
        }
        // Wrapping: −179 is 1° the other side of upside-down, not 181° off.
        XCTAssertEqual(LevelSensor.rollOffSquare(portraitDeg: -179), 1,
                       accuracy: 1e-9)
        // Never reports more than half a quarter turn, whatever it is handed.
        for deg in stride(from: -180.0, through: 180.0, by: 0.5) {
            XCTAssertLessThanOrEqual(abs(LevelSensor.rollOffSquare(portraitDeg: deg)),
                                     45 + 1e-9, "\(deg)° folded past 45°")
        }
    }

    /// A short tripod aimed up at contact height is the case the correction
    /// exists for. Aiming up puts everything *lower* in the frame than a level
    /// camera would, so rectifying must lift it back up — and by exactly the
    /// tilt angle, since a pinhole rotation just adds angles.
    func testAimingUpLiftsTheBallBackUpTheFrame() {
        let f = TiltRectifier.focalPx(widthPx: 1920, fovDeg: 60)
        let up = LevelSensor.tiltDown(gravityZ: sin(10 * Double.pi / 180))
        XCTAssertLessThan(up, 0, "aiming up must read negative")

        let r = TiltRectifier.rectify(x: 960, y: 300, tiltDeg: up,
                                      focalPx: f, cx: 960, cy: 540)
        XCTAssertLessThan(r.y, 300, "rectified ball should sit higher in frame")
        XCTAssertEqual(r.x, 960, accuracy: 1e-9, "on-axis x must not move")
        XCTAssertGreaterThan(r.magnification, 1,
                             "aiming up magnifies above the axis, so the ball reads bigger")

        // The angle-addition identity the homography reduces to on-axis:
        // a point at angle a below the tilted axis is at a + tilt below level.
        let alpha = atan((300.0 - 540) / f)
        let expected = 540 + f * tan(alpha + up * Double.pi / 180)
        XCTAssertEqual(r.y, expected, accuracy: 1e-6)

        // A ball dead centre in a camera aimed up 10 degrees is really 10
        // degrees above the horizon.
        let axis = TiltRectifier.rectify(x: 960, y: 540, tiltDeg: up,
                                         focalPx: f, cx: 960, cy: 540)
        XCTAssertEqual(axis.y, 540 - f * tan(10 * Double.pi / 180), accuracy: 1e-6)
    }

    // MARK: - Settings round-trip

    func testAppSettingsSurviveEncoding() {
        var settings = AppSettings()
        settings.detector.hsvLo = HSVBounds(h: 20, s: 80, v: 130)
        settings.triggerDb = 12
        // Non-default on purpose. A stored property with a declaration default
        // compiles fine when its line in the hand-written decoder is forgotten,
        // and then silently never survives a launch — which this test can only
        // catch if the value it round-trips differs from the default.
        settings.showSkeletonWhileArmed = !AppSettings().showSkeletonWhileArmed
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}

/// Measuring in the frame the viewer actually sees.
///
/// The bug these pin cost a real clip: a ball dropped from head height, tracked
/// perfectly for 121 frames, reported as `+76.9 deg` — going almost straight
/// UP — because the file's buffer is stored upside down and every number was
/// taken from the buffer. The pipeline then refused the reading as impossible,
/// which is the right answer to the wrong question. On a swing it would not
/// have been refused: a hit that rises would simply have been reported as one
/// that falls.
final class VideoOrientationTests: XCTestCase {

    func testQuarterTurnsFromTransform() {
        XCTAssertEqual(VideoOrientation.quarterTurns(.identity), 0)
        XCTAssertEqual(VideoOrientation.quarterTurns(CGAffineTransform(rotationAngle: .pi / 2)), 1)
        XCTAssertEqual(VideoOrientation.quarterTurns(CGAffineTransform(rotationAngle: .pi)), 2)
        XCTAssertEqual(VideoOrientation.quarterTurns(CGAffineTransform(rotationAngle: -.pi / 2)), 3)
        // The other way round the circle is the same quarter turn.
        XCTAssertEqual(VideoOrientation.quarterTurns(CGAffineTransform(rotationAngle: 3 * .pi / 2)), 3)
    }

    func testDisplaySizeSwapsOnAQuarterTurn() {
        XCTAssertEqual(VideoOrientation.displaySize(width: 1920, height: 1080, quarterTurns: 0).width, 1920)
        XCTAssertEqual(VideoOrientation.displaySize(width: 1920, height: 1080, quarterTurns: 1).width, 1080)
        XCTAssertEqual(VideoOrientation.displaySize(width: 1920, height: 1080, quarterTurns: 2).width, 1920)
        XCTAssertEqual(VideoOrientation.displaySize(width: 1920, height: 1080, quarterTurns: 3).width, 1080)
    }

    /// The real numbers from tee_06.mov: the ball's first and last tracked
    /// points in the buffer, and where they actually are on screen.
    func testTheDropThatReadAsARise() {
        let w = 1920, h = 1080
        let first = VideoOrientation.point(x: 1003.11, y: 761.21, width: w, height: h, quarterTurns: 2)
        let last  = VideoOrientation.point(x: 1028.78, y: 328.40, width: w, height: h, quarterTurns: 2)

        // In the buffer y DECREASES over the fall, which reads as rising.
        XCTAssertLessThan(328.40, 761.21)
        // Rotated into the displayed frame it increases, which is falling.
        XCTAssertGreaterThan(last.y, first.y, "a dropped ball must move down the screen")

        // And the angle flips sign, which is the whole point.
        let rawAngle = atan2(-(328.40 - 761.21), abs(1028.78 - 1003.11)) * 180 / .pi
        let upAngle  = atan2(-(last.y - first.y), abs(last.x - first.x)) * 180 / .pi
        XCTAssertGreaterThan(rawAngle, 80, "the buffer says it went up")
        XCTAssertLessThan(upAngle, -80, "the screen says it fell")
    }

    /// A length does not rotate. Diameter is the scale every mph rests on, so
    /// a rotation that quietly changed it would be worse than the bug it fixes.
    func testRotationLeavesDiametersAlone() {
        let track = [BallObservation(frame: 0, t: 0, x: 100, y: 200, diameterPx: 33.5, areaPx: 880)]
        for q in 0...3 {
            let r = VideoOrientation.rotate(track: track, width: 1920, height: 1080, quarterTurns: q)
            XCTAssertEqual(r[0].diameterPx, 33.5, "quarter turns \(q)")
            XCTAssertEqual(r[0].areaPx, 880, "quarter turns \(q)")
        }
    }

    /// Four quarter turns is where you started.
    func testFourTurnsIsIdentity() {
        var p = (x: 137.0, y: 991.0)
        var w = 1920, h = 1080
        for _ in 0..<4 {
            p = VideoOrientation.point(x: p.x, y: p.y, width: w, height: h, quarterTurns: 1)
            let d = VideoOrientation.displaySize(width: w, height: h, quarterTurns: 1)
            w = d.width; h = d.height
        }
        XCTAssertEqual(p.x, 137.0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 991.0, accuracy: 1e-9)
    }
}
