// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs
import kotlin.math.max

/**
 * Port of `ClipDiagnostics.swift` `final class ClipDiagnostics` (what the
 * analyser saw, stage by stage, in a form that fits in a message); the
 * reasoning lives there.
 *
 * The report's wording is the Swift's, character for character: the owner
 * reads it, and `spike/replay_corpus.py` reads the frame rate back out of it
 * when a bundle is ingested. Every number goes through [formatFixed], never
 * `String.format`, so a phone set to a comma-decimal locale writes the same
 * report as any other.
 *
 * Not thread-safe, for the reason the Swift gives.
 */
class ClipDiagnostics {

    // Clip facts
    var fps: Double = 0.0
    var width = 0
    var height = 0
    var durationS: Double = 0.0
    var framesDecoded = 0

    /** Port of `ClipDiagnostics.FPSSource`. */
    enum class FPSSource(val raw: String) {
        measured("measured"),
        container("container"),
        `override`("override"),
    }
    var fpsSource: FPSSource = FPSSource.container
    var containerFps: Double? = null
    var frameIntervalIrregularFraction: Double? = null
    var frameDropFraction: Double? = null
    var ballWindowLearned = false
    var radiusScale: Double? = null
    var elapsedS: Double? = null

    // Stage 1 — Vision's trajectory hint
    var hintPoints: Int? = null
    var hintSpanPx: Double? = null
    var usedBallSeed = false
    var ballSeedFoundNothing = false

    // Stage 2 — colour and shape
    var probedFrames = 0
    // Mutable lists rather than reassigned ones: the analyser appends to these
    // once per frame, and copying a list of every candidate diameter on each
    // append is quadratic.
    val inWindowPixels: MutableList<Int> = mutableListOf()
    var framesWithCandidates = 0
    var totalCandidates = 0
    val candidateDiametersPx: MutableList<Double> = mutableListOf()

    var gateBlobs = 0
    var gateTooSmall = 0
    var gateTooLarge = 0
    var gateTooElongated = 0
    var gateDiameterOutOfRange = 0

    // Stage 3 — tracking
    var tracksBuilt = 0
    var bestTrackFrames = 0
    var selectedStartsAfterContactS: Double? = null
    var tracksNearContact: Int? = null
    var shortTracksNearContact: Int? = null

    // Stage 4 — bat and body
    var batTapeFrames = 0
    var batRejectedReason: String? = null
    var videoQuarterTurns = 0
    var poseFramesSampled = 0
    var poseFramesWithPerson = 0
    val jointSeenCount: MutableMap<PoseJoint, Int> = mutableMapOf()
    val jointConfidenceSum: MutableMap<PoseJoint, Double> = mutableMapOf()

    // Outcome
    var failure: String? = null
    var launchAngleDeg: Double? = null
    var exitVeloMph: Double? = null
    var scaleMPerPx: Double? = null
    var flags: List<String> = emptyList()

    /** Port of `ClipDiagnostics.noteJoint(_:confidence:)`. */
    fun noteJoint(joint: PoseJoint, confidence: Double) {
        jointSeenCount[joint] = (jointSeenCount[joint] ?: 0) + 1
        jointConfidenceSum[joint] = (jointConfidenceSum[joint] ?: 0.0) + confidence
    }

