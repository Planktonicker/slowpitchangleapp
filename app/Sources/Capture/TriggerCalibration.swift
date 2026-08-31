// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import Foundation
import QuartzCore

/// Measures a venue and picks a contact threshold for it.
///
/// The default threshold is 20 dB over the rolling noise floor, which is the
/// validation gate `check_audio_trigger.py` applies (G5) — a single number
/// chosen to decide whether auto-triggering is viable at all. It is a bad
/// working threshold in both directions: too high for a quiet garden, where a
/// solid hit might peak at 12 dB over near-silence and never fire, and too low
/// for a cage, where the floor is high and ricochets are constant.
///
/// So measure both ends instead of guessing. Listen to the background for a
/// few seconds, record a handful of real hits, and put the threshold between
/// them. The separation decides both the number and whether a number is worth
/// having: a venue whose loudest background overlaps its quietest hit cannot be
/// fixed by a cleverer threshold, and saying so is more useful than picking one
/// anyway.
///
/// The arithmetic lives in `SLA.suggestTriggerDb`, ported from
/// `suggest_trigger_db` and pinned by `ParityTests`. This type only collects
/// the two numbers it needs.
@MainActor
final class TriggerCalibration: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Listening to the venue with nobody hitting.
        case background(remaining: Double)
        /// Waiting for the user to hit, with however many are already recorded.
        case hits(recorded: Int)
        case done(Result)
    }

    struct Result: Equatable {
        var backgroundPeakDb: Double
        var quietestHitDb: Double
        var loudestHitDb: Double
        var thresholdDb: Double
        var separationDb: Double
        var verdict: TriggerCalibrationVerdict
        var hitCount: Int
    }

    /// Seconds of background to listen to. Long enough to catch a passing car
    /// or a gust, short enough that nobody skips the step.
    static let backgroundListenS: Double = 5

    /// Hits needed before a threshold is offered. Three so the *quietest* is a
    /// real measurement rather than one sample — the whole method rests on the
    /// weakest hit, and one swing tells you nothing about how weak they get.
    static let hitsWanted = 3

    /// An impulse this far below the background peak is not a hit attempt —
    /// it is the user shuffling. Ignored rather than recorded, or a stray
    /// scuff would become "the quietest hit" and drag the threshold down onto
    /// the noise floor.
    static let minHitOverBackgroundDb: Double = 3

    @Published private(set) var phase: Phase = .idle
    /// Live level, mirrored for the meter so the view needs one observable.
    @Published private(set) var currentDb: Double = 0

    private var backgroundPeak: Double = 0
    private var hits: [Double] = []
    private var startedAt: CFTimeInterval = 0
    /// Peak of the impulse currently being tracked, and when it began. A single
    /// hit spans several 5 ms windows, so the peak is taken across the burst
    /// rather than from whichever window happened to be sampled.
    private var burstPeak: Double = 0
    private var burstEndsAt: CFTimeInterval = 0

    /// How long an impulse is allowed to keep rising before it is banked as one
    /// hit. Bat-on-ball is a few milliseconds; this is generous enough to span
    /// the ring-out without merging two swings.
    private let burstWindowS: Double = 0.25

    var isDone: Bool { if case .done = phase { return true }; return false }

    func startBackground() {
        backgroundPeak = 0
        hits = []
        burstPeak = 0
        startedAt = CACurrentMediaTime()
        phase = .background(remaining: Self.backgroundListenS)
    }

    func cancel() {
        phase = .idle
        hits = []
        backgroundPeak = 0
    }

    /// Feed the live level. Called at whatever rate the controller publishes;
    /// nothing here assumes a fixed cadence.
    func ingest(db: Double) {
        currentDb = db
        let now = CACurrentMediaTime()

        switch phase {
        case .idle, .done:
            return

        case .background:
            backgroundPeak = max(backgroundPeak, db)
            let elapsed = now - startedAt
            let remaining = Self.backgroundListenS - elapsed
            if remaining <= 0 {
                phase = .hits(recorded: 0)
            } else {
                phase = .background(remaining: remaining)
            }

        case .hits:
            // Below the floor plus a margin: not an attempt.
            guard db >= backgroundPeak + Self.minHitOverBackgroundDb else {
                bankBurstIfFinished(now: now)
                return
            }
            if burstPeak == 0 { burstEndsAt = now + burstWindowS }
            burstPeak = max(burstPeak, db)
            bankBurstIfFinished(now: now)
        }
    }

    /// Called on a timer as well as on every sample, so a hit still banks when
    /// the room goes silent and no further levels arrive.
    func tick() {
        let now = CACurrentMediaTime()
        if case .background = phase { ingest(db: currentDb) }
        bankBurstIfFinished(now: now)
    }

    private func bankBurstIfFinished(now: CFTimeInterval) {
        guard burstPeak > 0, now >= burstEndsAt else { return }
        hits.append(burstPeak)
        burstPeak = 0
        if hits.count >= Self.hitsWanted {
            finish()
        } else {
            phase = .hits(recorded: hits.count)
        }
    }

    /// Stop early with whatever hits are recorded. Offered because three swings
    /// is a request, not a requirement, and refusing to finish would strand
    /// someone who only wanted two.
    func finishEarly() {
        if burstPeak > 0 {
            hits.append(burstPeak)
            burstPeak = 0
        }
        finish()
    }

    private func finish() {
        guard let quietest = hits.min(), let loudest = hits.max() else {
            phase = .idle
            return
        }
        let s = SLA.suggestTriggerDb(backgroundPeakDb: backgroundPeak,
                                     quietestHitDb: quietest)
        phase = .done(Result(backgroundPeakDb: backgroundPeak,
                             quietestHitDb: quietest,
                             loudestHitDb: loudest,
                             thresholdDb: s.thresholdDb,
                             separationDb: s.separationDb,
                             verdict: s.verdict,
                             hitCount: hits.count))
    }
}
