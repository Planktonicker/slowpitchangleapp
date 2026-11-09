// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Kotlin-only checks on the pixel slice: things the Swift gets for free from
 * value types or CoreVideo and the Kotlin has to earn, plus end-to-end runs of
 * the detector over the shared fixture images. No Swift counterpart; the parity
 * assertions live in [PixelsParityTest].
 */
class PixelsKotlinTest {

    private fun probeImage(name: String, padding: Int = 0): Pair<PixelImage, kotlinx.serialization.json.JsonObject> {
        val c = Fixtures.block("diameter_probe").first { it.s("name") == name }
        return pixelImageFromBGR(c.arr("bgr").map { it.jsonPrimitive.int }, c.i("width"), c.i("height"), padding) to c
    }

    // Value semantics

    /**
     * A Swift `var out = base` copies; a Kotlin `val out = base` aliases, and
     * HSVBounds has `var` fields, so a session window built from the user's
     * settings could silently rewrite them. The ported PipelineTests compare the
     * result against `base` AFTER the call, so an aliasing port would make them
     * pass vacuously — this is the test that would catch it.
     */
    @Test
    fun sessionWindowNeverEditsItsBase() {
        val base = DetectorSettings()
        val before = base.deepCopy()
        SetupBallMeasure.sessionWindow(HSVConvert.HSV(32.0, 220.0, 230.0), 12.0, base)
        assertEquals(before, base)
        val d = base.deepCopy()
        d.hsvLo.h = 99.0
        assertEquals(before.hsvLo.h, base.hsvLo.h)
    }

    // PixelImage layout

    @Test
    fun lumaIsOpenCVsFixedPointGrayOfBGRA() {
        val img = PixelImage(byteArrayOf(10, 200.toByte(), 50, 0, -1, -1, -1, -1, 0, 0, 0, 0), 3, 1)
        val luma = img.lumaPlane()
        assertEquals(133, luma[0].toInt() and 0xFF)   // (3735*10 + 19235*200 + 9798*50 + 16384) >> 15
        assertEquals(255, luma[1].toInt() and 0xFF)   // white stays white, alpha ignored
        assertEquals(0, luma[2].toInt() and 0xFF)
        // Pure red is one of the colours where the Swift's 29/150/77-of-256 sum,
        // which reads 77, and cv2's gray part company.
        assertEquals(76, PixelImage.luma(0, 0, 255))
    }

    /** Row padding (bytesPerRow > width*4), which Android buffers often carry, must change nothing. */
    @Test
    fun rowPaddingChangesNoReading() {
        val (tight, c) = probeImage("blurred_21px")
        val (padded, _) = probeImage("blurred_21px", padding = 12)
        assertContentEquals(tight.lumaPlane(), padded.lumaPlane())
        for ((x, y) in listOf(0.0 to 0.0, 30.3 to 29.7, -3.0 to 70.0, 60.9 to 0.1, 12.25 to 44.5)) {
            assertEquals(tight.sampleBilinear(x, y), padded.sampleBilinear(x, y), "sample at $x,$y")
        }
        assertEquals(BallDetector.subpixelDiameter(tight, c.d("cx"), c.d("cy"), c.d("r0_px")),
                     BallDetector.subpixelDiameter(padded, c.d("cx"), c.d("cy"), c.d("r0_px")))
        assertEquals(BallDetector.detectWithCensus(tight, 3, 0.5),
                     BallDetector.detectWithCensus(padded, 3, 0.5))
        assertEquals(BallDetector.countInWindow(tight, DetectorSettings()),
                     BallDetector.countInWindow(padded, DetectorSettings()))
    }

    @Test
    fun bilinearReplicatesTheEdge() {
        // 2x1: left pixel black, right pixel B=100 G=200 R=50.
        val img = PixelImage(byteArrayOf(0, 0, 0, 0, 100, 200.toByte(), 50, 0), 2, 1)
        assertEquals(PixelImage.BGR(50.0, 100.0, 25.0), img.sampleBilinear(0.5, 0.0))
        assertEquals(PixelImage.BGR(100.0, 200.0, 50.0), img.sampleBilinear(5.0, -4.0))
        assertEquals(PixelImage.BGR(0.0, 0.0, 0.0), img.sampleBilinear(-2.0, 3.0))
    }

