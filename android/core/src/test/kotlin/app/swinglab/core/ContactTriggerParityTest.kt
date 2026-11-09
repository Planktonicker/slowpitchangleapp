// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Kotlin-only: the Swift pins its trigger with behavioural tests alone
 * (ContactTriggerTest is their port). This pins the same object number for
 * number to `spike/replay_trigger.py`, through the `trigger_highpass` and
 * `contact_trigger` blocks: `highpass()` sample for sample, and `simulate()`
 * window for window — every window's dB over the floor, and every fire.
 *
 * The audio is rebuilt here from each case's recipe, by the arithmetic of the
 * generator's `_trigger_signal` in the same order, so the two sides start from
 * the same samples to within what `sin` differs by between libraries.
 */
class ContactTriggerParityTest {

    private val highPass get() = Fixtures.block("trigger_highpass")
    private val cases get() = Fixtures.block("contact_trigger")

    private fun JsonObject.signal(): DoubleArray {
        val sr = d("sample_rate")
        val x = DoubleArray(i("n_samples"))
        for (element in arr("components")) {
            val c = element.jsonObject
            val lo = c.i("start")
            val hi = c.i("stop")
            when (c.s("kind")) {
                "pulse" -> {
                    val amp = c.d("amp")
                    for (i in lo until hi) x[i] += amp
                }
                "tone" -> {
                    val amp = c.d("amp"); val hz = c.d("hz"); val phase = c.d("phase")
                    for (i in lo until hi) x[i] += amp * sin(2.0 * PI * hz * i / sr + phase)
                }
                "hann_tone" -> {
                    val amp = c.d("amp"); val hz = c.d("hz")
                    val m = hi - lo
                    for (k in 0 until m) {
                        val w = 0.5 - 0.5 * cos(2.0 * PI * k / (m - 1))
                        x[lo + k] += amp * sin(2.0 * PI * hz * k / sr) * w
                    }
                }
                "chirp" -> {
                    val amp = c.d("amp"); val f0 = c.d("f0"); val f1 = c.d("f1")
                    val dur = (hi - lo) / sr
                    for (k in 0 until hi - lo) {
                        val t = k / sr
                        x[lo + k] += amp * sin(2.0 * PI * (f0 * t + (f1 - f0) * t * t / (2.0 * dur)))
                    }
                }
                else -> fail("${s("name")}: unknown component ${c.s("kind")}")
            }
        }
        return x
    }

    private val JsonObject.name get() = s("name")

    /** A trigger set up as the case's `simulate()` call was, armed. */
    private fun JsonObject.trigger(): ContactTrigger {
        // The fixture was generated against the Kotlin's own settings (that is
        // where replay_trigger reads them). A setting changed since without
        // regenerating would make every number below a comparison against a
        // different trigger, so say that rather than a dB mismatch.
        assertEquals(SLA.triggerHighPassHz, d("high_pass_hz"), "$name: regenerate the fixtures")
        assertEquals(SLA.triggerHighPassOrder, i("order"), "$name: regenerate the fixtures")
        assertEquals(ContactTrigger.attemptRefractoryS, d("attempt_refractory_s"), "$name: regenerate the fixtures")
        val t = ContactTrigger(thresholdDb = d("threshold_db"))
        t.refractoryS = d("refractory_s")
        t.isArmed = true
        return t
    }

    /**
     * simulate()'s confirmed model: every fire became a clip. Modelled by
     * confirming each fire before the next buffer, which is the same thing
     * while a buffer is shorter than the attempt refractory — nothing in it
     * after a fire could have fired anyway.
     */
    private val JsonObject.confirms: Boolean get() = when (s("refractory_mode")) {
        "attempt" -> false
        "confirmed" -> true
        else -> fail("$name: unknown refractory_mode ${s("refractory_mode")}")
    }

    private fun JsonObject.windowLength() = (d("rms_window_s") * d("sample_rate")).toInt()

    /**
     * Feed [x] in buffers of [size] samples, each stamped with its first
     * sample's place in the stream, as a microphone delivers them. [after]
     * runs after every buffer, with its length.
     */
    private fun JsonObject.feed(
        t: ContactTrigger, x: DoubleArray, size: Int, after: (Int) -> Unit = {},
    ): List<Pair<Double, Double>> {
        val sr = d("sample_rate")
        if (confirms) {
            assertTrue(size / sr < ContactTrigger.attemptRefractoryS,
                "$name: a confirmed case needs buffers shorter than the attempt refractory")
        }
        val fires = mutableListOf<Pair<Double, Double>>()
        var i = 0
        while (i < x.size) {
            val end = min(i + size, x.size)
            val got = t.process(samples = x.copyOfRange(i, end), sampleRate = sr, startSeconds = i.toDouble() / sr)
            fires += got
            if (confirms) got.lastOrNull()?.let { t.confirmFire(at = it.first) }
            after(end - i)
            i = end
        }
        return fires
    }

