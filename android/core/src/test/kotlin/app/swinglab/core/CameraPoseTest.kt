// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.tan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of `app/Tests/CameraPoseTests.swift` `CameraPoseTests`, plus
 * `PlacementWizardTests.testTheTwoLandscapesAgreeAboutWhereATapLanded`, which
 * pins `CameraPose.uprightBufferPoint` alone. (The same Swift file's
 * `FrameTimingTests` exercise `ClipAnalyzer.frameTiming` and belong with
 * ClipAnalyzer's port.)
 */
class CameraPoseTest {

    // A typical iPhone wide lens.
    private val fov = 68.0

    // Field of view

    @Test
    fun verticalHalfAngleIsNarrowerThanHorizontal() {
        val v = assertNotNull(CameraPose.verticalHalfAngleDeg(horizontalFovDeg = fov, frameAspect = 16.0 / 9.0))
        assertTrue(v < fov / 2)
        assertEquals(20.78, v, 0.02)
    }

    @Test
    fun squareFrameHasEqualHalfAngles() {
        val v = assertNotNull(CameraPose.verticalHalfAngleDeg(horizontalFovDeg = fov, frameAspect = 1.0))
        assertEquals(fov / 2, v, 1e-9)
    }

    @Test
    fun nonsenseOpticsReturnNil() {
        assertNull(CameraPose.verticalHalfAngleDeg(horizontalFovDeg = 0.0, frameAspect = 1.78))
        assertNull(CameraPose.verticalHalfAngleDeg(horizontalFovDeg = fov, frameAspect = 0.0))
    }

    @Test
    fun portraitSeesMoreVerticallyThanLandscape() {
        val portrait = assertNotNull(CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg = fov, isLandscape = false, screenAspect = 9.0 / 19.5))
        val landscape = assertNotNull(CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg = fov, isLandscape = true, screenAspect = 19.5 / 9.0))
        assertTrue(portrait > landscape)
        assertEquals(fov / 2, portrait, 1e-9)
    }

    // Horizon

    @Test
    fun levelCameraPutsHorizonAtFrameCentre() {
        val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = 0.0, visibleVerticalHalfAngleDeg = 21.0))
        assertEquals(0.5, f, 1e-9)
    }

    @Test
    fun aimingDownRaisesTheHorizon() {
        val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = 10.0, visibleVerticalHalfAngleDeg = 21.0))
        assertTrue(f < 0.5)
    }

    @Test
    fun aimingUpLowersTheHorizon() {
        val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = -10.0, visibleVerticalHalfAngleDeg = 21.0))
        assertTrue(f > 0.5)
    }

    @Test
    fun tiltOfHalfAngleLandsHorizonOnTheEdge() {
        val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = 21.0, visibleVerticalHalfAngleDeg = 21.0))
        assertEquals(0.0, f, 1e-9)
    }

    @Test
    fun horizonIsReportedOffFrameRatherThanClamped() {
        val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = 40.0, visibleVerticalHalfAngleDeg = 21.0))
        assertTrue(f < 0, "an off-frame horizon must stay off-frame so the UI can say so")
    }

    @Test
    fun horizonUndefinedPastVertical() {
        assertNull(CameraPose.horizonFraction(tiltDeg = 90.0, visibleVerticalHalfAngleDeg = 21.0))
    }

    // Tilt from a placed horizon

    @Test
    fun tiltRoundTripsThroughTheHorizon() {
        for (tilt in listOf(-30.0, -12.0, -3.0, 0.0, 4.5, 15.0, 33.0)) {
            val f = assertNotNull(CameraPose.horizonFraction(tiltDeg = tilt, visibleVerticalHalfAngleDeg = 21.0))
            val back = assertNotNull(CameraPose.tiltDeg(forHorizonFraction = f, visibleVerticalHalfAngleDeg = 21.0))
            assertEquals(tilt, back, 1e-6)
        }
    }

    @Test
    fun horizonAtFrameCentreIsLevel() {
        val t = assertNotNull(CameraPose.tiltDeg(forHorizonFraction = 0.5, visibleVerticalHalfAngleDeg = 21.0))
        assertEquals(0.0, t, 1e-9)
    }

    @Test
    fun horizonBelowCentreMeansAimingUp() {
        val t = assertNotNull(CameraPose.tiltDeg(forHorizonFraction = 0.8, visibleVerticalHalfAngleDeg = 21.0))
        assertTrue(t < 0)
    }

    @Test
    fun horizonAboveCentreMeansAimingDown() {
        val t = assertNotNull(CameraPose.tiltDeg(forHorizonFraction = 0.2, visibleVerticalHalfAngleDeg = 21.0))
        assertTrue(t > 0)
    }

    // Lens height

    @Test
    fun levelCameraOnTheGroundReadsZeroHeight() {
        val h = CameraPose.lensHeightM(feetFraction = 0.5, distanceM = 5.0, tiltDeg = 0.0, verticalHalfAngleDeg = 21.0)
        assertNull(h)
    }

    @Test
    fun feetBelowCentreGiveAPositiveHeight() {
        val h = assertNotNull(CameraPose.lensHeightM(
            feetFraction = 0.75, distanceM = 5.0, tiltDeg = 0.0, verticalHalfAngleDeg = 21.0))
        assertTrue(h > 0)
        assertEquals(5 * 0.5 * tan(21 * PI / 180), h, 1e-6)
    }

    @Test
    fun feetAtFrameBottomOfLevelCameraGiveTheFullHalfAngle() {
        val h = assertNotNull(CameraPose.lensHeightM(
            feetFraction = 1.0, distanceM = 5.0, tiltDeg = 0.0, verticalHalfAngleDeg = 21.0))
        assertEquals(5 * tan(21 * PI / 180), h, 1e-6)
    }

    @Test
    fun heightRoundTripsThroughTheProjection() {
        val vHalf = 21.0; val distance = 5.25; val tilt = 6.0; val trueHeight = 1.1
        val depression = atan(trueHeight / distance)
        val offAxis = depression - tilt * PI / 180
        val feet = 0.5 + tan(offAxis) / (2 * tan(vHalf * PI / 180))
        val recovered = assertNotNull(CameraPose.lensHeightM(
            feetFraction = feet, distanceM = distance, tiltDeg = tilt, verticalHalfAngleDeg = vHalf))
        assertEquals(trueHeight, recovered, 1e-6)
    }

    @Test
    fun feetAboveTheHorizonReturnNil() {
        assertNull(CameraPose.lensHeightM(feetFraction = 0.2, distanceM = 5.0, tiltDeg = 0.0, verticalHalfAngleDeg = 21.0))
    }

    @Test
    fun absurdDistanceReturnsNil() {
        assertNull(CameraPose.lensHeightM(feetFraction = 0.8, distanceM = 0.0, tiltDeg = 0.0, verticalHalfAngleDeg = 21.0))
    }

    // Outline validity

    @Test
    fun outlineValidWhenLevelAndAtContactHeight() {
        assertTrue(CameraPose.outlineIsValid(tiltDeg = 1.0, tiltToleranceDeg = 3.0, lensHeightM = 1.1))
    }

    @Test
    fun outlineInvalidForAPhoneOnTheGroundAimedUp() {
        assertFalse(CameraPose.outlineIsValid(tiltDeg = -18.0, tiltToleranceDeg = 3.0, lensHeightM = 0.1))
    }

    @Test
    fun outlineInvalidOnHeightAloneEvenWhenPerfectlyLevel() {
        assertFalse(CameraPose.outlineIsValid(tiltDeg = 0.0, tiltToleranceDeg = 3.0, lensHeightM = 0.15))
    }

    @Test
    fun unmeasuredHeightDoesNotInvalidateTheOutline() {
        assertTrue(CameraPose.outlineIsValid(tiltDeg = 0.0, tiltToleranceDeg = 3.0, lensHeightM = null))
    }

    @Test
    fun unknownTiltInvalidatesTheOutline() {
        assertFalse(CameraPose.outlineIsValid(tiltDeg = null, tiltToleranceDeg = 3.0, lensHeightM = 1.1))
    }

    // Feet from the pose

    @Test
    fun feetFractionPassesThroughWhenUpright() {
        val joints = mapOf(
            PoseJoint.leftAnkle to Point(0.3, 0.80),
            PoseJoint.rightAnkle to Point(0.32, 0.84),
        )
        val f = assertNotNull(SetupOverlay.feetFraction(from = joints, orientation = ImagePropertyOrientation.up))
        assertEquals(0.82, f, 1e-9)
    }

    @Test
    fun feetFractionInvertsForTheOtherLandscape() {
        val joints = mapOf(PoseJoint.leftAnkle to Point(0.3, 0.80))
        val f = assertNotNull(SetupOverlay.feetFraction(from = joints, orientation = ImagePropertyOrientation.down))
        assertEquals(0.20, f, 1e-9)
    }

    @Test
    fun feetFractionRefusesPortrait() {
        val joints = mapOf(PoseJoint.leftAnkle to Point(0.3, 0.80))
        assertNull(SetupOverlay.feetFraction(from = joints, orientation = ImagePropertyOrientation.right))
        assertNull(SetupOverlay.feetFraction(from = joints, orientation = ImagePropertyOrientation.left))
    }

    @Test
    fun feetFractionNeedsAnAnkle() {
        assertNull(SetupOverlay.feetFraction(from = null, orientation = ImagePropertyOrientation.up))
        assertNull(SetupOverlay.feetFraction(
            from = mapOf(PoseJoint.nose to Point(0.3, 0.2)), orientation = ImagePropertyOrientation.up))
    }

    // From PlacementWizardTests: the one assertion there that is CameraPose alone.

    @Test
    fun theTwoLandscapesAgreeAboutWhereATapLanded() {
        val widthPx = 1920.0
        val heightPx = 1080.0
        val up = assertNotNull(CameraPose.uprightBufferPoint(
            Point(1200.0, 700.0), orientation = ImagePropertyOrientation.up, width = widthPx, height = heightPx))
        val down = assertNotNull(CameraPose.uprightBufferPoint(
            Point(widthPx - 1200, heightPx - 700),
            orientation = ImagePropertyOrientation.down, width = widthPx, height = heightPx))
        assertEquals(up.x, down.x, 1e-9)
        assertEquals(up.y, down.y, 1e-9)
    }

    // Kotlin-only: the mirrored orientations, which the Swift doc comment says
    // are treated as their unmirrored quarter turn, and nothing pins.

    @Test
    fun mirroredLandscapesAreTreatedAsTheirQuarterTurn() {
        val p = Point(100.0, 200.0)
        assertEquals(p, CameraPose.uprightBufferPoint(p, ImagePropertyOrientation.upMirrored, 1920.0, 1080.0))
        assertEquals(Point(1820.0, 880.0),
            CameraPose.uprightBufferPoint(p, ImagePropertyOrientation.downMirrored, 1920.0, 1080.0))
        assertNull(CameraPose.uprightBufferPoint(p, ImagePropertyOrientation.leftMirrored, 1920.0, 1080.0))
        assertNull(CameraPose.uprightBufferPoint(p, ImagePropertyOrientation.rightMirrored, 1920.0, 1080.0))
    }
}
