// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Port of the `app/Tests/ParityTests.swift` cases whose functions live in
 * `TrackBuilder.swift`, against the same `parity.json` (blocks track_straightness,
 * select_track, build_tracks, stitch_tracks, seed_track). Method names mirror
 * the Swift `testXxx` names.
 *
 * The constant assertions at the top of the Swift seed, stitch, build and
 * contact-time tests were ported with the foundation, in
 * `FoundationParityTest.*ConstantsMatchReference`; only the case loops are here.
 */
class TrackBuilderParityTest {

    /** The Swift test's own `assertClose` defaults: rel 1e-6, abs 1e-9. */
    private fun close(actual: Double, expected: Double, label: String,
                      rel: Double = 1e-6, abs: Double = 1e-9) =
        assertClose(actual, expected, label, abs = abs, rel = rel)

    private fun JsonObject.observation() = BallObservation(
        frame = i("frame"), t = d("t"), x = d("x"), y = d("y"),
        diameterPx = d("diameter_px"), areaPx = d("area_px"),
    )

    private fun JsonElement.observations(): List<BallObservation> =
        jsonArray.map { it.jsonObject.observation() }

    private fun JsonObject.tracks(): List<List<BallObservation>> =
        arr("tracks").map { it.observations() }

    /** The Swift `[String: [Obs]]` → `[Int: [BallObservation]]` loop, skipping non-integer keys as it does. */
    private fun JsonObject.perFrame(): Map<Int, List<BallObservation>> {
        val out = HashMap<Int, List<BallObservation>>()
        for ((key, obs) in obj("per_frame")) {
            val f = key.toIntOrNull() ?: continue
            out[f] = obs.observations()
        }
        return out
    }

    /** An optional integer field; JSON null is the Swift `nil`. */
    private fun JsonObject.iOrNull(key: String): Int? = dOrNull(key)?.toInt()

    private fun obs(pts: List<Triple<Double, Double, Double>>): List<BallObservation> =
        pts.mapIndexed { i, p ->
            BallObservation(frame = i, t = p.first, x = p.second, y = p.third,
                diameterPx = 11.0, areaPx = 140.0)
        }

