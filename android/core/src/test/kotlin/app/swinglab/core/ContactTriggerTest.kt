// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Port of `app/Tests/ContactTriggerTests.swift`, through the same
 * `process(samples:sampleRate:startSeconds:)` seam.
 */
class ContactTriggerTest {

    private val sr = 48_000.0

    /**
     * The Swift test's seeded generator, bit for bit: `&*` / `&+` wrap exactly
     * as Long arithmetic does, and `seed >> 11` on a UInt64 is `ushr`.
     */
    private class Lcg(private var seed: Long) {
        fun next(): Double {
            seed = seed * 6364136223846793005L + 1442695040888963407L
            return (seed ushr 11).toDouble() / (1L shl 52).toDouble() - 1.0
        }
    }

    /** Quiet room, with impulses dropped into it. Deterministic. */
    private fun room(
        seconds: Double,
        noise: Double = 1e-3,
        impulsesAt: List<Double> = emptyList(),
        impulse: Double = 0.5,
    ): DoubleArray {
        val rng = Lcg(0x5EED)
        val out = DoubleArray((seconds * sr).toInt()) { rng.next() * noise }
        for (at in impulsesAt) {
            val i = (at * sr).toInt()
            for (k in 0 until (0.001 * sr).toInt()) {
                if (i + k < out.size) out[i + k] += impulse
            }
        }
        return out
    }

    private fun armed(threshold: Double = 20.0, refractory: Double = 2.0): ContactTrigger {
        val t = ContactTrigger(thresholdDb = threshold)
        t.refractoryS = refractory
        t.isArmed = true
        return t
    }

    // What the trigger is for