    /** Port of `ClipDiagnostics.report(detector:)`; the reasoning lives there. */
    fun report(detector: DetectorSettings): String {
        val out = mutableListOf("SwingLab clip diagnostics")
        out.add("--------------------------------")
        out.add("clip     ${width}x$height  ${formatFixed(durationS, 1)}s  ${formatFixed(fps, 2)} fps " +
            "(${fpsSource.raw})  $framesDecoded frames decoded")
        val container = containerFps
        if (container != null && abs(container - fps) > 0.5) {
            out.add("         container metadata says ${formatFixed(container, 2)} fps — measured timing used instead")
        }
        val irregularLine = frameIntervalIrregularFraction
        if (irregularLine != null && irregularLine > 0.05) {
            out.add("         ${formatFixed(irregularLine * 100, 0)}% of frame intervals are irregular — variable frame rate, timing is unreliable")
        }
        val droppedLine = frameDropFraction
        if (droppedLine != null && droppedLine > 0.02) {
            out.add("         ${formatFixed(droppedLine * 100, 0)}% of frames never arrived — the timing of the rest is still sound")
        }
        if (videoQuarterTurns != 0) {
            out.add("         buffer is rotated ${videoQuarterTurns * 90}° for display — angles measured after rotating")
        }
        val elapsed = elapsedS
        if (elapsed != null) {
            out.add("took     ${formatFixed(elapsed, 1)}s (${formatFixed(1000 * elapsed / max(1, framesDecoded).toDouble(), 0)} ms per decoded frame)")
        }
        val k = radiusScale ?: 1.0
        out.add("hsv      lo ${formatFixed(detector.hsvLo.h, 0)}/${formatFixed(detector.hsvLo.s, 0)}/${formatFixed(detector.hsvLo.v, 0)}" +
            "  hi ${formatFixed(detector.hsvHi.h, 0)}/${formatFixed(detector.hsvHi.s, 0)}/${formatFixed(detector.hsvHi.v, 0)}" +
            "  radius ${formatFixed(detector.minRadiusPx * k, 0)}-${formatFixed(detector.maxRadiusPx * k, 0)} px")
        if (ballWindowLearned) {
            out.add("           learned from the ball tapped in setup, not the default window")
        }
        val scale = radiusScale
        if (scale != null) {
            out.add("           radii scaled x${formatFixed(scale, 2)} for a $width px wide clip")
        }

        out.add("")
        var visionLine = hintPoints?.let { "flight found, $it points" }
            ?: "no flight found (fell back to full-frame)"
        val span = hintSpanPx
        if (span != null) {
            visionLine += " spanning ${formatFixed(span, 0)} px"
        }
        out.add("1 vision   $visionLine")
        if (usedBallSeed) {
            out.add("           ball picked by hand — selection bypassed")
        } else if (ballSeedFoundNothing) {
            out.add("           ball picked by hand, but nothing was detected there")
        }

        // Swift's `Int` is 64 bits; a sum of per-frame pixel counts is not
        // guaranteed to fit Kotlin's 32.
        val framePixels = max(1L, width.toLong() * height.toLong())
        if (probedFrames > 0) {
            val mean = inWindowPixels.sumOf { it.toLong() } / max(1, inWindowPixels.size).toLong()
            val peak = inWindowPixels.maxOrNull() ?: 0
            out.add("2 colour   $probedFrames frames probed: mean $mean px in window " +
                "(${formatFixed(100.0 * mean.toDouble() / framePixels.toDouble(), 3)}%), peak $peak")
        }
        out.add("3 shape    $framesWithCandidates/$framesDecoded frames produced a candidate, $totalCandidates total")
        if (candidateDiametersPx.isNotEmpty()) {
            val d = candidateDiametersPx.sorted()
            out.add("           diameter px  min ${formatFixed(d.first(), 1)}  median ${formatFixed(d[d.size / 2], 1)}  max ${formatFixed(d.last(), 1)}")
        }
        if (gateBlobs > 0) {
            out.add("           $gateBlobs blobs, $totalCandidates became candidates — rejected: $gateTooSmall too small, " +
                "$gateTooLarge too large, $gateTooElongated smeared past 6:1, $gateDiameterOutOfRange diameter out of range")
        }
        out.add("4 track    $tracksBuilt tracks built, longest $bestTrackFrames frames")
        val offset = selectedStartsAfterContactS
        if (offset != null) {
            out.add("           the chosen track begins ${formatFixed(offset, 3, plusSign = true)} s from contact")
        }
        val near = tracksNearContact
        if (near != null) {
            val short = shortTracksNearContact ?: 0
            out.add("           $near track${if (near == 1) "" else "s"} began within 150 ms of contact, $short of them too short to be scored (needs ${SLA.nearContactMinFrames} frames at contact)")
        }
        if (batTapeFrames == 0) {
            out.add("5 bat      no barrel tape seen — bat metrics not reported")
        } else {
            out.add("5 bat      $batTapeFrames frames with barrel tape")
        }
        val why = batRejectedReason
        if (why != null) {
            out.add("           withheld: $why")
        }

        if (poseFramesSampled > 0) {
            out.add("6 body     person in $poseFramesWithPerson/$poseFramesSampled sampled frames " +
                "(${formatFixed(100.0 * poseFramesWithPerson.toDouble() / poseFramesSampled.toDouble(), 0)}%)")
            for (joint in PoseJoint.entries) {
                val seen = jointSeenCount[joint] ?: 0
                val mean = if (seen > 0) (jointConfidenceSum[joint] ?: 0.0) / seen.toDouble() else 0.0
                // `%-15@ %3d/%3d`: left-justified to 15, numbers right-justified to 3.
                out.add("           ${joint.raw.padEnd(15)} ${seen.toString().padStart(3)}/" +
                    "${poseFramesSampled.toString().padStart(3)}  mean conf ${formatFixed(mean, 2)}")
            }
        } else {
            out.add("6 body     not run")
        }

        for (note in notes()) out.add("note       $note")

        out.add("")
        val failed = failure
        if (failed != null) {
            out.add("result     FAILED — $failed")
        } else {
            out.add("result     ${formatFixed(launchAngleDeg ?: Double.NaN, 1)} deg at " +
                "${formatFixed(exitVeloMph ?: Double.NaN, 1)} mph, scale ${formatFixed(scaleMPerPx ?: Double.NaN, 5)} m/px")
            if (flags.isNotEmpty()) out.add("flags      " + flags.joinToString(" "))
        }
        out.add("verdict    " + verdict())
        return out.joinToString("\n")
    }