    @Test
    fun badBufferIsRefused() {
        assertFailsWith<IllegalArgumentException> { PixelImage(ByteArray(15), 2, 2) }
        assertFailsWith<IllegalArgumentException> { PixelImage(ByteArray(64), 4, 2, bytesPerRow = 12) }
    }

    // HSV

    /** The Swift says `inRange` is exactly `fromBGR` plus the range tests, short-circuited. Hold it to that. */
    @Test
    fun inRangeIsFromBGRFollowedByTheRangeTests() {
        val windows = listOf(
            SLA.hsvLoDefault to SLA.hsvHiDefault,
            SLA.batHSVLoDefault to SLA.batHSVHiDefault,
            HSVBounds(0.0, 0.0, 0.0) to HSVBounds(179.0, 255.0, 255.0),
            HSVBounds(0.0, 0.0, 0.0) to HSVBounds(0.0, 0.0, 255.0),   // greys only
            HSVBounds(29.5, 120.0, 60.0) to HSVBounds(30.5, 240.0, 230.0),
        )
        val levels = (0..255 step 15) + listOf(1, 254, 255)
        for ((lo, hi) in windows) for (b in levels) for (g in levels) for (r in levels) {
            val hsv = HSVConvert.fromBGR(b.toDouble(), g.toDouble(), r.toDouble())
            val want = hsv.h >= lo.h && hsv.h <= hi.h && hsv.s >= lo.s && hsv.s <= hi.s &&
                hsv.v >= lo.v && hsv.v <= hi.v
            assertEquals(want, HSVConvert.inRange(b.toDouble(), g.toDouble(), r.toDouble(), lo, hi),
                         "bgr $b,$g,$r in $lo..$hi")
        }
    }

    @Test
    fun hueIsHalvedIntoOpenCVsRangeAndRounded() {
        // S = 200 * 255 / 220 = 231.8, which OpenCV stores as 232.
        assertEquals(HSVConvert.HSV(30.0, 232.0, 220.0), HSVConvert.fromBGR(20.0, 220.0, 220.0))
        assertEquals(HSVConvert.HSV(0.0, 255.0, 255.0), HSVConvert.fromBGR(0.0, 0.0, 255.0))     // red
        assertEquals(HSVConvert.HSV(120.0, 255.0, 255.0), HSVConvert.fromBGR(255.0, 0.0, 0.0))   // blue
        assertEquals(HSVConvert.HSV(150.0, 255.0, 255.0), HSVConvert.fromBGR(255.0, 0.0, 255.0)) // magenta wraps
        assertEquals(HSVConvert.HSV(0.0, 0.0, 0.0), HSVConvert.fromBGR(0.0, 0.0, 0.0))
    }

    /**
     * The reason the rounding matters: S 99.78 is 100 to OpenCV, inside a window
     * whose floor is 100, and the unrounded test the Swift made said no.
     */
    @Test
    fun theWindowTestsTheRoundedValues() {
        val lo = SLA.hsvLoDefault
        val hi = SLA.hsvHiDefault
        assertTrue(HSVConvert.inRange(154, 253, 253, lo, hi))    // S 99.78 -> 100
        assertTrue(HSVConvert.inRange(47, 255, 185, lo, hi))     // H 40.10 -> 40
        assertTrue(HSVConvert.inRange(100, 192, 255, lo, hi))    // H 17.81 -> 18
        assertTrue(!HSVConvert.inRange(160, 253, 253, lo, hi))   // S 93.7: outside either way
    }

    // Motion mask

    @Test
    fun evenMotionDilationIsRefused() {
        val a = MotionMask.Luma(ByteArray(9), 3, 3)
        assertFailsWith<IllegalArgumentException> { MotionMask.mask(a, a, dilatePx = 4) }
        assertEquals(9, MotionMask.mask(a, a, dilatePx = 0)?.size)
    }

    @Test
    fun mismatchedFramesGiveNoMask() {
        val a = MotionMask.Luma(ByteArray(9), 3, 3)
        assertEquals(null, MotionMask.mask(a, MotionMask.Luma(ByteArray(12), 4, 3)))
        assertEquals(null, MotionMask.mask(MotionMask.Luma(ByteArray(8), 3, 3), a))
    }

    // Morphology and labelling

    private fun mask(vararg rows: String): Triple<ByteArray, Int, Int> {
        val w = rows[0].length
        val m = ByteArray(w * rows.size)
        for ((y, row) in rows.withIndex()) for ((x, ch) in row.withIndex()) if (ch == '#') m[y * w + x] = 255.toByte()
        return Triple(m, w, rows.size)
    }