    @Test
    fun seededTrackingMatchesReference() {
        val cases = Fixtures.block("seed_track")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val track = TrackBuilder.trackFromSeed(
                perFrame = c.perFrame(), fps = c.d("fps"),
                t = c.d("seed_t"), x = c.d("seed_x"), y = c.d("seed_y"),
            )
            assertEquals(c.i("expected_len"), track?.size ?: 0, "seeded length $name")
            assertEquals(c.iOrNull("expected_first_frame"), track?.firstOrNull()?.frame, "seeded start $name")
            assertEquals(c.iOrNull("expected_last_frame"), track?.lastOrNull()?.frame, "seeded end $name")
        }
    }

    @Test
    fun stitchTracksMatchesReference() {
        val cases = Fixtures.block("stitch_tracks")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val chains = TrackBuilder.stitchTracks(c.tracks())
            assertEquals(c.i("expected_chain_count"), chains.size, "chain count $name")
            assertEquals(c.arr("expected_chain_lens").doubles().map { it.toInt() },
                chains.map { it.size }.sorted(), "chain lengths $name")
            // Swift `max(by:)` keeps the FIRST of equal maxima, as maxByOrNull does.
            val longest = chains.maxByOrNull { it.size }
            if (longest != null) {
                assertEquals(c.i("expected_longest_first_frame"), longest.firstOrNull()?.frame,
                    "longest start $name")
                assertEquals(c.i("expected_longest_last_frame"), longest.lastOrNull()?.frame,
                    "longest end $name")
            }
        }
    }

    @Test
    fun trackBuildingMatchesReference() {
        val cases = Fixtures.block("build_tracks")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val built = TrackBuilder.buildTracks(perFrame = c.perFrame(), fps = c.d("fps"))
            assertEquals(c.i("expected_track_count"), built.size, "track count $name")
            assertEquals(c.i("expected_longest"), built.maxOfOrNull { it.size } ?: 0,
                "longest track $name")

            val picked = TrackBuilder.selectOutboundTrack(built, direction = TrackBuilder.Direction.right)
            assertEquals(c.i("expected_selected_len"), picked?.size ?: 0, "selected length $name")
            val first = c.dOrNull("expected_selected_first_x")
            val last = c.dOrNull("expected_selected_last_x")
            if (first != null && last != null) {
                close(picked?.firstOrNull()?.x ?: Double.NaN, first, "selected start $name")
                close(picked?.lastOrNull()?.x ?: Double.NaN, last, "selected end $name")
            }
        }
    }

    @Test
    fun trackSelectionMatchesReference() {
        val cases = Fixtures.block("select_track")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val tracks = c.tracks()
            val direction = TrackBuilder.Direction.fromRaw(c.s("direction")) ?: TrackBuilder.Direction.auto
            val picked = TrackBuilder.selectOutboundTrack(tracks, direction = direction,
                contactTime = c.dOrNull("contact_time"))
            val expected = c.iOrNull("expected_index")
            if (expected != null) {
                assertEquals(tracks[expected], picked, "selection $name")
            } else {
                assertNull(picked, "selection $name should pick nothing")
            }
        }
    }

    @Test
    fun selectionPrefersTheFlightAtContact() {
        for (name in listOf("short_hit_at_contact_beats_late_impostor",
                            "full_length_at_contact_beats_short",
                            "nothing_near_contact_falls_back",
                            "stalled_then_fast_loses_to_steady_flight")) {
            val c = Fixtures.block("select_track").firstOrNull { it.s("name") == name }
                ?: fail("fixture missing: $name")
            val tracks = c.tracks()
            val direction = TrackBuilder.Direction.fromRaw(c.s("direction")) ?: TrackBuilder.Direction.auto
            val picked = TrackBuilder.selectOutboundTrack(tracks, direction = direction,
                contactTime = c.dOrNull("contact_time"))
            val expected = c.iOrNull("expected_index")
            if (expected == null) {
                assertNull(picked, "$name: expected no track")
                continue
            }
            assertEquals(tracks[expected], picked, name)
        }
    }

    @Test
    fun medianStepSpeedRejectsAStalledTrack() {
        // Straight from live_39: a corner blob glued to something fast.
        val stalled = obs(listOf(
            Triple(1.641667, 87.44, 71.47), Triple(1.655, 87.43, 71.74),
            Triple(1.666667, 88.95, 74.96), Triple(1.68, 87.66, 74.36),
            Triple(1.691667, 86.16, 73.21), Triple(1.705, 146.95, 34.87),
            Triple(1.721667, 330.92, 9.62), Triple(1.738333, 562.72, 17.87),
        ))
        // The ball in the same clip, which lost.
        val ball = obs(listOf(
            Triple(1.4883, 740.2, 509.0), Triple(1.5050, 797.6, 540.7),
            Triple(1.5083, 818.1, 552.9), Triple(1.5167, 855.9, 563.1),
            Triple(1.5250, 895.0, 577.9), Triple(1.5333, 928.8, 593.6),
            Triple(1.5383, 947.3, 600.2), Triple(1.5417, 962.6, 606.2),
            Triple(1.5500, 998.6, 621.6), Triple(1.5550, 1013.8, 631.0),
            Triple(1.5583, 1027.2, 638.2),
        ))

        fun endpoints(t: List<BallObservation>): Double {
            val dt = t.last().t - t.first().t
            val dx = t.last().x - t.first().x
            val dy = t.last().y - t.first().y
            return sqrt(dx * dx + dy * dy) / dt
        }
        assertTrue(endpoints(stalled) > endpoints(ball),
            "the old score preferred the stalled track — that is the bug")
        assertTrue(TrackBuilder.medianStepSpeed(stalled)!! < TrackBuilder.medianStepSpeed(ball)!! / 10,
            "the median step must separate them by an order of magnitude")
        // Straightness cannot save it: a stationary head walks no distance.
        assertTrue(TrackBuilder.straightness(stalled) > 0.9,
            "straightness does not catch this, which is why the score had to")

        val picked = TrackBuilder.selectOutboundTrack(listOf(stalled, ball),
            direction = TrackBuilder.Direction.right, contactTime = 1.498717)
        assertEquals(ball, picked)
    }

    /** The selection half; `SELECT_CONTACT_TOL_S` is pinned in `FoundationParityTest`. */
    @Test
    fun selectionUsesContactTime() {
        val c = Fixtures.block("select_track").firstOrNull { it.s("name") == "mishit_slower_than_pitch" }
            ?: fail("fixture missing")
        val tracks = c.tracks()
        val contactTime = c.dOrNull("contact_time")
        assertNotNull(contactTime, "this case exists to exercise contact time")

        // Without it, the pitch wins on speed — the bug, stated as a test so
        // the fixture cannot quietly stop exercising anything.
        val blind = TrackBuilder.selectOutboundTrack(tracks, direction = TrackBuilder.Direction.auto)
        assertEquals(tracks[0], blind, "without contact time the pitch is the fastest track")

        val informed = TrackBuilder.selectOutboundTrack(tracks, direction = TrackBuilder.Direction.auto,
            contactTime = contactTime)
        assertEquals(tracks[c.iOrNull("expected_index")!!], informed, "contact time picks the hit")
    }

    @Test
    fun trackStraightnessMatchesReference() {
        val cases = Fixtures.block("track_straightness")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val track = c.arr("points").mapIndexed { i, p ->
                val pt = p.jsonObject
                BallObservation(frame = i, t = i.toDouble() / 240.0,
                    x = pt.d("x"), y = pt.d("y"), diameterPx = 10.0, areaPx = 80.0)
            }
            close(TrackBuilder.straightness(track), c.d("expected"), "straightness ${c.s("name")}")
        }
    }
}
