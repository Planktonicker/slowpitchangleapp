// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Kotlin-only: `ClipDiagnostics.swift` has no tests. The report is read by the
 * owner and parsed by `spike/replay_corpus.py`, so its wording is pinned here
 * line by line, each expected line written out from the Swift's own format
 * string rather than from this port.
 */
class ClipDiagnosticsTest {

    private val detector = DetectorSettings(
        hsvLo = HSVBounds(h = 25.0, s = 80.0, v = 120.0),
        hsvHi = HSVBounds(h = 40.0, s = 255.0, v = 255.0),
        minRadiusPx = 3.0, maxRadiusPx = 25.0,
    )

    /** A measured clip that ran to the end, with most optional lines switched on. */
    private fun measured(): ClipDiagnostics = ClipDiagnostics().apply {
        fps = 239.058413
        width = 1920
        height = 1080
        durationS = 3.3
        framesDecoded = 780
        fpsSource = ClipDiagnostics.FPSSource.measured
        containerFps = 30.0
        frameIntervalIrregularFraction = 0.0
        frameDropFraction = 0.30
        videoQuarterTurns = 1
        elapsedS = 11.2
        ballWindowLearned = true
        hintPoints = 42
        hintSpanPx = 812.4
        probedFrames = 8
        inWindowPixels.addAll(listOf(1000, 2000, 3000, 2400, 1600, 1200, 800, 400))
        framesWithCandidates = 120
        totalCandidates = 150
        candidateDiametersPx.addAll(listOf(10.0, 11.5, 12.2, 9.7, 13.0))
        gateBlobs = 400
        gateTooSmall = 100
        gateTooLarge = 50
        gateTooElongated = 60
        gateDiameterOutOfRange = 40
        tracksBuilt = 12
        bestTrackFrames = 24
        selectedStartsAfterContactS = 0.012
        tracksNearContact = 3
        shortTracksNearContact = 1
        launchAngleDeg = 23.44
        exitVeloMph = 71.26
        scaleMPerPx = 0.0021234
        flags = listOf("DEPTH_MOTION")
    }

    @Test
    fun aMeasuredRunReadsExactlyAsTheSwiftWritesIt() {
        val expected = listOf(
            "SwingLab clip diagnostics",
            "--------------------------------",
            "clip     1920x1080  3.3s  239.06 fps (measured)  780 frames decoded",
            "         container metadata says 30.00 fps — measured timing used instead",
            "         30% of frames never arrived — the timing of the rest is still sound",
            "         buffer is rotated 90° for display — angles measured after rotating",
            "took     11.2s (14 ms per decoded frame)",
            "hsv      lo 25/80/120  hi 40/255/255  radius 3-25 px",
            "           learned from the ball tapped in setup, not the default window",
            "",
            "1 vision   flight found, 42 points spanning 812 px",
            "2 colour   8 frames probed: mean 1550 px in window (0.075%), peak 3000",
            "3 shape    120/780 frames produced a candidate, 150 total",
            "           diameter px  min 9.7  median 11.5  max 13.0",
            "           400 blobs, 150 became candidates — rejected: 100 too small, 50 too large, 60 smeared past 6:1, 40 diameter out of range",
            "4 track    12 tracks built, longest 24 frames",
            "           the chosen track begins +0.012 s from contact",
            "           3 tracks began within 150 ms of contact, 1 of them too short to be scored (needs 4 frames at contact)",
            "5 bat      no barrel tape seen — bat metrics not reported",
            "6 body     not run",
            "note       30% of the frames never reached the file. The timing of the ones that did is still sound, so the numbers are not biased by this — but the ball is being seen in fewer places, gaps have to be stitched across, and a fast ball can cross the frame inside one. This is the capture keeping up, not the footage: check the dropped-frame chip while armed, and if it says buffers, close other apps and let the phone cool.",
            "",
            "result     23.4 deg at 71.3 mph, scale 0.00212 m/px",
            "flags      DEPTH_MOTION",
            "verdict    the ball was moving toward or away from the camera rather than across it, so it is foreshortened and reads slow. This is a camera-placement problem, not a detection one: stand square to the flight, on the side the hitter faces.",
        )
        assertEquals(expected, measured().report(detector).split("\n"))
    }