    private fun ByteArray.render(w: Int): List<String> =
        toList().chunked(w).map { row -> row.joinToString("") { if (it.toInt() == 0) "." else "#" } }

    @Test
    fun openAndCloseUseTheThreeByThreeCross() {
        val (m, w, h) = mask(".......", ".#####.", ".#####.", ".#####.", ".......", "......#")
        Morphology.open(m, w, h)
        // The cross erodes the block's corners away for good; the speck goes.
        assertEquals(listOf(".......", "..###..", ".#####.", "..###..", ".......", "......."), m.render(w))

        // The hole closes. The dilation also reaches the mask's edge, and the
        // erosion leaves what touches the edge where it is, as cv2.morphologyEx
        // does on this exact mask (the Swift, eroding from outside, gave the
        // plain block back).
        val (c, cw, ch) = mask(".......", ".#####.", ".##.##.", ".#####.", ".......")
        Morphology.close(c, cw, ch)
        assertEquals(listOf("..###..", ".#####.", "#######", ".#####.", "..###.."), c.render(cw))

        // Away from the edge, the close is the plain hole-filling it looks like.
        val (d, dw, dh) = mask(".........", ".........", "..#####..", "..##.##..", "..#####..", ".........", ".........")
        Morphology.close(d, dw, dh)
        assertEquals(listOf(".........", ".........", "..#####..", "..#####..", "..#####..", ".........", "........."),
                     d.render(dw))
    }

    /**
     * OpenCV's default erode border is the maximum value, so the outside of the
     * mask never erodes anything; the Swift treated it as background and ate
     * the frame's edge. The edge only goes where a real background pixel takes it.
     */
    @Test
    fun erodeLeavesTheMaskEdgeAloneAsOpenCVDoes() {
        val (m, w, h) = mask("###", "###", "###")
        Morphology.erode(m, w, h)
        assertEquals(listOf("###", "###", "###"), m.render(w))
        val (e, ew, eh) = mask("####.", "#####", "#####")
        Morphology.erode(e, ew, eh)
        assertEquals(listOf("###..", "####.", "#####"), e.render(ew))
        // And dilation still grows nothing in from outside.
        val (d, dw, dh) = mask("...", "...", "...")
        Morphology.dilate(d, dw, dh)
        assertEquals(listOf("...", "...", "..."), d.render(dw))
    }

    /**
     * Masking a window gives exactly the full-frame mask, cropped: the reference
     * only ever masks whole frames, and open+close reach four pixels.
     */
    @Test
    fun aWindowedMaskIsTheFullFrameMaskCropped() {
        val (img, _) = probeImage("blurred_21px")
        val lo = SLA.hsvLoDefault
        val hi = SLA.hsvHiDefault
        val full = BallDetector.maskAfterMorphology(img, ROI(0, 0, img.width, img.height), lo, hi)
        for (roi in listOf(ROI(20, 22, 33, 41), ROI(0, 25, 31, 61), ROI(29, 0, 61, 30), ROI(30, 30, 31, 31))) {
            for (close in listOf(true, false)) {
                val wide = BallDetector.maskAfterMorphology(img, ROI(0, 0, img.width, img.height), lo, hi, close = close)
                val got = BallDetector.maskAfterMorphology(img, roi, lo, hi, close = close)
                val w = roi.x1 - roi.x0
                for (y in roi.y0 until roi.y1) for (x in roi.x0 until roi.x1) {
                    assertEquals(wide[y * img.width + x], got[(y - roi.y0) * w + (x - roi.x0)], "$roi close=$close at $x,$y")
                }
            }
        }
        assertTrue(full.any { it.toInt() != 0 })
    }

    /**
     * Detection inside a window finds what full-frame detection finds for every
     * ball the window wholly contains, to the bit: the mask is the full frame's,
     * and the contour is fitted in full-frame coordinates.
     */
    @Test
    fun windowedDetectionAgreesWithFullFrameDetection() {
        val (img, _) = probeImage("notched_21px")
        val full = BallDetector.detect(img, 1, 0.0)
        assertEquals(1, full.size)
        for (roi in listOf(ROI(12, 12, 50, 49), ROI(17, 15, 44, 45), ROI(0, 0, 61, 61))) {
            assertEquals(full, BallDetector.detect(img, 1, 0.0, roi = roi), "$roi")
        }
    }

