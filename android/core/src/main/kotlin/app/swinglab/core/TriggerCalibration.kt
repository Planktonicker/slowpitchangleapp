// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Port of `TriggerCalibration.swift` `final class TriggerCalibration`: listen
 * to the venue, bank a few hits, and put the threshold between them. The
 * arithmetic is `SLA.suggestTriggerDb` / `SLA.thresholdFromBackground`
 * (sla_common.suggest_trigger_db / threshold_from_background); the reasoning
 * lives in the Swift.
 *
 * Where the Kotlin differs: the Swift is a `@MainActor ObservableObject` that
 * reads `CACurrentMediaTime()` and publishes [phase] and [currentDb] through
 * Combine. None of that is available in plain JVM core, so the clock is
 * injected ([clock], seconds on any monotonic origin) and the two published
 * values are plain read-only properties for the app layer to observe — which
 * also lets the state machine be driven deterministically in a test. Callers
 * keep it on one thread, as the Swift's main-actor isolation did.
 */
class TriggerCalibration(
    private val clock: () -> Double = { System.nanoTime() / 1e9 },
) {

    /** Port of `TriggerCalibration.Phase`; lower-case names as in the Swift enum. */
    sealed class Phase {
        object idle : Phase() {
            override fun toString() = "idle"
        }

        /** Listening to the venue with nobody hitting. */
        data class background(val remaining: Double) : Phase()

        /** Waiting for the user to hit, with however many are already recorded. */
        data class hits(val recorded: Int) : Phase()

        data class done(val result: Result) : Phase()
    }

    /** Port of `TriggerCalibration.Result`; the hit fields and verdict are null for a listen-only calibration. */
    data class Result(
        val backgroundPeakDb: Double,
        val quietestHitDb: Double?,
        val loudestHitDb: Double?,
        val thresholdDb: Double,
        val separationDb: Double?,
        val verdict: TriggerCalibrationVerdict?,
        val hitCount: Int,
    )

    var phase: Phase = Phase.idle
        private set

    /** Live level, mirrored for the meter. */
    var currentDb: Double = 0.0
        private set

    private var backgroundPeak: Double = 0.0
    private val hits = mutableListOf<Double>()
    private var startedAt: Double = 0.0
    private var burstPeak: Double = 0.0
    private var burstEndsAt: Double = 0.0

    private val burstWindowS: Double = 0.25

    val isDone: Boolean get() = phase is Phase.done

    fun startBackground() {
        backgroundPeak = 0.0
        hits.clear()
        burstPeak = 0.0
        startedAt = clock()
        phase = Phase.background(remaining = backgroundListenS)
    }

    fun cancel() {
        phase = Phase.idle
        hits.clear()
        backgroundPeak = 0.0
    }

    /** Port of `TriggerCalibration.ingest(db:)`: feed the live level, at any cadence. */
    fun ingest(db: Double) {
        currentDb = db
        val now = clock()

        when (phase) {
            is Phase.idle, is Phase.done -> return

            is Phase.background -> {
                backgroundPeak = swiftMax(backgroundPeak, db)
                val elapsed = now - startedAt
                val remaining = backgroundListenS - elapsed
                phase = if (remaining <= 0) Phase.hits(recorded = 0) else Phase.background(remaining = remaining)
            }

            is Phase.hits -> {
                if (!(db >= backgroundPeak + minHitOverBackgroundDb)) {
                    bankBurstIfFinished(now)
                    return
                }
                if (burstPeak == 0.0) burstEndsAt = now + burstWindowS
                burstPeak = swiftMax(burstPeak, db)
                bankBurstIfFinished(now)
            }
        }
    }

    /** Port of `TriggerCalibration.tick()`: so a hit still banks when the room goes silent. */
    fun tick() {
        val now = clock()
        if (phase is Phase.background) ingest(currentDb)
        bankBurstIfFinished(now)
    }

    private fun bankBurstIfFinished(now: Double) {
        if (!(burstPeak > 0) || !(now >= burstEndsAt)) return
        hits.add(burstPeak)
        burstPeak = 0.0
        if (hits.size >= hitsWanted) {
            finish()
        } else {
            phase = Phase.hits(recorded = hits.size)
        }
    }

    /** Port of `TriggerCalibration.finishEarly()`: stop with whatever hits are recorded, including none. */
    fun finishEarly() {
        if (burstPeak > 0) {
            hits.add(burstPeak)
            burstPeak = 0.0
        }
        finish()
    }

    /** Port of `TriggerCalibration.finish()`: no hits is a listen-only result, not a failure. */
    private fun finish() {
        // Swift's `hits.min()` / `hits.max()` compare with `<`, as minOrNull /
        // maxOrNull do for the finite levels that reach here.
        val quietest = hits.minOrNull()
        val loudest = hits.maxOrNull()
        if (quietest == null || loudest == null) {
            phase = Phase.done(
                Result(
                    backgroundPeakDb = backgroundPeak,
                    quietestHitDb = null,
                    loudestHitDb = null,
                    thresholdDb = SLA.thresholdFromBackground(backgroundPeakDb = backgroundPeak),
                    separationDb = null,
                    verdict = null,
                    hitCount = 0,
                ),
            )
            return
        }
        val s = SLA.suggestTriggerDb(backgroundPeakDb = backgroundPeak, quietestHitDb = quietest)
        phase = Phase.done(
            Result(
                backgroundPeakDb = backgroundPeak,
                quietestHitDb = quietest,
                loudestHitDb = loudest,
                thresholdDb = s.thresholdDb,
                separationDb = s.separationDb,
                verdict = s.verdict,
                hitCount = hits.size,
            ),
        )
    }

    companion object {
        /** Port of `TriggerCalibration.backgroundListenS`. */
        const val backgroundListenS: Double = 5.0

        /** Port of `TriggerCalibration.hitsWanted`. */
        const val hitsWanted = 3

        /** Port of `TriggerCalibration.minHitOverBackgroundDb`. */
        const val minHitOverBackgroundDb: Double = 3.0
    }
}
