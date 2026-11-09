// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Port of the `app/Tests/ParityTests.swift` cases for the pixel slice
 * (MotionMask, BallDetector.subpixelDiameter), against the same `parity.json`
 * blocks `motion_mask` and `diameter_probe`. Method names mirror the Swift.
 */
class PixelsParityTest {

    private val constants get() = Fixtures.constants

    /** The Swift test's own `assertClose` defaults: rel 1e-6, abs 1e-9. */
    private fun close(actual: Double, expected: Double, label: String,
                      rel: Double = 1e-6, abs: Double = 1e-9) =
        assertClose(actual, expected, label, abs = abs, rel = rel)

    /** `c.cur.flatMap { $0.map { UInt8($0) } }` — rows of 0-255 ints to unsigned bytes. */
    private fun JsonArray.lumaBytes(): ByteArray =
        flatMap { row -> row.jsonArray.map { it.jsonPrimitive.int } }
            .map { require(it in 0..255) { "luma $it out of UInt8 range" }; it.toByte() }
            .toByteArray()

    @Test
    fun motionMaskMatchesReference() {
        close(SLA.motionDiffThreshold, constants.d("MOTION_DIFF_THRESHOLD"), "motion threshold")
        close(SLA.motionDilatePx, constants.d("MOTION_DILATE_PX"), "motion dilate")

        val cases = Fixtures.block("motion_mask")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val curRows = c.arr("cur")
            val h = curRows.size
            val w = curRows[0].jsonArray.size
            val cur = MotionMask.Luma(curRows.lumaBytes(), w, h)
            val prev = if (c.has("prev")) MotionMask.Luma(c.arr("prev").lumaBytes(), w, h) else null
            val mask = MotionMask.mask(cur, prev)

            if (!c.has("expected")) {
                assertNull(mask, "no previous frame means no mask: $name")
                continue
            }
            assertNotNull(mask, "expected a mask for $name")
            val want = c.arr("expected")
                .flatMap { row -> row.jsonArray.map { it.jsonPrimitive.int != 0 } }
                .toBooleanArray()
            assertEquals(want.size, mask.size, "mask size $name")
            assertContentEquals(want, mask, "mask pixels $name")
            assertEquals(want.count { it }, mask.count { it }, "moved pixel count $name")
        }
    }

    @Test
    fun subpixelDiameterMatchesReference() {
        close(SLA.diameterProbeDirections.toDouble(), constants.d("DIAMETER_PROBE_DIRECTIONS"), "probe directions")
        close(SLA.diameterBgInner, constants.d("DIAMETER_BG_INNER"), "bg inner")
        close(SLA.diameterBgOuter, constants.d("DIAMETER_BG_OUTER"), "bg outer")
        close(SLA.diameterBgPadPx, constants.d("DIAMETER_BG_PAD_PX"), "bg pad")

        val cases = Fixtures.block("diameter_probe")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            val name = c.s("name")
            val image = pixelImageFromBGR(c.arr("bgr").map { it.jsonPrimitive.int }, c.i("width"), c.i("height"))
            val got = BallDetector.subpixelDiameter(image, c.d("cx"), c.d("cy"), c.d("r0_px"))
            val want = c.dOrNull("expected")
            if (want == null) {
                assertNull(got, "$name: too little contrast to measure")
                continue
            }
            assertNotNull(got, "$name: expected $want px, got no measurement")
            close(got, want, "$name diameter", rel = 1e-6, abs = 0.01)
        }
    }
}

/**
 * The fixtures store BGR; [PixelImage] reads the BGRA the capture path
 * delivers, so widen it here (alpha 255, channels clamped like Swift's
 * `UInt8(clamping:)`), exactly as the Swift test does. [padding] adds unused
 * bytes at the end of every row, to exercise `bytesPerRow`.
 */
fun pixelImageFromBGR(bgr: List<Int>, width: Int, height: Int, padding: Int = 0): PixelImage {
    val bytesPerRow = width * 4 + padding
    val bytes = ByteArray(bytesPerRow * height) { 255.toByte() }
    for (y in 0 until height) {
        for (x in 0 until width) {
            val i = y * width + x
            val o = y * bytesPerRow + x * 4
            for (ch in 0 until 3) bytes[o + ch] = bgr[i * 3 + ch].coerceIn(0, 255).toByte()
        }
    }
    return PixelImage(bytes, width, height, bytesPerRow)
}