    private fun JsonObject.assertFires(got: List<Pair<Double, Double>>, how: String) {
        val expected = arr("expected_fires").map { it.jsonObject }
        assertEquals(expected.size, got.size,
            "$name ($how): fired at ${got.map { it.first }}, replay_trigger at ${expected.map { it.d("t") }}")
        for ((k, e) in expected.withIndex()) {
            assertClose(got[k].first, e.d("t"), "$name ($how) fire $k time", abs = 1e-12, rel = 0.0)
            assertClose(got[k].second, e.d("db"), "$name ($how) fire $k dB", abs = DB_ABS, rel = 0.0)
        }
    }

    /** One window per call, reading `lastDb` back after each: the whole trace. */
    private fun JsonObject.assertTrace(t: ContactTrigger, how: String) {
        val x = signal()
        val w = windowLength()
        val trace = mutableListOf<Double>()
        val fires = feed(t, x, w, after = { length -> if (length == w) trace += t.lastDb })
        val expected = arr("expected_db").doubles()
        // simulate() drops a tail too short to fill a window; the carry holds
        // it and measures nothing.
        assertEquals(expected.size, trace.size, "$name ($how): window count")
        for ((k, e) in expected.withIndex()) {
            assertClose(trace[k], e, "$name ($how) window $k dB", abs = DB_ABS, rel = 0.0)
        }
        assertFires(fires, how)
    }

    @Test
    fun theHighPassIsReplayTriggersSampleForSample() {
        assertTrue(highPass.isNotEmpty())
        for (c in highPass) {
            val x = c.signal()
            // Built as ContactTrigger builds its cascade: order / 2 sections.
            val sections = List(c.i("order") / 2) {
                TriggerBiquad(highPassHz = c.d("high_pass_hz"), sampleRate = c.d("sample_rate"))
            }
            val y = DoubleArray(x.size)
            for (i in x.indices) {
                var s = x[i]
                for (section in sections) s = section.process(s)
                y[i] = s
            }
            val indices = c.arr("indices").doubles().map { it.toInt() }
            val expected = c.arr("expected").doubles()
            assertEquals(indices.size, expected.size, c.name)
            for ((k, i) in indices.withIndex()) {
                assertClose(y[i], expected[k], "${c.name} sample $i", abs = SAMPLE_ABS, rel = SAMPLE_REL)
            }
        }
    }

    @Test
    fun theFixturesCoverBothRefractoryModels() {
        val modes = cases.map { it.s("refractory_mode") }.toSet()
        assertEquals(setOf("attempt", "confirmed"), modes)
        assertTrue(cases.sumOf { it.arr("expected_fires").size } > 0, "a trigger that never fires pins nothing about firing")
    }

    @Test
    fun everyWindowStandsWhereReplayTriggerPutsIt() {
        for (c in cases) c.assertTrace(c.trigger(), "one window per buffer")
    }

    /**
     * The whole clip in one call. Attempt-model cases only: a single call has
     * nowhere to confirm a fire before the next window, so the confirmed model
     * is reached through the buffered tests instead.
     */
    @Test
    fun theWholeStreamInOneBufferFiresWhereReplayTriggerDoes() {
        val attempt = cases.filter { !it.confirms }
        assertTrue(attempt.isNotEmpty())
        for (c in attempt) {
            c.assertFires(c.trigger().process(samples = c.signal(), sampleRate = c.d("sample_rate"), startSeconds = 0.0),
                "one buffer")
        }
    }

    /**
     * Buffers that are not a whole number of windows — one sample, a prime,
     * and a typical microphone buffer — fire at the stream times simulate()
     * gives, with `rearm` between every buffer changing nothing it can see.
     */
    @Test
    fun buffersOfAnySizeFireAtReplayTriggersTimes() {
        for (c in cases) {
            val x = c.signal()
            for (size in listOf(1, 1021, 4096)) {
                val t = c.trigger()
                c.assertFires(c.feed(t, x, size, after = { t.rearm() }), "buffers of $size")
            }
        }
    }

    /**
     * After `resetForRound` the trigger is a fresh stream, which is what
     * simulate() always is: no filter memory, no carry, no floor, no
     * refractory. Primed with a loud clip that fires and leaves a part-window
     * in the carry, so a reset that missed any of the four shows.
     */
    @Test
    fun resetForRoundIsAFreshStream() {
        val primer = cases.first { it.name == "chatter_lifts_the_floor" }
        val primerSamples = primer.signal().copyOfRange(0, (0.7 * primer.d("sample_rate")).toInt() + 37)
        for (c in cases) {
            val t = c.trigger()
            val primed = t.process(samples = primerSamples, sampleRate = primer.d("sample_rate"), startSeconds = 0.0)
            assertTrue(primed.isNotEmpty(), "the primer must fire, or the refractory reset is untested")
            t.resetForRound()
            c.assertTrace(t, "after resetForRound")
        }
    }

    private companion object {
        /**
         * The two sides differ only in rounding — numpy sums a window's
         * squares pairwise and interpolates its median where this sums in
         * order and averages — and in `sin` between libraries. Measured: 4e-14
         * dB, 2e-18 (4e-16 relative) on a filtered sample, 2e-16 s on a fire.
         * The generator refuses any case whose outcome would hang on that
         * (`_trigger_margins`), so a fire is never decided by it.
         */
        const val DB_ABS = 1e-10
        const val SAMPLE_ABS = 1e-16
        const val SAMPLE_REL = 1e-12
    }
}
