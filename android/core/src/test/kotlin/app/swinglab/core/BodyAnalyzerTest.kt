// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of the "Body metrics" cases in `app/Tests/PipelineTests.swift`, which
 * exercise `BodyAnalyzer.analyze` and `PoseObservation` — this slice's code —
 * from a file that otherwise belongs to the pipeline.
 */
class BodyAnalyzerTest {

    @Test
    fun frontLegFollowsTheBallDirection() {
        val joints = mapOf(
            PoseJoint.leftAnkle to PosePoint(400.0, 900.0, 0.9),
            PoseJoint.rightAnkle to PosePoint(600.0, 900.0, 0.9),
            PoseJoint.leftHip to PosePoint(470.0, 560.0, 0.9),
            PoseJoint.rightHip to PosePoint(560.0, 560.0, 0.9),
            PoseJoint.leftKnee to PosePoint(440.0, 730.0, 0.9),
            PoseJoint.rightKnee to PosePoint(590.0, 730.0, 0.9),
            PoseJoint.leftShoulder to PosePoint(480.0, 330.0, 0.9),
            PoseJoint.rightShoulder to PosePoint(570.0, 330.0, 0.9),
            PoseJoint.nose to PosePoint(525.0, 250.0, 0.9),
        )
        val track = listOf(
            PoseObservation(frame = 0, t = 0.0, joints = joints),
            PoseObservation(frame = 60, t = 0.25, joints = joints),
        )

        val left = BodyAnalyzer.analyze(track, contactTime = 0.25, scaleMPerPx = 1.0 / 240, ballDirectionX = -1.0)
        assertNotNull(left.frontKneeDeg)
        val right = BodyAnalyzer.analyze(track, contactTime = 0.25, scaleMPerPx = 1.0 / 240, ballDirectionX = 1.0)
        assertNotNull(right.frontKneeDeg)
        assertNotEquals(left.frontKneeDeg!!, right.frontKneeDeg!!,
            "the two legs are not mirror images here, so the readings must differ")
    }

    @Test
    fun lowConfidenceJointsAreTreatedAsMissing() {
        val obs = PoseObservation(frame = 0, t = 0.0, joints = mapOf(
            PoseJoint.leftHip to PosePoint(100.0, 100.0, 0.9),
            PoseJoint.rightHip to PosePoint(140.0, 100.0, 0.05),
        ))
        assertNotNull(obs.point(PoseJoint.leftHip))
        assertNull(obs.point(PoseJoint.rightHip), "below SLA.jointConfidenceMin")
        assertNull(obs.midpoint(PoseJoint.leftHip, PoseJoint.rightHip),
            "a hip centre from one hip would move half a body width between frames")
    }

    @Test
    fun anglesSurviveAMissingScaleButDistancesDoNot() {
        val joints = mapOf(
            PoseJoint.leftAnkle to PosePoint(400.0, 900.0, 0.9),
            PoseJoint.rightAnkle to PosePoint(600.0, 900.0, 0.9),
            PoseJoint.leftHip to PosePoint(470.0, 560.0, 0.9),
            PoseJoint.rightHip to PosePoint(560.0, 560.0, 0.9),
            PoseJoint.leftKnee to PosePoint(440.0, 730.0, 0.9),
            PoseJoint.leftShoulder to PosePoint(480.0, 330.0, 0.9),
            PoseJoint.rightShoulder to PosePoint(570.0, 330.0, 0.9),
            PoseJoint.nose to PosePoint(525.0, 250.0, 0.9),
        )
        val track = listOf(
            PoseObservation(frame = 0, t = 0.0, joints = joints),
            PoseObservation(frame = 60, t = 0.25, joints = joints),
        )
        val m = BodyAnalyzer.analyze(track, contactTime = 0.25, scaleMPerPx = null, ballDirectionX = -1.0)
        assertNotNull(m.frontKneeDeg)
        assertNotNull(m.spineTiltDeg)
        assertNull(m.strideM)
        assertNull(m.headDriftM)
        assertNull(m.weightShiftM)
    }

    @Test
    fun implausibleHeadDriftIsWithheld() {
        fun obs(t: Double, headX: Double) = PoseObservation(frame = (t * 240).toInt(), t = t, joints = mapOf(
            PoseJoint.nose to PosePoint(headX, 250.0, 0.9),
            PoseJoint.leftHip to PosePoint(470.0, 560.0, 0.9),
            PoseJoint.rightHip to PosePoint(560.0, 560.0, 0.9),
        ))
        val m = BodyAnalyzer.analyze(listOf(obs(0.0, 200.0), obs(0.25, 500.0)),
            contactTime = 0.25, scaleMPerPx = 1.0 / 240, ballDirectionX = -1.0)
        assertNull(m.headDriftM)
        val ok = BodyAnalyzer.analyze(listOf(obs(0.0, 500.0), obs(0.25, 520.0)),
            contactTime = 0.25, scaleMPerPx = 1.0 / 240, ballDirectionX = -1.0)
        assertNotNull(ok.headDriftM)
    }

    // Kotlin-only: the parts of PoseObservation.swift the Swift tests reach only
    // through the app.

    @Test
    fun jointRawValuesAreThePythonNamesAndRoundTrip() {
        for (j in PoseJoint.entries) assertTrue(PoseJoint.fromRaw(j.raw) == j)
        assertTrue(PoseJoint.leftShoulder.raw == "left_shoulder")
        assertTrue(PoseJoint.rightWrist.raw == "right_wrist")
        assertNull(PoseJoint.fromRaw("leftShoulder"))
    }

    @Test
    fun onlyTheArmsAreDrawingOnly() {
        val drawn = PoseJoint.entries.filter { it.isDrawingOnly }.toSet()
        assertTrue(drawn == setOf(PoseJoint.leftElbow, PoseJoint.rightElbow,
            PoseJoint.leftWrist, PoseJoint.rightWrist))
        assertFalse(BodyMetrics().hasAnything)
        assertTrue(BodyMetrics(spineTiltDeg = 3.0).hasAnything)
    }
}