    /** Port of `ClipDiagnostics.notes()`; the reasoning lives there. */
    private fun notes(): List<String> {
        val out = mutableListOf<String>()
        if (fps > 0 && fps < 100) {
            out.add(
                "${formatFixed(fps, 0)} fps, measured from the clip's own frame timing rather than its metadata. At this rate the ball moves too far between frames to track: film in slow motion (Camera → Slo-Mo) and import with \"From Photos\", which is the only route that keeps the original high-rate frames. Every other way of getting a clip off the phone renders the slow-motion EDIT, which really is ${formatFixed(fps, 0)} fps.")
        }
        val irregular = frameIntervalIrregularFraction
        if (irregular != null && irregular > 0.05) {
            out.add(
                "${formatFixed(irregular * 100, 0)}% of the frame intervals are not a whole number of frame periods, so the timestamps themselves cannot be trusted — and every measurement here reads frame times from the file. Re-record rather than re-encode: a variable-rate file cannot be repaired after the fact.")
        }
        val dropped = frameDropFraction
        if (dropped != null && dropped > 0.05) {
            out.add(
                "${formatFixed(dropped * 100, 0)}% of the frames never reached the file. The timing of the ones that did is still sound, so the numbers are not biased by this — but the ball is being seen in fewer places, gaps have to be stitched across, and a fast ball can cross the frame inside one. This is the capture keeping up, not the footage: check the dropped-frame chip while armed, and if it says buffers, close other apps and let the phone cool.")
        }
        val offset = selectedStartsAfterContactS
        if (offset != null && offset > 0.25) {
            var line =
                "the track this measurement came from begins ${formatFixed(offset, 2)} s after contact. Selection keeps any track starting at or after contact and then scores on speed alone, with no upper bound, so a fast object later in the clip outranks a slower one at the bat."
            val short = shortTracksNearContact
            if (short != null && short > 0) {
                line += " $short track${if (short == 1) " was" else "s were"} found at contact and dropped for being shorter than ${SLA.nearContactMinFrames} frames."
            }
            line += " Treat this reading as unattributed: it may not be the ball that was hit."
            out.add(line)
        }
        val fraction = inWindowFraction
        if (fraction != null && fraction > 0.02 && candidatesPerFrame <= 5) {
            out.add(
                "${formatFixed(fraction * 100, 1)}% of every frame matches the ball's colour window — wide, but only ${formatFixed(candidatesPerFrame, 1)} candidates a frame survived, because almost none of it was moving. The motion gate is carrying this clip; if the camera is ever hand-held or the background thrashes in wind, that margin goes and the colour window will not hold on its own. Raising the LOWER SATURATION (Settings → Ball colour) is the fix that does not depend on it.")
        }
        if (fraction != null && fraction > 0.02 && candidatesPerFrame > 5) {
            out.add(
                "${formatFixed(fraction * 100, 1)}% of every frame matches the ball's colour window. A ball at this distance is a few hundredths of one percent, so the window is admitting the background wholesale — sunlit grass is the usual culprit, since it shares optic yellow's hue. Raise the LOWER SATURATION first (Settings → Ball colour): vegetation is dull where the ball is fluorescent, and that one number separates them without touching the hue at all.")
        }
        if (durationS > 20) {
            out.add(
                "${formatFixed(durationS, 0)}s long — a whole session rather than one swing. Only the single best track in the file is measured, so the other swings in it are discarded silently. Trim to the swing you care about.")
        }
        if (width > 0 && width < 1900 && radiusScale == null) {
            out.add(
                "$width px wide, not 1920. The ball is correspondingly smaller, so the minimum-radius gate may reject it.")
        }
        return out
    }

