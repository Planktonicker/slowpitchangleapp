// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Base64
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `detect_ball_candidates`, end to end and stage by stage, against the
 * `detect_candidates`, `contour_geometry` and `cv_color` blocks of parity.json —
 * the Python's detector, not the Swift's.
 * No Swift counterpart: the frozen app's detector was never pinned to the
 * reference end to end, which is how it came to differ from it at every stage
 * (see [BallDetector] for the list).
 *
 * Tolerances, and why each is what it is:
 *  - masks, contour points, contour areas, candidate counts and order: exact.
 *    They are integers, or sums of them.
 *  - fitted centres and axes: two float32 ulps. They are `float`s in OpenCV and
 *    `Float`s here, computed by the same arithmetic; on the machine that wrote
 *    the fixtures they agree to the bit. The two ulps are for a reference
 *    regenerated against an OpenCV that links LAPACK for its SVD, whose double
 *    answer can differ in the last place and, very rarely, round the other way.
 *  - diameters: 1e-5 px. Bit-exact here too; the allowance is for a reference
 *    regenerated against another BLAS or numpy, whose float32 sums and dot
 *    products can move an edge crossing by a few millionths of a pixel. It is
 *    a thousand times tighter than the probe's own 0.01 px pin.
 */
class DetectorParityTest {

    private fun b64(s: String): ByteArray = Base64.getDecoder().decode(s)

    private class Case(val c: JsonObject) {
        val name = c.s("name")
        val width = c.i("width")
        val height = c.i("height")
        val image: PixelImage = pixelImageFromBGR(
            Base64.getDecoder().decode(c.s("bgr_b64")).map { it.toInt() and 0xFF }, width, height)
        val motion: BooleanArray? = c["motion_b64"].let {
            if (it == null || it is JsonNull) null
            else Base64.getDecoder().decode(it.jsonPrimitive.content).map { b -> b.toInt() != 0 }.toBooleanArray()
        }
        val settings: DetectorSettings = run {
            val lo = c.arr("hsv_lo").doubles()
            val hi = c.arr("hsv_hi").doubles()
            DetectorSettings(HSVBounds(lo[0], lo[1], lo[2]), HSVBounds(hi[0], hi[1], hi[2]),
                             c.d("min_radius_px"), c.d("max_radius_px"))
        }
        val mask: ByteArray = Base64.getDecoder().decode(c.s("mask_b64"))
    }

    private val cases: List<Case> by lazy { Fixtures.block("detect_candidates").map { Case(it) } }

    private fun assertFloatResult(actual: Double, expected: Double, label: String) {
        val tol = 2.0 * Math.ulp(expected.toFloat()).toDouble()
        assertTrue(abs(actual - expected) <= tol,
            "$label: got $actual, expected $expected (|diff| ${abs(actual - expected)} > 2 float ulps $tol)")
    }

    // ------------------------------------------------------------------ colour

    /**
     * Every one of the 2^24 colours, as one digest each for HSV and gray:
     * `sum((i + 1) * code) mod 2^64` over `i = b<<16 | g<<8 | r` — the generator
     * says how. A Long wraps at 2^64 exactly as numpy's uint64 does.
     */
    @Test
    fun colourConversionsMatchOpenCVOnEveryColour() {
        val block = Fixtures.block("cv_color").single()
        var hsv = 0L
        var gray = 0L
        val lo = SLA.hsvLoDefault
        val hi = SLA.hsvHiDefault
        var disagreements = 0
        for (i in 0 until (1 shl 24)) {
            val b = i shr 16
            val g = (i shr 8) and 0xFF
            val r = i and 0xFF
            val p = HSVConvert.packedFromBGR(b, g, r)
            hsv += (i + 1).toLong() * p.toLong()
            gray += (i + 1).toLong() * PixelImage.luma(b, g, r).toLong()
            // inRange repeats packedFromBGR's arithmetic to short-circuit; hold it to that.
            val h = p shr 16
            val s = (p shr 8) and 0xFF
            val v = p and 0xFF
            val want = h >= lo.h && h <= hi.h && s >= lo.s && s <= hi.s && v >= lo.v && v <= hi.v
            if (want != HSVConvert.inRange(b, g, r, lo, hi)) disagreements += 1
        }
        assertEquals(java.lang.Long.parseUnsignedLong(block.s("hsv_digest")), hsv, "HSV digest over all colours")
        assertEquals(java.lang.Long.parseUnsignedLong(block.s("gray_digest")), gray, "gray digest over all colours")
        assertEquals(0, disagreements, "inRange disagrees with packedFromBGR")
    }

