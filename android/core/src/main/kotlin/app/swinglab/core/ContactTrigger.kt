// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Port of `ContactTrigger.swift` `struct TriggerBiquad` (spike/check_audio_trigger.py's
 * filter): one second-order Butterworth high-pass section in direct form I,
 * carrying its own memory across buffers; the reasoning lives there.
 */
class TriggerBiquad(highPassHz: Double, sampleRate: Double) {
    private val b0: Double
    private val b1: Double
    private val b2: Double
    private val a1: Double
    private val a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init {
        val fc = highPassHz
        val w0 = 2 * PI * fc / sampleRate
        val c = cos(w0); val sn = sin(w0)
        val alpha = sn / (2 * (1 / sqrt(2.0)))
        val a0 = 1 + alpha
        b0 = ((1 + c) / 2) / a0
        b1 = (-(1 + c)) / a0
        b2 = ((1 + c) / 2) / a0
        a1 = (-2 * c) / a0
        a2 = (1 - alpha) / a0
    }

    fun process(x: Double): Double {
        val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    fun clear() { x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0 }
}

/**
 * Port of `ContactTrigger.swift` `final class ContactTrigger` — the measurement
 * only: high band, 5 ms RMS against a rolling median floor, the attempt and
 * confirmed refractories. The reasoning lives there.
 *
 * Not ported: `onContact` and `process(sampleBuffer:)` with its `CMSampleBuffer`
 * PCM extraction. That is AVFoundation plumbing; on Android the app module's
 * `AudioRecord` reader hands its first channel, as doubles in -1...1, to
 * [process] and reports what comes back — outside this object's lock, for the
 * deadlock reason the Swift gives.
 */
class ContactTrigger(thresholdDb: Double = SLA.triggerDb) {

    private val lock = ReentrantLock()

    private var _lastDb: Double = 0.0
    private var _peakDb: Double = Double.NEGATIVE_INFINITY
    private var _peakSinceArm: Double = Double.NEGATIVE_INFINITY

    /** Port of `ContactTrigger.consumePeakDb()`: the loudest window since the last call, then the hold resets. */
    fun consumePeakDb(): Double = lock.withLock {
        val peak = if (_peakDb == Double.NEGATIVE_INFINITY) _lastDb else _peakDb
        _peakDb = Double.NEGATIVE_INFINITY
        peak
    }

    val lastDb: Double
        get() = lock.withLock { _lastDb }

    private var _thresholdDb: Double = thresholdDb
    var thresholdDb: Double
        get() = lock.withLock { _thresholdDb }
        set(newValue) { lock.withLock { _thresholdDb = newValue } }

    private var _refractoryS: Double = 2.0
    /** Port of `ContactTrigger.refractoryS`: suppression after a CONFIRMED fire. */
    var refractoryS: Double
        get() = lock.withLock { _refractoryS }
        set(newValue) { lock.withLock { _refractoryS = newValue } }

    private var _isArmed = false
    /** Port of `ContactTrigger.isArmed`: disarmed until somebody arms it. */
    var isArmed: Boolean
        get() = lock.withLock { _isArmed }
        set(newValue) { lock.withLock { _isArmed = newValue } }

    private val rmsWindowS = 0.005      // 5 ms
    private val floorWindowS = 0.5      // rolling median span

    private var sections: List<TriggerBiquad> = emptyList()
    private var sectionsSampleRate: Double = 0.0
    // An ArrayDeque where the Swift has an Array: the same append and
    // remove-first, without the O(n) shift on every 5 ms window.
    private val floorHistory = ArrayDeque<Double>()
    private val maxFloorSamples: Int get() = max(8, (floorWindowS / rmsWindowS).toInt())
    private var lastFireTime: Double = Double.NEGATIVE_INFINITY
    private var lastAttemptTime: Double = Double.NEGATIVE_INFINITY

    // The Swift's `carry: [Double]`, as a growable primitive buffer and a
    // count, so 48 000 samples a second are not boxed. Same contents, same
    // removals, in the same order.
    private var carry = DoubleArray(0)
    private var carryCount = 0

    /** Port of `ContactTrigger.resetForRound()`: forget the venue, start listening from scratch. */
    fun resetForRound() {
        lock.withLock {
            floorHistory.clear()
            carryCount = 0
            for (s in sections) s.clear()
            lastFireTime = Double.NEGATIVE_INFINITY
            lastAttemptTime = Double.NEGATIVE_INFINITY
            _peakSinceArm = Double.NEGATIVE_INFINITY
        }
    }