    /** Port of `ClipDiagnostics.inWindowFraction`. */
    private val inWindowFraction: Double?
        get() {
            if (!(probedFrames > 0 && inWindowPixels.isNotEmpty() && width > 0 && height > 0)) return null
            val mean = inWindowPixels.sumOf { it.toLong() }.toDouble() / inWindowPixels.size.toDouble()
            return mean / (width.toLong() * height.toLong()).toDouble()
        }

    /** Port of `ClipDiagnostics.candidatesPerFrame`. */
    private val candidatesPerFrame: Double
        get() = if (framesDecoded > 0) totalCandidates.toDouble() / framesDecoded.toDouble() else 0.0

    /** Port of `ClipDiagnostics.verdict()`; the reasoning lives there. */
    private fun verdict(): String {
        if (framesDecoded == 0) {
            val readMetadata = width > 0 && durationS > 0
            return if (readMetadata)
                "the file's metadata read fine but not one frame decoded — that is the hardware video decoder being unavailable, not a bad file. Close anything else using the camera and retry."
            else
                "clip could not be decoded at all"
        }
        if (probedFrames > 0 && (inWindowPixels.maxOrNull() ?: 0) < 20) {
            return "the ball's colour is outside the HSV window — almost nothing in any frame matched. Widen it, or the ball is not optic yellow under this light."
        }
        if (framesWithCandidates == 0) {
            return "colour matched but nothing passed the size and shape gates. Check the diameter range against how big the ball actually is here."
        }
        val fraction = inWindowFraction
        if (fraction != null && fraction > 0.05 && candidatesPerFrame > 5) {
            return "the colour window is far too wide — ${formatFixed(fraction * 100, 0)}% of every frame matches it, and ${formatFixed(candidatesPerFrame, 0)} candidates a frame are getting through. Everything after this stage is measuring background. Raise the lower saturation in Settings → Ball colour."
        }
        if (bestTrackFrames < 3) {
            return "candidates were found but never linked into a flight — they are probably not the same object frame to frame (background clutter of a similar colour)."
        }
        if (failure != null) {
            return "a track was built but analysis rejected it; see the failure line."
        }
        if (bestTrackFrames < SLA.minTrackFrames) {
            return "measured, but off a short track — treat the number as provisional."
        }

        if (fps > 0) {
            val trackSeconds = bestTrackFrames.toDouble() / fps
            if (trackSeconds > implausibleTrackSeconds) {
                return "the longest \"flight\" lasts ${formatFixed(trackSeconds, 1)} s. A hit ball crosses the frame in a fraction of a second, so this is a stationary object of about the right colour being tracked, not a swing — look at the colour line above: if a large share of every frame matches, the detector is following the background."
            }
        }

        if (flags.contains("CONTACT_TIME_REJECTED")) {
            return "the trigger fired well before the ball was seen leaving the bat, so the microphone heard something that was not this hit — and the two-second refractory window then covered the real crack. Contact has been taken from the first frame of the flight instead, so the reading stands, but the bat panel is gone and the next swing at this venue will do the same thing. Settings → Trigger → Calibrate measures what a hit here actually sounds like."
        }

        if (flags.contains("HIGH_RESIDUAL")) {
            return "a track was measured but it does not fit a parabola, which a ball in flight must. The points being tracked are not one object moving ballistically — most often background clutter sharing the ball's colour."
        }

        val angle = launchAngleDeg
        if (angle != null && (angle < plausibleLaunchLoDeg || angle > plausibleLaunchHiDeg)) {
            return "measured ${formatFixed(angle, 0)} degrees, which is not a hit — that is the ball going almost straight ${if (angle < 0) "into the ground" else "up"}. Whatever was tracked, it was not a struck ball."
        }

        if (flags.contains("DEPTH_MOTION")) {
            return "the ball was moving toward or away from the camera rather than across it, so it is foreshortened and reads slow. This is a camera-placement problem, not a detection one: stand square to the flight, on the side the hitter faces."
        }

        return "clean run."
    }

    private companion object {
        /** Port of `ClipDiagnostics.implausibleTrackSeconds`. */
        const val implausibleTrackSeconds = 2.5
        /** Port of `ClipDiagnostics.plausibleLaunchLoDeg`. */
        const val plausibleLaunchLoDeg = -25.0
        /** Port of `ClipDiagnostics.plausibleLaunchHiDeg`. */
        const val plausibleLaunchHiDeg = 75.0
    }
}
