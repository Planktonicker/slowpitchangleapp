// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `ClipAnalyzer.frameTiming(fromIntervals:)` against the `frame_timing` block,
 * which `spike/gen_parity_fixtures.py` takes from `replay_corpus.derive_fps` —
 * the Python copy of this estimator. No Swift counterpart: the frozen iOS app
 * pinned this only to its own hand-written tests (FrameTimingTests.kt).
 *
 * The estimator does the same arithmetic in the same order as the Python, so
 * the answers agree to the last bit or two; the tolerances below are that
 * tight on purpose, because every exit velocity is scaled by this rate.
 */
class FrameTimingParityTest {

    @Test
    fun frameTimingMatchesReference() {
        val cases = Fixtures.block("frame_timing")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val t = ClipAnalyzer.frameTiming(fromIntervals = c.getValue("intervals").doubles())
            if (!c.has("expected")) {
                assertNull(t, "$name: the reference refuses to measure this")
                continue
            }
            val e = c.obj("expected")
            assertNotNull(t, "$name: the reference measured this")
            assertClose(t.fps, e.d("fps"), "$name fps", abs = 0.0, rel = 1e-12)
            assertEquals(e.i("intervals"), t.intervals, "$name intervals")
            assertClose(t.irregularFraction, e.d("irregular_fraction"), "$name irregular", abs = 1e-12, rel = 0.0)
        }
    }

    /**
     * The block has to keep covering the cases the port is most likely to get
     * wrong. A regenerated fixture file that quietly lost one would leave this
     * test green on whatever remained.
     */
    @Test
    fun fixturesCoverTheKnownTraps() {
        val names = Fixtures.block("frame_timing").map { it.s("name") }.toSet()
        for (required in listOf(
            "clean_240", "timescale_600_alternation", "dropped_frame_240",
            "variable_rate_1_6_1_0", "fps_30", "coarse_container_stts",
            "knife_edge_inside_slack", "knife_edge_outside_slack", "three_intervals",
        )) {
            assertTrue(required in names, "frame_timing fixtures lost '$required'")
        }
    }
}