    @Test
    fun labellingIsEightConnectedAndMergesThroughUnion() {
        val (m, w, h) = mask(
            "#.#....#",
            "#.#...#.",
            "###.....",
            "........",
            ".....##.",
        )
        val (blobs, labels) = ConnectedComponents.labelDetailed(m, w, h)
        assertEquals(3, blobs.size)
        // Sorted by meanY: the diagonal pair (0.5), the U (8/7), the bottom bar (4).
        assertEquals(listOf(2, 7, 2), blobs.map { it.count })
        assertEquals(listOf(0.5, 8.0 / 7.0, 4.0), blobs.map { it.meanY })
        // The U merged into one root, and every pixel carries its blob's root.
        val u = blobs[1]
        for (i in m.indices) {
            if (m[i].toInt() == 0) assertEquals(0, labels[i]) else assertTrue(labels[i] != 0)
        }
        assertEquals(7, labels.count { it == u.root })
        assertEquals(2, labels.count { it == blobs[0].root })   // the diagonal pair is one blob
    }

    @Test
    fun blobMomentsOfARectangle() {
        val (m, w, h) = mask("..........", ".#########", ".#########", ".#########")
        val blob = ConnectedComponents.label(m, w, h).single()
        assertEquals(27, blob.count)
        assertEquals(5.0, blob.meanX, 1e-12)
        assertEquals(2.0, blob.meanY, 1e-12)
        // A w x h block of pixels has variance (w^2 - 1)/12 along each side; full axis = 4 sqrt(var).
        assertEquals(4 * sqrt(80.0 / 12.0), blob.majorAxis, 1e-9)
        assertEquals(4 * sqrt(8.0 / 12.0), blob.minorAxis, 1e-9)
        assertEquals(90.0, blob.minorAxisDeg, 1e-9)
        assertEquals(1.0, blob.extent, 1e-12)
        assertEquals(3.0, blob.boxAspect, 1e-12)
    }

    // ROI

    @Test
    fun roiTruncatesTowardZeroAndClamps() {
        assertEquals(ROI(7, 2, 14, 9), ROI.around(10.7, 5.2, 3.0))
        assertEquals(ROI(-2, -2, 4, 4), ROI.around(0.5, 0.5, 3.0))   // Int(-2.5) == -2, as in Swift
        assertEquals(ROI(0, 0, 4, 4), ROI.around(0.5, 0.5, 3.0).clamped(100, 100))
        assertEquals(ROI(99, 49, 100, 50), ROI(120, 60, 130, 70).clamped(100, 50))
    }

    // Detector end to end

    /**
     * On the clean fixture balls the detector's own seed (the fitted ellipse's
     * minor axis) must land the same diameter the reference probe gives from the
     * fixture's deliberately short seed — the probe is meant to be insensitive
     * to how good its seed is. Tolerance is the parity one.
     */
    @Test
    fun detectorMeasuresTheCleanFixtureBallsLikeTheReferenceProbe() {
        for (name in listOf("clean_11px", "clean_21px")) {
            val (img, c) = probeImage(name)
            val (obs, census) = BallDetector.detectWithCensus(img, 7, 0.25)
            assertEquals(1, obs.size, "$name: one candidate")
            assertEquals(1, census.passed, name)
            val o = obs.single()
            assertEquals(7, o.frame)
            assertEquals(0.25, o.t)
            assertEquals(c.d("cx"), o.x, 1e-9, "$name centre x")
            assertEquals(c.d("cy"), o.y, 1e-9, "$name centre y")
            assertClose(o.diameterPx, c.d("expected"), "$name diameter", abs = 0.01, rel = 1e-6)
        }
    }

    @Test
    fun theMotionGateDecidesWhatTheDetectorMaySee() {
        val (img, _) = probeImage("clean_21px")
        val n = img.width * img.height
        val ungated = BallDetector.detectWithCensus(img, 0, 0.0)
        assertEquals(ungated, BallDetector.detectWithCensus(img, 0, 0.0, motion = BooleanArray(n) { true }))
        val still = BallDetector.detectWithCensus(img, 0, 0.0, motion = BooleanArray(n))
        assertEquals(0, still.observations.size)
        assertEquals(0, still.census.blobs)
        // A mask of the wrong size is ignored, as the Swift ignores it.
        assertEquals(ungated, BallDetector.detectWithCensus(img, 0, 0.0, motion = BooleanArray(1)))
    }