    @Test
    fun anImpulseOverAQuietRoomFires() {
        val t = armed()
        val fires = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.6)), sampleRate = sr, startSeconds = 0.0)
        assertEquals(1, fires.size)
        assertEquals(0.6, fires.firstOrNull()?.first ?: 0.0, 0.02)
    }

    @Test
    fun aDisarmedTriggerHearsNothing() {
        val t = armed()
        t.isArmed = false
        assertTrue(t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.6)), sampleRate = sr, startSeconds = 0.0).isEmpty())
    }

    // The refractory, which is where the swings went

    @Test
    fun oneImpulseIsReportedOnce() {
        val t = armed()
        val fires = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.6)), sampleRate = sr, startSeconds = 0.0)
        assertEquals(1, fires.size, "a bat crack spans several windows")
    }

    @Test
    fun aRefusedImpulseDoesNotCostTheRefractory() {
        val t = armed()
        val samples = room(seconds = 2.0, impulsesAt = listOf(0.5, 1.5))
        val fires = t.process(samples = samples, sampleRate = sr, startSeconds = 0.0)
        assertEquals(2, fires.size, "nothing confirmed the first, so the second must still be heard")
    }

    @Test
    fun aConfirmedFireDoesCostTheRefractory() {
        val t = armed()
        val first = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.5)), sampleRate = sr, startSeconds = 0.0)
        assertEquals(1, first.size)
        t.confirmFire(at = assertNotNull(first.firstOrNull()).first)
        val second = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.5)), sampleRate = sr, startSeconds = 1.0)
        assertTrue(second.isEmpty(), "1.5 s after a confirmed fire is still inside 2 s")
    }

    @Test
    fun theRefractoryEndsOnTime() {
        val t = armed()
        val first = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.5)), sampleRate = sr, startSeconds = 0.0)
        t.confirmFire(at = assertNotNull(first.firstOrNull()).first)
        val later = t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.8)), sampleRate = sr, startSeconds = 2.0)
        assertEquals(1, later.size, "2.8 s is past a 2 s refractory")
    }

    // The dead zone after every clip

    @Test
    fun rearmKeepsTheNoiseFloorAndResetForRoundDoesNot() {
        val warm = room(seconds = 1.0)

        val kept = armed()
        kept.process(samples = warm, sampleRate = sr, startSeconds = 0.0)
        kept.rearm()
        val afterRearm = kept.process(samples = room(seconds = 0.2, impulsesAt = listOf(0.05)),
            sampleRate = sr, startSeconds = 1.0)
        assertEquals(1, afterRearm.size, "the venue did not change while the clip was being written")

        val cleared = armed()
        cleared.process(samples = warm, sampleRate = sr, startSeconds = 0.0)
        cleared.resetForRound()
        val afterReset = cleared.process(samples = room(seconds = 0.2, impulsesAt = listOf(0.05)),
            sampleRate = sr, startSeconds = 1.0)
        assertTrue(afterReset.isEmpty(), "a fresh round must refill the floor before it trusts a level")
    }

    // The floor, and what it cannot do

    @Test
    fun sustainedNoiseBecomesTheFloorAndHidesAnImpulseInsideIt() {
        // One generator across both calls of clip(), as the Swift's captured
        // `seed` is: only the chatter draws from it, and only the second call
        // has chatter, so the order is the Swift's.
        val chatter = Lcg(0xC0FFEE)
        fun clip(withChatter: Boolean): DoubleArray {
            val x = room(seconds = 2.0, noise = 1e-3)
            if (withChatter) {
                for (i in (0.30 * sr).toInt() until (1.50 * sr).toInt()) x[i] += chatter.next() * 3e-2
            }
            val i = (1.20 * sr).toInt()
            for (k in 0 until (0.001 * sr).toInt()) x[i + k] += 0.5
            return x
        }

        val quiet = armed().process(samples = clip(withChatter = false), sampleRate = sr, startSeconds = 0.0)
        assertEquals(1, quiet.size, "over a quiet field this impulse is 35 dB over the floor")
        assertEquals(1.20, quiet.firstOrNull()?.first ?: 0.0, 0.02)

        val noisy = armed().process(samples = clip(withChatter = true), sampleRate = sr, startSeconds = 0.0)
        assertEquals(1, noisy.size)
        assertEquals(0.30, noisy.firstOrNull()?.first ?: 0.0, 0.05, "the only thing heard is the chatter starting")
        assertFalse(noisy.any { abs(it.first - 1.20) < 0.05 },
            "the impulse inside the chatter is measured against the chatter")
    }

    // The band, which is what actually separates a hit

    @Test
    fun aLoudLowThumpIsIgnoredButAClickOfTheSameSizeIsNot() {
        fun tone(hz: Double): DoubleArray {
            val x = room(seconds = 1.2)
            val i = (0.6 * sr).toInt()
            val n = (0.010 * sr).toInt()
            for (k in 0 until n) {
                // Hann-windowed, so the burst's own edges are not a click.
                val w = 0.5 - 0.5 * cos(2 * PI * k.toDouble() / (n - 1).toDouble())
                x[i + k] += 0.5 * sin(2 * PI * hz * k.toDouble() / sr) * w
            }
            return x
        }
        for (hz in listOf(250.0, 500.0, 1000.0)) {
            assertTrue(armed().process(samples = tone(hz), sampleRate = sr, startSeconds = 0.0).isEmpty(),
                "${hz.toInt()} Hz at half full scale is not a bat on a ball")
        }
        assertEquals(1, armed().process(samples = room(seconds = 1.2, impulsesAt = listOf(0.6)),
            sampleRate = sr, startSeconds = 0.0).size,
            "the same peak amplitude, broadband, is")
    }

    @Test
    fun theFilterOrderIsEvenSoNoSectionIsSilentlyDropped() {
        assertEquals(0, SLA.triggerHighPassOrder % 2)
        assertTrue(SLA.triggerHighPassOrder >= 4, "12 dB/octave was measured to be not enough")
    }

    // Robustness

    @Test
    fun silenceDoesNotFire() {
        val t = armed()
        assertTrue(t.process(samples = DoubleArray(sr.toInt()), sampleRate = sr, startSeconds = 0.0).isEmpty())
    }

    @Test
    fun anInvalidSampleRateIsRefusedRatherThanDividedBy() {
        val t = armed()
        assertTrue(t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.5)), sampleRate = 0.0, startSeconds = 0.0).isEmpty())
    }

    @Test
    fun fragmentedBuffersFindTheSameImpulse() {
        val samples = room(seconds = 1.0, impulsesAt = listOf(0.6))

        val whole = armed()
        val a = whole.process(samples = samples, sampleRate = sr, startSeconds = 0.0)

        val split = armed()
        val b = mutableListOf<Pair<Double, Double>>()
        val chunk = 1021          // deliberately not a multiple of a window
        var i = 0
        while (i < samples.size) {
            val end = min(i + chunk, samples.size)
            b += split.process(samples = samples.copyOfRange(i, end), sampleRate = sr, startSeconds = i.toDouble() / sr)
            i = end
        }
        assertEquals(a.size, b.size)
        assertEquals(a.firstOrNull()?.first ?: -1.0, b.firstOrNull()?.first ?: -2.0, 0.010)
    }

    // Kotlin-only: the two peak holds, which no Swift test reaches.

    @Test
    fun peaksAreHeldUntilConsumedAndMeasuredWhileDisarmed() {
        val t = armed()
        t.isArmed = false
        t.process(samples = room(seconds = 1.0, impulsesAt = listOf(0.6)), sampleRate = sr, startSeconds = 0.0)
        val sinceArm = t.consumePeakSinceArm()
        assertTrue(sinceArm > 20, "measured even while disarmed")
        assertEquals(Double.NEGATIVE_INFINITY, t.consumePeakSinceArm(), "consuming resets the hold")
        assertEquals(sinceArm, t.consumePeakDb(), "the meter's hold saw the same windows")
        assertEquals(t.lastDb, t.consumePeakDb(), "with no new window the meter falls back to the last level")
    }
}
