// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Port of the `app/Tests/PipelineTests.swift` cases on the pixel slice — the
 * "Learning the ball from one tap" section, `SetupBallMeasure.sessionWindow`.
 * Method names mirror the Swift; tolerances are the Swift's.
 */
class PixelsPipelineTest {

    @Test
    fun theLearnedWindowIsNeverLooserThanTheDefault() {
        val base = DetectorSettings()
        base.hsvLo = HSVBounds(h = 18.0, s = 100.0, v = 120.0)
        base.hsvHi = HSVBounds(h = 40.0, s = 255.0, v = 255.0)
        val w = SetupBallMeasure.sessionWindow(tap = HSVConvert.HSV(h = 30.0, s = 120.0, v = 140.0),
                                               measuredDiameterPx = 12.0, base = base)
        assertTrue(w.hsvLo.s >= base.hsvLo.s)
        assertTrue(w.hsvLo.v >= base.hsvLo.v)
    }

    @Test
    fun aFluorescentBallRaisesTheSaturationFloor() {
        val base = DetectorSettings()
        base.hsvLo = HSVBounds(h = 18.0, s = 100.0, v = 120.0)
        base.hsvHi = HSVBounds(h = 40.0, s = 255.0, v = 255.0)
        val w = SetupBallMeasure.sessionWindow(tap = HSVConvert.HSV(h = 32.0, s = 220.0, v = 230.0),
                                               measuredDiameterPx = 12.0, base = base)
        assertEquals(121.0, w.hsvLo.s, 1e-9)   // 220 * 0.55
        assertEquals(14.0, w.hsvLo.h, 1e-9)    // re-centred on the ball
        assertEquals(50.0, w.hsvHi.h, 1e-9)
    }

    @Test
    fun theSizeBandFollowsTheMeasuredBall() {
        val base = DetectorSettings()
        base.minRadiusPx = 4.0
        base.maxRadiusPx = 60.0
        val w = SetupBallMeasure.sessionWindow(tap = HSVConvert.HSV(h = 30.0, s = 200.0, v = 200.0),
                                               measuredDiameterPx = 12.0, base = base)
        assertEquals(15.0, w.maxRadiusPx, 1e-9)   // 6 * 2.5
        assertTrue(w.minRadiusPx >= base.minRadiusPx)
        assertTrue(w.minRadiusPx < w.maxRadiusPx)
    }

    @Test
    fun anImpossibleSizeBandFallsBackRatherThanRejectingEverything() {
        val base = DetectorSettings()
        base.minRadiusPx = 20.0
        base.maxRadiusPx = 60.0
        val w = SetupBallMeasure.sessionWindow(tap = HSVConvert.HSV(h = 30.0, s = 200.0, v = 200.0),
                                               measuredDiameterPx = 8.0, base = base)
        assertEquals(20.0, w.minRadiusPx, 1e-9)
        assertEquals(60.0, w.maxRadiusPx, 1e-9)
        assertTrue(w.hsvLo.s > 0, "the colour lesson is still kept")
    }
}