    @Test
    fun sizeGatesAreCounted() {
        val (img, _) = probeImage("clean_21px")
        val tooSmall = BallDetector.detectWithCensus(img, 0, 0.0,
            DetectorSettings(minRadiusPx = 12.0, maxRadiusPx = 60.0))
        assertEquals(1, tooSmall.census.tooSmall)
        val tooBig = BallDetector.detectWithCensus(img, 0, 0.0,
            DetectorSettings(minRadiusPx = 2.0, maxRadiusPx = 4.0))
        assertEquals(1, tooBig.census.tooLarge)
        val outOfBand = BallDetector.detectWithCensus(img, 0, 0.0,
            DetectorSettings(minRadiusPx = 4.0, maxRadiusPx = 9.0))
        assertEquals(1, outOfBand.census.diameterOutOfRange)
    }

    // Setup measurement end to end

    /** A ball-coloured shape on dark turf, 4x4 supersampled so its edge blends like a real one. */
    private fun scene(size: Int, inside: (Double, Double) -> Boolean): PixelImage {
        val ground = intArrayOf(40, 90, 45)
        val ball = intArrayOf(20, 220, 220)
        val bgr = ArrayList<Int>(size * size * 3)
        for (y in 0 until size) for (x in 0 until size) {
            var hits = 0
            for (sy in 0 until 4) for (sx in 0 until 4) {
                if (inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)) hits += 1
            }
            val a = hits / 16.0
            for (ch in 0 until 3) bgr.add(((1 - a) * ground[ch] + a * ball[ch]).rounded().toInt())
        }
        return pixelImageFromBGR(bgr, size, size)
    }

    @Test
    fun setupMeasureFindsADisc() {
        val img = scene(240) { x, y -> (x - 120.5) * (x - 120.5) + (y - 120.5) * (y - 120.5) <= 20.0 * 20.0 }
        val got = SetupBallMeasure.measure(img, 120.0, 121.0, 60.0, DetectorSettings(), 60.0)
        val found = assertIs<SetupBallMeasure.Outcome.found>(got.outcome, got.report)
        assertTrue(found.measurement.subpixelRefined, got.report)
        assertEquals(40.0, found.measurement.diameterPx, 1.0, got.report)
        // Pixel-index coordinates: pixel 120 spans [120, 121), so the disc's centre is 120.0.
        assertEquals(120.0, found.measurement.x, 0.1)
        assertEquals(120.0, found.measurement.y, 0.1)
        assertNotNull(got.learned, "a found ball teaches the session window")
    }

    /** The reason the setup path exists: a compact ball-coloured square is not a ball (extent ~1.0). */
    @Test
    fun setupMeasureRefusesASquare() {
        val img = scene(240) { x, y -> x in 100.0..140.0 && y in 100.0..140.0 }
        val got = SetupBallMeasure.measure(img, 120.0, 120.0, 60.0, DetectorSettings(), 60.0)
        assertTrue(got.outcome !is SetupBallMeasure.Outcome.found, got.report)
        assertTrue("fill" in got.report, got.report)
        assertEquals(null, got.learned)
    }

    /**
     * Bounds are truncated the way `np.array(bound, np.uint8)` truncates them
     * before `cv2.inRange` sees them — so a learned lower bound of 17.6 lets
     * H = 17 in. The detect_candidates case hsv_fractional_lower_bounds pins
     * the consequence end to end; this pins the rule itself, including the
     * clamp outside 0..255 where numpy would refuse the cast.
     */
    @Test
    fun boundsTruncateLikeAUint8Cast() {
        kotlin.test.assertEquals(17, HSVConvert.uint8(17.6))
        kotlin.test.assertEquals(17, HSVConvert.uint8(17.0))
        kotlin.test.assertEquals(99, HSVConvert.uint8(99.5))
        kotlin.test.assertEquals(0, HSVConvert.uint8(-0.9))
        kotlin.test.assertEquals(255, HSVConvert.uint8(255.9))
        kotlin.test.assertEquals(0, HSVConvert.uint8(-3.0))
        kotlin.test.assertEquals(255, HSVConvert.uint8(300.0))
        kotlin.test.assertEquals(0, HSVConvert.uint8(Double.NaN))
    }
}
