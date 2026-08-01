// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

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

    // MARK: - Settings round-trip

    func testAppSettingsSurviveEncoding() {
        var settings = AppSettings()
        settings.detector.hsvLo = HSVBounds(h: 20, s: 80, v: 130)
        settings.triggerDb = 12
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}