    /** Port of `ContactTrigger.rearm()`: back to listening after a clip WITHOUT forgetting the venue. */
    fun rearm() {
        lock.withLock { _peakSinceArm = Double.NEGATIVE_INFINITY }
    }

    /** Port of `ContactTrigger.confirmFire(at:)`: the impulse became a clip; start the full refractory. */
    fun confirmFire(at: Double) {
        lock.withLock { lastFireTime = at }
    }

    /**
     * Port of `ContactTrigger.process(samples:sampleRate:startSeconds:)`, the
     * testable seam. Returns the impulses detected in this batch as
     * (time, dB over the floor). [samples] is a `DoubleArray` where the Swift
     * takes `[Double]`, so PCM is not boxed on its way in.
     */
    fun process(samples: DoubleArray, sampleRate: Double, startSeconds: Double): List<Pair<Double, Double>> {
        if (!(sampleRate > 0)) return emptyList()
        val windowLength = max(1, (rmsWindowS * sampleRate).toInt())
        val fires = mutableListOf<Pair<Double, Double>>()

        lock.withLock {
            if (sectionsSampleRate != sampleRate) {
                sectionsSampleRate = sampleRate
                sections = List(SLA.triggerHighPassOrder / 2) {
                    TriggerBiquad(highPassHz = SLA.triggerHighPassHz, sampleRate = sampleRate)
                }
            }
            // Deliberately not the Swift. Samples carried over from the last
            // batch come BEFORE this batch's first sample, so a window that
            // straddles two batches began before startSeconds. The Swift dates
            // every window from startSeconds and so stamps a straddling one up
            // to a window (5 ms) late; replay_trigger.simulate, the reference,
            // dates each window by its place in the stream whatever the buffer
            // size — and a microphone buffer is almost never a whole number of
            // windows. Unchanged whenever the previous batch left no carry.
            val carriedIn = carryCount
            reserveCarry(carryCount + samples.size)
            for (raw in samples) {
                var sample = raw
                for (s in sections) sample = s.process(sample)
                carry[carryCount++] = sample
            }
            var offset = 0
            while (carryCount - offset >= windowLength) {
                var sumSq = 0.0
                for (i in 0 until windowLength) {
                    val v = carry[offset + i]
                    sumSq += v * v
                }
                val rms = sqrt(sumSq / windowLength.toDouble()) + 1e-9

                val floor = medianFloor() + 1e-9
                val db = 20 * log10(rms / floor)
                _lastDb = db
                if (db > _peakDb) _peakDb = db

                val windowTime = startSeconds +
                    (offset - carriedIn).toDouble() / sampleRate +
                    rmsWindowS / 2

                if (_isArmed &&
                    db >= _thresholdDb &&
                    floorHistory.size >= maxFloorSamples / 2 &&
                    windowTime - lastFireTime >= _refractoryS &&
                    windowTime - lastAttemptTime >= attemptRefractoryS
                ) {
                    lastAttemptTime = windowTime
                    fires.add(Pair(windowTime, db))
                }
                if (db > _peakSinceArm) _peakSinceArm = db

                floorHistory.addLast(rms)
                if (floorHistory.size > maxFloorSamples) floorHistory.removeFirst()
                offset += windowLength
            }
            if (offset > 0) removeCarryPrefix(min(offset, carryCount))
            if (carryCount > sampleRate.toInt()) {
                removeCarryPrefix(min(carryCount - sampleRate.toInt(), carryCount))
            }
        }
        return fires
    }

    /** Port of `ContactTrigger.consumePeakSinceArm()`: not reset by the UI meter. */
    fun consumePeakSinceArm(): Double = lock.withLock {
        val peak = _peakSinceArm
        _peakSinceArm = Double.NEGATIVE_INFINITY
        peak
    }

    private fun medianFloor(): Double {
        if (floorHistory.isEmpty()) return 1e-9
        val sorted = floorHistory.sorted()
        val n = sorted.size
        return if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /** `carry.reserveCapacity`. */
    private fun reserveCarry(capacity: Int) {
        if (capacity <= carry.size) return
        carry = carry.copyOf(max(capacity, carry.size * 2))
    }

    /** `carry.removeFirst(n)`. */
    private fun removeCarryPrefix(n: Int) {
        if (n <= 0) return
        System.arraycopy(carry, n, carry, 0, carryCount - n)
        carryCount -= n
    }

    companion object {
        /** Port of `ContactTrigger.attemptRefractoryS`: what detection alone buys; the reasoning lives there. */
        const val attemptRefractoryS = 0.25
    }
}
