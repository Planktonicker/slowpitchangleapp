// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Port of the `app/Tests/ParityTests.swift` "Full analysis" cases
 * (`analyze_track`), against the same `parity.json`. Method names mirror the
 * Swift `testXxx` names. `testFixturesCoverEveryFlag` is already ported in
 * [FoundationParityTest].
 */
class AnalysisParityTest {

    /** The Swift test's own `assertClose`: exact equality passes, else rel 1e-6 / abs 1e-9. */
    private fun close(actual: Double, expected: Double, label: String,
                      rel: Double = 1e-6, abs: Double = 1e-9) {
        if (actual == expected) return
        assertClose(actual, expected, label, abs = abs, rel = rel)
    }

    private fun JsonObject.observation() = BallObservation(
        frame = i("frame"), t = d("t"), x = d("x"), y = d("y"),
        diameterPx = d("diameter_px"), areaPx = d("area_px"),
    )

    @Test
    fun analyzeTrackMatchesReference() {
        val cases = Fixtures.block("analyze_track")
        assertTrue(cases.isNotEmpty(), "no analyze_track fixtures")
        for (c in cases) {
            val name = c.s("name")
            val track = c.arr("track").map { it.jsonObject.observation() }
            val m = SwingAnalyzer.analyze(
                track = track,
                contactTime = c.dOrNull("contact_time"),
                rollDeg = c.d("roll_deg"),
            )
            val e = c.obj("expected")

            close(m.launchAngleDeg, e.d("launch_angle_deg"), "$name launch angle")
            close(m.exitVeloMph, e.d("exit_velo_mph"), "$name exit velo mph")
            close(m.exitVeloMps, e.d("exit_velo_mps"), "$name exit velo m/s")
            close(m.scaleBallMPerPx, e.d("scale_ball_m_per_px"), "$name ball scale")
            close(m.diameterDrift, e.d("diameter_drift"), "$name diameter drift")
            close(m.trackDurationS, e.d("track_duration_s"), "$name duration")
            close(m.fitRmsPx, e.d("fit_rms_px"), "$name fit rms")
            close(m.t0, e.d("t0"), "$name t0")
            close(m.vxPxS, e.d("vx_px_s"), "$name vx")
            close(m.vyPxS, e.d("vy_px_s"), "$name vy")
            close(m.x0Px, e.d("x0_px"), "$name x0")
            close(m.y0Px, e.d("y0_px"), "$name y0")
            assertEquals(e.i("n_frames"), m.nFrames, "$name frame count")

            val gravity = m.scaleGravityMPerPx
            val gravityExpected = e.dOrNull("scale_gravity_m_per_px")
            when {
                gravity == null && gravityExpected == null -> {}
                gravity != null && gravityExpected != null -> close(gravity, gravityExpected, "$name gravity scale")
                else -> fail("$name: gravity scale presence differs")
            }

            val disagreement = m.scaleDisagreement
            val disagreementExpected = e.dOrNull("scale_disagreement")
            when {
                disagreement == null && disagreementExpected == null -> {}
                disagreement != null && disagreementExpected != null -> close(disagreement, disagreementExpected, "$name disagreement")
                else -> fail("$name: disagreement presence differs")
            }

            // Order matters: the flags are appended in a fixed sequence and
            // the CSV export writes them in that order.
            assertEquals(e.arr("flags").map { it.jsonPrimitive.content }, m.flags.map { it.raw }, "$name flags")
        }
    }
}