    /** `spike/replay_corpus.py` `fps_from_bundle_entry`: the first `([\d.]+)\s*fps` in the report is the rate. */
    @Test
    fun theCorpusToolReadsTheMeasuredRateBackOut() {
        val report = measured().report(detector)
        val m = assertNotNull(Regex("""([\d.]+)\s*fps""").find(report))
        assertEquals("239.06", m.groupValues[1])
    }

    /** `formatFixed`, not `String.format`: a German phone must not write `239,06 fps`. */
    @Test
    fun theReportDoesNotFollowThePhoneLocale() {
        val saved = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            val report = measured().report(detector)
            assertTrue(report.contains("239.06 fps (measured)"))
            assertTrue(report.contains("scale 0.00212 m/px"))
        } finally {
            Locale.setDefault(saved)
        }
    }

    @Test
    fun aFailureIsReportedInsteadOfAResult() {
        val d = measured().apply {
            failure = ClipAnalysisError.noBallTrack.errorDescription
            radiusScale = 0.5
            width = 960
            height = 540
            usedBallSeed = false
            ballSeedFoundNothing = true
            hintPoints = null
            hintSpanPx = null
            batTapeFrames = 7
            batRejectedReason = "it was not moving like a barrel"
        }
        val lines = d.report(detector).split("\n")
        assertTrue("hsv      lo 25/80/120  hi 40/255/255  radius 2-12 px" in lines, "radii shown as scaled")
        assertTrue("           radii scaled x0.50 for a 960 px wide clip" in lines)
        assertTrue("1 vision   no flight found (fell back to full-frame)" in lines)
        assertTrue("           ball picked by hand, but nothing was detected there" in lines)
        assertTrue("5 bat      7 frames with barrel tape" in lines)
        assertTrue("           withheld: it was not moving like a barrel" in lines)
        assertTrue("result     FAILED — No ball flight found in this clip. Check that the ball is optic yellow and in frame, or widen the colour range in Settings." in lines)
        assertFalse(lines.any { it.startsWith("flags") }, "no flags line for a failure")
        assertEquals("verdict    a track was built but analysis rejected it; see the failure line.", lines.last())
        // A rescaled clip is narrow on purpose; the width note is for one that was not rescaled.
        assertFalse(lines.any { it.contains("px wide, not 1920") })
    }

    @Test
    fun anUnmeasuredResultPrintsNanAsTheSwiftDoes() {
        val d = measured().apply {
            launchAngleDeg = null
            exitVeloMph = null
            scaleMPerPx = null
            flags = emptyList()
        }
        val lines = d.report(detector).split("\n")
        assertTrue("result     nan deg at nan mph, scale nan m/px" in lines)
        assertFalse(lines.any { it.startsWith("flags") })
    }

    @Test
    fun theBodyStageListsEveryJointInOrder() {
        val d = measured().apply {
            poseFramesSampled = 40
            poseFramesWithPerson = 30
            noteJoint(PoseJoint.nose, confidence = 0.9)
            noteJoint(PoseJoint.nose, confidence = 0.7)
            noteJoint(PoseJoint.rightShoulder, confidence = 0.55)
        }
        val lines = d.report(detector).split("\n")
        val start = lines.indexOf("6 body     person in 30/40 sampled frames (75%)")
        assertTrue(start >= 0, "body header")
        val jointLines = lines.subList(start + 1, start + 1 + PoseJoint.entries.size)
        assertEquals("           nose              2/ 40  mean conf 0.80", jointLines[0])
        assertEquals("           neck              0/ 40  mean conf 0.00", jointLines[1])
        assertEquals("           right_shoulder    1/ 40  mean conf 0.55", jointLines[3])
        assertEquals(PoseJoint.entries.map { it.raw }, jointLines.map { it.trim().split(" ")[0] })
    }

    @Test
    fun notesNameTheFootageProblems() {
        val d = ClipDiagnostics().apply {
            fps = 30.0
            width = 1280
            height = 720
            durationS = 42.0
            framesDecoded = 1260
            frameIntervalIrregularFraction = 0.4
            probedFrames = 4
            // 3% of a 1280x720 frame matches; few candidates survive.
            inWindowPixels.addAll(List(4) { 27648 })
            framesWithCandidates = 100
            totalCandidates = 300
            tracksBuilt = 5
            bestTrackFrames = 20
            selectedStartsAfterContactS = 0.74
            tracksNearContact = 2
            shortTracksNearContact = 2
            launchAngleDeg = 20.0
            exitVeloMph = 60.0
            scaleMPerPx = 0.002
        }
        val lines = d.report(detector).split("\n")
        assertTrue("         40% of frame intervals are irregular — variable frame rate, timing is unreliable" in lines)
        val notes = lines.filter { it.startsWith("note       ") }.map { it.removePrefix("note       ") }
        assertEquals(6, notes.size, notes.joinToString("\n"))
        assertEquals("30 fps, measured from the clip's own frame timing rather than its metadata. At this rate the ball moves too far between frames to track: film in slow motion (Camera → Slo-Mo) and import with \"From Photos\", which is the only route that keeps the original high-rate frames. Every other way of getting a clip off the phone renders the slow-motion EDIT, which really is 30 fps.", notes[0])
        assertEquals("40% of the frame intervals are not a whole number of frame periods, so the timestamps themselves cannot be trusted — and every measurement here reads frame times from the file. Re-record rather than re-encode: a variable-rate file cannot be repaired after the fact.", notes[1])
        assertEquals("the track this measurement came from begins 0.74 s after contact. Selection keeps any track starting at or after contact and then scores on speed alone, with no upper bound, so a fast object later in the clip outranks a slower one at the bat. 2 tracks were found at contact and dropped for being shorter than 4 frames. Treat this reading as unattributed: it may not be the ball that was hit.", notes[2])
        assertEquals("3.0% of every frame matches the ball's colour window — wide, but only 0.2 candidates a frame survived, because almost none of it was moving. The motion gate is carrying this clip; if the camera is ever hand-held or the background thrashes in wind, that margin goes and the colour window will not hold on its own. Raising the LOWER SATURATION (Settings → Ball colour) is the fix that does not depend on it.", notes[3])
        assertEquals("42s long — a whole session rather than one swing. Only the single best track in the file is measured, so the other swings in it are discarded silently. Trim to the swing you care about.", notes[4])
        assertEquals("1280 px wide, not 1920. The ball is correspondingly smaller, so the minimum-radius gate may reject it.", notes[5])
    }

    @Test
    fun oneShortTrackAtContactIsSingular() {
        val d = measured().apply {
            selectedStartsAfterContactS = 0.5
            tracksNearContact = 1
            shortTracksNearContact = 1
        }
        val lines = d.report(detector).split("\n")
        assertTrue("           1 track began within 150 ms of contact, 1 of them too short to be scored (needs 4 frames at contact)" in lines)
        assertTrue(lines.any { it.contains(" 1 track was found at contact and dropped for being shorter than 4 frames.") })
        assertTrue("           the chosen track begins +0.500 s from contact" in lines)
    }

    @Test
    fun aSwampingColourWindowIsTheVerdict() {
        val d = measured().apply {
            inWindowPixels.clear()
            inWindowPixels.addAll(List(8) { 207360 })   // 10% of every frame
            totalCandidates = 7800                       // 10 a frame
        }
        val lines = d.report(detector).split("\n")
        assertTrue(lines.any { it == "note       10.0% of every frame matches the ball's colour window. A ball at this distance is a few hundredths of one percent, so the window is admitting the background wholesale — sunlit grass is the usual culprit, since it shares optic yellow's hue. Raise the LOWER SATURATION first (Settings → Ball colour): vegetation is dull where the ball is fluorescent, and that one number separates them without touching the hue at all." })
        assertEquals("verdict    the colour window is far too wide — 10% of every frame matches it, and 10 candidates a frame are getting through. Everything after this stage is measuring background. Raise the lower saturation in Settings → Ball colour.", lines.last())
    }

    /** Each rung of `verdict()`, in the order the Swift checks them. */
    @Test
    fun theVerdictNamesTheStageThatFailed() {
        fun verdictOf(d: ClipDiagnostics) = d.report(detector).split("\n").last().removePrefix("verdict    ")

        assertEquals("clip could not be decoded at all",
            verdictOf(ClipDiagnostics()))
        assertEquals("the file's metadata read fine but not one frame decoded — that is the hardware video decoder being unavailable, not a bad file. Close anything else using the camera and retry.",
            verdictOf(ClipDiagnostics().apply { width = 1920; durationS = 2.0 }))
        assertEquals("the ball's colour is outside the HSV window — almost nothing in any frame matched. Widen it, or the ball is not optic yellow under this light.",
            verdictOf(measured().apply { inWindowPixels.clear(); inWindowPixels.addAll(listOf(3, 19)) }))
        assertEquals("colour matched but nothing passed the size and shape gates. Check the diameter range against how big the ball actually is here.",
            verdictOf(measured().apply { framesWithCandidates = 0 }))
        assertEquals("candidates were found but never linked into a flight — they are probably not the same object frame to frame (background clutter of a similar colour).",
            verdictOf(measured().apply { bestTrackFrames = 2 }))
        assertEquals("measured, but off a short track — treat the number as provisional.",
            verdictOf(measured().apply { bestTrackFrames = 7 }))
        assertEquals("the longest \"flight\" lasts 4.2 s. A hit ball crosses the frame in a fraction of a second, so this is a stationary object of about the right colour being tracked, not a swing — look at the colour line above: if a large share of every frame matches, the detector is following the background.",
            verdictOf(measured().apply { fps = 240.0; bestTrackFrames = 1008 }))
        assertEquals("the trigger fired well before the ball was seen leaving the bat, so the microphone heard something that was not this hit — and the two-second refractory window then covered the real crack. Contact has been taken from the first frame of the flight instead, so the reading stands, but the bat panel is gone and the next swing at this venue will do the same thing. Settings → Trigger → Calibrate measures what a hit here actually sounds like.",
            verdictOf(measured().apply { flags = listOf("HIGH_RESIDUAL", "CONTACT_TIME_REJECTED") }))
        assertEquals("a track was measured but it does not fit a parabola, which a ball in flight must. The points being tracked are not one object moving ballistically — most often background clutter sharing the ball's colour.",
            verdictOf(measured().apply { flags = listOf("DEPTH_MOTION", "HIGH_RESIDUAL") }))
        assertEquals("measured -66 degrees, which is not a hit — that is the ball going almost straight into the ground. Whatever was tracked, it was not a struck ball.",
            verdictOf(measured().apply { launchAngleDeg = -66.0 }))
        assertEquals("measured 80 degrees, which is not a hit — that is the ball going almost straight up. Whatever was tracked, it was not a struck ball.",
            verdictOf(measured().apply { launchAngleDeg = 80.0; flags = emptyList() }))
        assertEquals("clean run.",
            verdictOf(measured().apply { flags = emptyList() }))
    }

    @Test
    fun clipAnalysisErrorsCarryTheSwiftsWords() {
        assertEquals("That clip has no video track.", ClipAnalysisError.noVideoTrack.message)
        assertEquals("Could not read the clip: decoder busy", ClipAnalysisError.readerFailed("decoder busy").message)
        assertTrue(ClipAnalysisError.noBallAtSeed.errorDescription.startsWith("No ball was detected where you tapped. That is a DETECTION problem"))
        assertEquals(ClipAnalysisError.readerFailed("x"), ClipAnalysisError.readerFailed("x"))
    }
}
