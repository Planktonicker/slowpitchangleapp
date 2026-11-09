// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Checks with no Swift counterpart: the places where the Kotlin had to do work
 * the Swift got for free (value semantics, C rounding and printf, the
 * CoreGraphics stand-ins). Each expected value is what Swift / C produce.
 */
class FoundationKotlinTest {

    @Test
    fun hsvDefaultsAreNotSharedMutableState() {
        val tuned = SLA.hsvLoDefault
        tuned.h = 5.0
        assertEquals(18.0, SLA.hsvLoDefault.h)
    }

    @Test
    fun rawValuesRoundTrip() {
        for (f in SwingFlag.entries) assertEquals(f, SwingFlag.fromRaw(f.raw))
        for (f in CaptureFlag.entries) assertEquals(f, CaptureFlag.fromRaw(f.raw))
        for (q in ContactQuality.entries) assertEquals(q, ContactQuality.fromRaw(q.raw))
        for (q in SmashQuality.entries) assertEquals(q, SmashQuality.fromRaw(q.raw))
        for (v in TriggerCalibrationVerdict.entries) assertEquals(v, TriggerCalibrationVerdict.fromRaw(v.raw))
        for (u in SpeedUnit.entries) assertEquals(u, SpeedUnit.fromRaw(u.raw))
        assertEquals(null, SwingFlag.fromRaw("TILT_CORRECTED"), "a capture flag is not a swing flag")
    }

    @Test
    fun roundedIsHalfAwayFromZero() {
        assertEquals(1.0, 0.5.rounded())
        assertEquals(-1.0, (-0.5).rounded())
        assertEquals(3.0, 2.5.rounded())
        assertEquals(-3.0, (-2.5).rounded())
        assertEquals(2.0, 2.4999.rounded())
        assertEquals(0.0, 0.49999999999999994.rounded())
        assertEquals(4503599627370497.0, 4503599627370497.0.rounded())
        assertTrue(Double.NaN.rounded().isNaN())
        assertEquals(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY.rounded())
    }

    @Test
    fun swiftMaxMinFollowTheComparison() {
        assertEquals(0.0, swiftMax(0.0, Double.NaN))
        assertTrue(swiftMax(Double.NaN, 0.0).isNaN())
        assertEquals(0.0, swiftMin(0.0, Double.NaN))
        assertEquals(3.0, swiftMax(2.0, 3.0))
        assertEquals(2.0, swiftMin(2.0, 3.0))
    }

    @Test
    fun formatFixedMatchesPrintf() {
        assertEquals("0.1", formatFixed(0.15, 1))      // 0.1499999... in binary
        assertEquals("2", formatFixed(2.5, 0))         // exact tie, half to even
        assertEquals("4", formatFixed(3.5, 0))
        assertEquals("1.00", formatFixed(1.005, 2))
        assertEquals("-0.0", formatFixed(-0.04, 1))
        assertEquals("+12", formatFixed(12.4, 0, plusSign = true))
        assertEquals("-0", formatFixed(-0.4, 0, plusSign = true))
        assertEquals("1234567.890", formatFixed(1234567.89, 3))
        assertEquals("+17 mm", Fmt.signedMm(0.0166666))
        assertEquals("5.8 m", Fmt.m(5.8))
        assertEquals("4.167 mm/px", Fmt.mmPerPx(0.004166666666666667))
        assertEquals("112.7", SpeedUnit.kmh.format(mph = 70.0))
    }

    @Test
    fun affineTransformInvertsAndRotates() {
        val quarter = AffineTransform(a = 0.0, b = 1.0, c = -1.0, d = 0.0, tx = 1080.0, ty = 0.0)
        val p = Point(100.0, 250.0)
        assertEquals(p, p.applying(quarter).applying(quarter.inverted()))
        assertEquals(Size(-250.0, 100.0), Size(100.0, 250.0).applying(quarter))
        assertTrue(AffineTransform.identity.isIdentity)
        assertTrue(AffineTransform(1.0, -0.0, 0.0, 1.0, 0.0, -0.0).isIdentity)
        val singular = AffineTransform(1.0, 2.0, 2.0, 4.0, 3.0, 3.0)
        assertEquals(singular, singular.inverted())
        val r = AffineTransform(rotationAngle = PI / 2)
        assertEquals(1.0, r.b)
        assertEquals(-1.0, r.c)
    }

    @Test
    fun rectIsStandardizedLikeCoreGraphics() {
        val r = Rect(x = 10.0, y = 20.0, width = -4.0, height = 6.0)
        assertEquals(6.0, r.minX)
        assertEquals(10.0, r.maxX)
        assertEquals(4.0, r.width)
        assertEquals(8.0, r.midX)
        assertTrue(r.contains(Point(6.0, 20.0)))
        assertFalse(r.contains(Point(10.0, 20.0)))
        assertTrue(Rect.zero.isEmpty)
    }
}
