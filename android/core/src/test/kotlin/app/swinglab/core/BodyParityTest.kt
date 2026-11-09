// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Port of `ParityTests.testBodyGeometryMatchesReference` against the fixture
 * blocks body_angles, body_tilts, body_distances, body_strides and
 * body_drift_gate. `testBodyConstantsMatchReference` is already in
 * FoundationParityTest.
 */
class BodyParityTest {

    /** The Swift test's `assertClose(_, _, rel:, abs: 1e-9, _)`. */
    private fun close(actual: Double, expected: Double, label: String, rel: Double = 1e-6) {
        if (actual == expected) return
        assertTrue(!(actual.isNaN() && !expected.isNaN()), "$label: got NaN, expected $expected")
        assertClose(actual, expected, label, abs = 1e-9, rel = rel)
    }

    @Test
    fun bodyGeometryMatchesReference() {
        val angles = Fixtures.block("body_angles")
        assertTrue(angles.isNotEmpty())
        for (c in angles) {
            val a = BodyAnalyzer.sagittalAngleDeg(
                a = Point(c.d("ax"), c.d("ay")),
                b = Point(c.d("bx"), c.d("by")),
                c = Point(c.d("cx"), c.d("cy")),
            )
            val expected = c.dOrNull("expected")
            if (expected == null) {
                assertTrue(a.isNaN(), "${c.s("name")}: expected NaN for a degenerate joint")
                continue
            }
            close(a, expected, "${c.s("name")} angle", rel = 1e-9)
        }

        val tilts = Fixtures.block("body_tilts")
        assertTrue(tilts.isNotEmpty())
        for (c in tilts) {
            val t = BodyAnalyzer.spineTiltDeg(
                hip = Point(c.d("hip_x"), c.d("hip_y")),
                shoulder = Point(c.d("shoulder_x"), c.d("shoulder_y")),
            )
            val expected = c.dOrNull("expected")
            if (expected == null) {
                assertTrue(t.isNaN(), "${c.s("name")}: expected NaN")
                continue
            }
            close(t, expected, "${c.s("name")} tilt", rel = 1e-9)
        }

        val distances = Fixtures.block("body_distances")
        assertTrue(distances.isNotEmpty())
        for (c in distances) {
            val d = BodyAnalyzer.planarDistanceM(
                Point(c.d("x0"), c.d("y0")),
                Point(c.d("x1"), c.d("y1")),
                scaleMPerPx = c.d("scale_m_per_px"),
            )
            close(d, c.d("expected"), "${c.s("name")} distance", rel = 1e-9)
        }

        val strides = Fixtures.block("body_strides")
        assertTrue(strides.isNotEmpty())
        for (c in strides) {
            val d = BodyAnalyzer.strideLengthM(
                loadX = c.d("load_x"), contactX = c.d("contact_x"),
                scaleMPerPx = c.d("scale_m_per_px"),
            )
            close(d, c.d("expected"), "${c.s("name")} stride", rel = 1e-9)
        }

        val gate = Fixtures.block("body_drift_gate")
        assertTrue(gate.isNotEmpty())
        for (c in gate) {
            val drift = c.dOrNull("drift_m")
            assertEquals(c.b("expected"), BodyAnalyzer.headDriftPlausible(drift), "drift gate at $drift")
        }
    }
}
