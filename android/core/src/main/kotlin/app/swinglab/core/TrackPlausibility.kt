// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.sqrt

/**
 * Port of `TrackPlausibility.swift` `enum TrackPlausibility` (app-only: no
 * sla_common counterpart); the reasoning lives there.
 */
object TrackPlausibility {

    const val maxFlightS = 2.5
    const val minLaunchDeg = -25.0
    const val maxLaunchDeg = 75.0
    const val minStraightness = 0.80
    const val minDiametersPerFrame = 0.20
    const val maxExitVeloMph = 130.0
    const val residualMeaninglessBelow = 6
    const val maxShortTrackSpeedGrowth = 2.0
    const val maxStartAfterContactS = 0.25

    /**
     * Port of `TrackPlausibility.rejection`; the reasoning lives there. `null`
     * when the track is worth reporting, otherwise why not, in words for the
     * person who filmed it. The numbers go through [formatFixed] so they read
     * exactly as Swift's `String(format:)` prints them, whatever the locale.
     */
    fun rejection(
        track: List<BallObservation>,
        launchAngleDeg: Double,
        flags: List<SwingFlag>,
        fps: Double = 0.0,
        contactTime: Double? = null,
        exitVeloMph: Double = 0.0,
    ): String? {
        val first = track.firstOrNull()
        val last = track.lastOrNull()
        if (first == null || last == null) {
            return "no ball was tracked at all"
        }
        val duration = last.t - first.t
        if (duration > maxFlightS) {
            return "the tracked object stayed in frame for ${formatFixed(duration, 1)} s — a hit ball crosses in a fraction of a second, so this is something in the scene, not the swing"
        }
        if (launchAngleDeg < minLaunchDeg || launchAngleDeg > maxLaunchDeg) {
            return "${formatFixed(launchAngleDeg, 0)}° is not a hit — that is almost straight ${if (launchAngleDeg < 0) "into the ground" else "up"}"
        }
        val straight = TrackBuilder.straightness(track)
        if (straight < minStraightness) {
            return "the path wanders (straightness ${formatFixed(straight, 2)}); a ball in flight does not turn back"
        }
        if (SwingFlag.highResidual in flags) {
            return "the path does not fit a parabola, which a ball in flight must"
        }
        if (fps > 0) {
            val perFrame = diametersPerFrame(track = track, fps = fps)
            if (perFrame != null && perFrame < minDiametersPerFrame) {
                return "the tracked object moved ${formatFixed(perFrame, 2)} of its own width per frame; a struck ball moves about two, so this is something drifting in the scene"
            }
        }
        val contactIsTrustworthy = SwingFlag.contactTimeRejected !in flags
        if (contactIsTrustworthy && contactTime != null &&
            first.t - contactTime > maxStartAfterContactS
        ) {
            return "it was first seen ${formatFixed(first.t - contactTime, 2)} s after contact — a hit ball is at the bat when the bat meets it, so this is something else that moved later in the clip"
        }
        if (contactIsTrustworthy && contactTime != null && last.t < contactTime) {
            return "the whole path was over ${formatFixed((contactTime - last.t) * 1000, 0)} ms before contact — a struck ball's flight begins when the bat meets it, so this is something that crossed beforehand"
        }
        if (exitVeloMph > maxExitVeloMph) {
            return "${formatFixed(exitVeloMph, 0)} mph is faster than any softball has been hit"
        }
        if (track.size < residualMeaninglessBelow) {
            val growth = speedGrowth(track = track)
            if (growth != null && growth > maxShortTrackSpeedGrowth) {
                return "it sped up ${formatFixed(growth, 1)}-fold across ${track.size} frames; a ball in flight holds its speed, and a track this short cannot be checked against a parabola"
            }
        }
        return null
    }

    /** Port of `TrackPlausibility.speedGrowth`; the reasoning lives there. */
    fun speedGrowth(track: List<BallObservation>): Double? {
        val steps = ArrayList<Double>()
        for ((a, b) in track.zipWithNext()) {
            val dt = b.t - a.t
            if (!(dt > 0)) continue
            val dx = b.x - a.x
            val dy = b.y - a.y
            steps.add(sqrt(dx * dx + dy * dy) / dt)
        }
        if (steps.size < 2) return null
        val f = steps.first()
        val l = steps.last()
        if (!(f > 0)) return null
        return l / f
    }

    /** Port of `TrackPlausibility.diametersPerFrame`; the reasoning lives there. */
    fun diametersPerFrame(track: List<BallObservation>, fps: Double): Double? {
        if (!(fps > 0 && track.size >= 2)) return null
        val steps = ArrayList<Double>()
        for ((a, b) in track.zipWithNext()) {
            val dt = b.t - a.t
            if (!(dt > 0)) continue
            val dx = b.x - a.x
            val dy = b.y - a.y
            steps.add(sqrt(dx * dx + dy * dy) / dt)
        }
        val diameters = track.map { it.diameterPx }.filter { it > 0 }.sorted()
        if (steps.isEmpty() || diameters.isEmpty()) return null
        steps.sort()
        val medianStep = steps[steps.size / 2]
        val medianDiameter = diameters[diameters.size / 2]
        if (!(medianDiameter > 0)) return null
        return (medianStep / fps) / medianDiameter
    }
}