    @Test
    fun colourSamplesMatchOpenCV() {
        val samples = Fixtures.block("cv_color").single().arr("samples").map { it.jsonObject }
        assertTrue(samples.isNotEmpty())
        val bgr = ArrayList<Int>()
        for (s in samples) {
            val b = s.i("b"); val g = s.i("g"); val r = s.i("r")
            val got = HSVConvert.fromBGR(b.toDouble(), g.toDouble(), r.toDouble())
            assertEquals(HSVConvert.HSV(s.d("h"), s.d("s"), s.d("v")), got, "hsv of $b,$g,$r")
            assertEquals(s.i("gray"), PixelImage.luma(b, g, r), "gray of $b,$g,$r")
            bgr.addAll(listOf(b, g, r))
        }
        // The plane the motion gate reads is the same conversion, pixel for pixel.
        val plane = pixelImageFromBGR(bgr, samples.size, 1, padding = 8).lumaPlane()
        assertEquals(samples.map { it.i("gray") }, plane.map { it.toInt() and 0xFF })
    }

    // ------------------------------------------------------------------ stages

    /** The mask `detect_ball_candidates` finds contours on: window, open, close, motion gate. */
    @Test
    fun maskMatchesReference() {
        assertTrue(cases.isNotEmpty())
        for (k in cases) {
            val got = BallDetector.maskAfterMorphology(
                k.image, ROI(0, 0, k.width, k.height), k.settings.hsvLo, k.settings.hsvHi, k.motion)
            assertEquals(k.mask.size, got.size, "${k.name}: mask size")
            val diff = k.mask.indices.count { (k.mask[it].toInt() != 0) != (got[it].toInt() != 0) }
            assertEquals(0, diff, "${k.name}: mask pixels differing from the reference")
        }
    }

    /** `findContours` on the reference's own mask, then `contourArea` and the fitted shapes. */
    @Test
    fun contoursMatchReference() {
        for (k in cases) checkContours(k.name, k.mask, k.width, k.height, k.c.arr("contours").map { it.jsonObject })
    }

    /**
     * The same on masks built to be awkward — specks, one-pixel lines and rings,
     * diagonal-only links, things inside holes, blobs on every edge — where
     * findContours' order and its RETR_EXTERNAL nesting come out of how its
     * border marks interact, and a port that only resembles it would differ.
     */
    @Test
    fun contourGeometryMatchesReference() {
        val masks = Fixtures.block("contour_geometry")
        assertTrue(masks.size >= 20)
        var contours = 0
        for (m in masks) {
            val want = m.arr("contours").map { it.jsonObject }
            checkContours(m.s("name"), b64(m.s("mask_b64")), m.i("width"), m.i("height"), want)
            contours += want.size
        }
        assertTrue(contours > 50)
        // Offsets are added to every point, as findContours' offset argument does.
        val m = masks.first { it.s("name") == "ball_sized_blobs" }
        val plain = OpenCV.findContours(b64(m.s("mask_b64")), m.i("width"), m.i("height"))
        val shifted = OpenCV.findContours(b64(m.s("mask_b64")), m.i("width"), m.i("height"), 100, -7)
        assertEquals(plain.map { c -> c.x.map { it + 100 } }, shifted.map { it.x.toList() })
        assertEquals(plain.map { c -> c.y.map { it - 7 } }, shifted.map { it.y.toList() })
    }

