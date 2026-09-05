// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import XCTest
@testable import SwingLab

/// The first tests this file has ever had, and it decides when the app records.
///
/// It had none because the measurement was welded to `CMSampleBuffer`, which is
/// awkward to build in a test and impossible to get from a simulator's
/// microphone. `process(samples:sampleRate:startSeconds:)` is that seam: PCM
/// extraction stays in the buffer path, the measurement is reachable from here.
///
/// The numbers pinned below come from `spike/replay_trigger.py`, which runs the
/// same measurement over the real audio in `spike/corpus/`.
final class ContactTriggerTests: XCTestCase {

    private let sr = 48_000.0

    /// Quiet room, with impulses dropped into it. Deterministic — a seeded
    /// generator, because a test that fires on noise some days is worse than no
    /// test.
    private func room(seconds: Double, noise: Double = 1e-3,
                      impulsesAt: [Double] = [], impulse: Double = 0.5) -> [Double] {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
        }
        var out = (0..<Int(seconds * sr)).map { _ in next() * noise }
        for at in impulsesAt {
            let i = Int(at * sr)
            for k in 0..<Int(0.001 * sr) where i + k < out.count {
                out[i + k] += impulse
            }
        }
        return out
    }

    private func armed(threshold: Double = 20, refractory: Double = 2.0) -> ContactTrigger {
        let t = ContactTrigger(thresholdDb: threshold)
        t.refractoryS = refractory
        t.isArmed = true
        return t
    }

    // MARK: - What the trigger is for

    func testAnImpulseOverAQuietRoomFires() {
        let t = armed()
        let fires = t.process(samples: room(seconds: 1.0, impulsesAt: [0.6]),
                              sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires.first?.0 ?? 0, 0.6, accuracy: 0.02)
    }

    func testADisarmedTriggerHearsNothing() {
        let t = armed()
        t.isArmed = false
        XCTAssertTrue(t.process(samples: room(seconds: 1.0, impulsesAt: [0.6]),
                                sampleRate: sr, startSeconds: 0).isEmpty)
    }

    // MARK: - The refractory, which is where the swings went

    /// One impulse must not be reported once per 5 ms window it spans, nor once
    /// per queue hop while the recording decision is in flight.
    func testOneImpulseIsReportedOnce() {
        let t = armed()
        let fires = t.process(samples: room(seconds: 1.0, impulsesAt: [0.6]),
                              sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(fires.count, 1, "a bat crack spans several windows")
    }

    /// The fix. An impulse that is refused downstream — no hitter in frame, the
    /// controller disarmed, the recorder busy — never reaches `confirmFire`, so
    /// it must not cost the two-second refractory. Before this, four separate
    /// refusal paths each bought two seconds of deafness for a clip that was
    /// never written.
    func testARefusedImpulseDoesNotCostTheRefractory() {
        let t = armed()
        // Two impulses a second apart: well inside the 2 s refractory, well
        // outside the 0.25 s that detection alone buys.
        let samples = room(seconds: 2.0, impulsesAt: [0.5, 1.5])
        let fires = t.process(samples: samples, sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(fires.count, 2,
                       "nothing confirmed the first, so the second must still be heard")
    }

    /// The other half: once a clip really is being written, the refractory does
    /// its job. A ball rattling a fence a second later must not start a second
    /// clip.
    func testAConfirmedFireDoesCostTheRefractory() throws {
        let t = armed()
        let first = t.process(samples: room(seconds: 1.0, impulsesAt: [0.5]),
                              sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(first.count, 1)
        t.confirmFire(at: try XCTUnwrap(first.first).0)
        let second = t.process(samples: room(seconds: 1.0, impulsesAt: [0.5]),
                               sampleRate: sr, startSeconds: 1.0)
        XCTAssertTrue(second.isEmpty, "1.5 s after a confirmed fire is still inside 2 s")
    }

    func testTheRefractoryEndsOnTime() throws {
        let t = armed()
        let first = t.process(samples: room(seconds: 1.0, impulsesAt: [0.5]),
                              sampleRate: sr, startSeconds: 0)
        t.confirmFire(at: try XCTUnwrap(first.first).0)
        let later = t.process(samples: room(seconds: 1.0, impulsesAt: [0.8]),
                              sampleRate: sr, startSeconds: 2.0)
        XCTAssertEqual(later.count, 1, "2.8 s is past a 2 s refractory")
    }

    // MARK: - The dead zone after every clip

    /// Nothing may fire until the floor history is half full, which is 50
    /// windows of 5 ms. `resetForRound` empties it on purpose; `rearm` must not,
    /// or every clip is followed by a quarter-second hole in the middle of a
    /// round.
    func testRearmKeepsTheNoiseFloorAndResetForRoundDoesNot() {
        let warm = room(seconds: 1.0)

        let kept = armed()
        _ = kept.process(samples: warm, sampleRate: sr, startSeconds: 0)
        kept.rearm()
        let afterRearm = kept.process(samples: room(seconds: 0.2, impulsesAt: [0.05]),
                                      sampleRate: sr, startSeconds: 1.0)
        XCTAssertEqual(afterRearm.count, 1,
                       "the venue did not change while the clip was being written")

        let cleared = armed()
        _ = cleared.process(samples: warm, sampleRate: sr, startSeconds: 0)
        cleared.resetForRound()
        let afterReset = cleared.process(samples: room(seconds: 0.2, impulsesAt: [0.05]),
                                         sampleRate: sr, startSeconds: 1.0)
        XCTAssertTrue(afterReset.isEmpty,
                      "a fresh round must refill the floor before it trusts a level")
    }

    // MARK: - The floor, and what it cannot do

    /// The failure the field report describes, stated as a test rather than as
    /// an argument: the floor is a median over 0.5 s, so anything sustained past
    /// half of that becomes the floor, and a bat crack is then measured against
    /// the chatter instead of against the quiet.
    ///
    /// This is not a bug to be fixed by widening the window — `spike/replay_
    /// trigger.py --sweep` shows every span from 0.5 s to 5 s and every
    /// quantile from the 10th to the median leaves this venue's hits and
    /// non-hits within 3 dB of each other. It is pinned here so that a change
    /// to the floor has to confront what the floor actually does.
    func testSustainedNoiseBecomesTheFloorAndHidesAnImpulseInsideIt() {
        var seed: UInt64 = 0xC0FFEE
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
        }
        /// A quiet field, optionally with 1.2 s of chatter across the middle of
        /// it, and one impulse at 1.20 s — well after the chatter began, so the
        /// floor has fully caught up to it by then.
        func clip(withChatter: Bool) -> [Double] {
            var x = room(seconds: 2.0, noise: 1e-3)
            if withChatter {
                for i in Int(0.30 * sr)..<Int(1.50 * sr) { x[i] += next() * 3e-2 }
            }
            let i = Int(1.20 * sr)
            for k in 0..<Int(0.001 * sr) { x[i + k] += 3e-2 }
            return x
        }

        let quiet = armed().process(samples: clip(withChatter: false),
                                    sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(quiet.count, 1, "over a quiet field this impulse is 27 dB over the floor")
        XCTAssertEqual(quiet.first?.0 ?? 0, 1.20, accuracy: 0.02)

        // The whole field report, in one assertion. The chatter's ONSET fires,
        // because the floor has not caught up to it yet — that is a clip of
        // nobody swinging. By the time the real impulse arrives the chatter HAS
        // become the floor, so the impulse is barely 1 dB over it and is not
        // heard at all — that is the swing nobody recorded. False positive and
        // false negative out of the same mechanism, a second apart.
        let noisy = armed().process(samples: clip(withChatter: true),
                                    sampleRate: sr, startSeconds: 0)
        XCTAssertEqual(noisy.count, 1)
        XCTAssertEqual(noisy.first?.0 ?? 0, 0.30, accuracy: 0.05,
                       "the only thing heard is the chatter starting")
        XCTAssertFalse(noisy.contains { abs($0.0 - 1.20) < 0.05 },
                       "the impulse inside the chatter is measured against the chatter")
    }

    // MARK: - Robustness

    func testSilenceDoesNotFire() {
        let t = armed()
        XCTAssertTrue(t.process(samples: [Double](repeating: 0, count: Int(sr)),
                                sampleRate: sr, startSeconds: 0).isEmpty)
    }

    func testAnInvalidSampleRateIsRefusedRatherThanDividedBy() {
        let t = armed()
        XCTAssertTrue(t.process(samples: room(seconds: 1.0, impulsesAt: [0.5]),
                                sampleRate: 0, startSeconds: 0).isEmpty)
    }

    /// Buffers arrive in fragments that are not a whole number of 5 ms windows;
    /// the leftover is carried. Feeding the same audio in one batch and in many
    /// must find the same impulse.
    func testFragmentedBuffersFindTheSameImpulse() {
        let samples = room(seconds: 1.0, impulsesAt: [0.6])

        let whole = armed()
        let a = whole.process(samples: samples, sampleRate: sr, startSeconds: 0)

        let split = armed()
        var b: [(Double, Double)] = []
        let chunk = 1021          // deliberately not a multiple of a window
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            b += split.process(samples: Array(samples[i..<end]),
                               sampleRate: sr, startSeconds: Double(i) / sr)
            i = end
        }
        XCTAssertEqual(a.count, b.count)
        // Not exact, and the tolerance says why: leftover samples are carried
        // between calls, and the window time is measured from the start of the
        // batch rather than from the start of the carry — so a fragmented feed
        // can report an impulse up to one window (5 ms) late.
        XCTAssertEqual(a.first?.0 ?? -1, b.first?.0 ?? -2, accuracy: 0.010)
    }
}