    private fun checkContours(name: String, mask: ByteArray, width: Int, height: Int, want: List<JsonObject>) {
        val got = OpenCV.findContours(mask, width, height)
        assertEquals(want.size, got.size, "$name: contour count")
        for ((i, pair) in want.zip(got).withIndex()) {
            val (w, g) = pair
            val label = "$name contour $i"
            val pts = w.arr("points").map { p -> p.jsonArray.map { it.jsonPrimitive.int } }
            assertEquals(pts.map { it[0] }, g.x.toList(), "$label x")
            assertEquals(pts.map { it[1] }, g.y.toList(), "$label y")
            assertEquals(w.d("area"), OpenCV.contourArea(g), "$label area")
            if (w.has("ellipse")) {
                val e = w.obj("ellipse")
                val f = OpenCV.fitEllipse(g)
                assertFloatResult(f.cx.toDouble(), e.d("cx"), "$label ellipse cx")
                assertFloatResult(f.cy.toDouble(), e.d("cy"), "$label ellipse cy")
                assertFloatResult(f.width.toDouble(), e.d("width"), "$label ellipse width")
                assertFloatResult(f.height.toDouble(), e.d("height"), "$label ellipse height")
            }
            if (w.has("circle")) {
                val e = w.obj("circle")
                val f = OpenCV.minEnclosingCircle(g)
                assertFloatResult(f.cx.toDouble(), e.d("cx"), "$label circle cx")
                assertFloatResult(f.cy.toDouble(), e.d("cy"), "$label circle cy")
                assertFloatResult(f.radius.toDouble(), e.d("radius"), "$label circle radius")
            }
        }
    }

    // ------------------------------------------------------------------ end to end

    @Test
    fun candidatesMatchReference() {
        var total = 0
        for (k in cases) {
            val want = k.c.arr("expected").map { it.jsonObject }
            val got = BallDetector.detectWithCensus(k.image, k.c.i("frame"), k.c.d("t"), k.settings,
                                                    motion = k.motion)
            val obs = got.observations
            assertEquals(want.size, obs.size, "${k.name}: candidate count (census ${got.census})")
            assertEquals(obs.size, got.census.passed, "${k.name}: census passed")
            assertEquals(k.c.arr("contours").size, got.census.blobs, "${k.name}: census blobs are contours")
            for ((i, pair) in want.zip(obs).withIndex()) {
                val (w, o) = pair
                val label = "${k.name} candidate $i"
                assertEquals(w.i("frame"), o.frame, "$label frame")
                assertEquals(w.d("t"), o.t, "$label t")
                assertFloatResult(o.x, w.d("x"), "$label x")
                assertFloatResult(o.y, w.d("y"), "$label y")
                assertClose(o.diameterPx, w.d("diameter_px"), "$label diameter", abs = 1e-5, rel = 0.0)
                assertEquals(w.d("area_px"), o.areaPx, "$label area")
                total += 1
            }
        }
        assertTrue(total > 0)
    }

    /**
     * The block has to keep exercising every path, or the cases above pass on a
     * port that never runs half of them: each gate rejecting something, each of
     * the three shape fits (circle under five points, the direct fit at five,
     * the general fit above), a gated and an ungated frame.
     */
    @Test
    fun fixturesCoverEveryDetectorPath() {
        val census = BallDetector.GateCensus()
        val sizes = HashSet<Int>()
        for (k in cases) {
            val r = BallDetector.detectWithCensus(k.image, 0, 0.0, k.settings, motion = k.motion).census
            census.blobs += r.blobs
            census.tooSmall += r.tooSmall
            census.tooLarge += r.tooLarge
            census.tooElongated += r.tooElongated
            census.diameterOutOfRange += r.diameterOutOfRange
            census.passed += r.passed
            for (c in k.c.arr("contours")) {
                val o = c.jsonObject
                if (o.has("ellipse") || o.has("circle")) sizes.add(o.arr("points").size.coerceAtMost(6))
            }
        }
        assertTrue(census.tooSmall > 0, "a case below the area gate: $census")
        assertTrue(census.tooLarge > 0, "a case above the area gate: $census")
        assertTrue(census.tooElongated > 0, "a case past the elongation gate: $census")
        assertTrue(census.diameterOutOfRange > 0, "a case outside the diameter band: $census")
        assertTrue(census.passed > 0, "$census")
        assertEquals(setOf(4, 5, 6), sizes, "fits under five, at five and above five points")
        assertTrue(cases.any { it.motion != null } && cases.any { it.motion == null }, "gated and ungated cases")
    }
}
