// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The OpenCV routines `sla_common.detect_ball_candidates` calls on a mask,
 * ported from OpenCV 5.0's own sources (imgproc `contours_new.cpp`, geometry
 * `shapedescr.cpp`). No Swift counterpart: the Swift detector approximated them
 * — a pixel count for `contourArea`, image moments for `fitEllipse`, all
 * connected components for `RETR_EXTERNAL` — and each approximation moved the
 * point the diameter probe stands on, which moved the scale behind every speed.
 *
 * Ported literally, quirks included, and pinned by the `detect_candidates`
 * fixtures (every contour's points, area and fitted shape). The float32
 * arithmetic is OpenCV's: those values are `float`s in the reference, so they
 * are `Float`s here and the outputs agree to the bit, not merely to a tolerance.
 *
 * Only what the detector uses is ported: external contours with
 * `CHAIN_APPROX_SIMPLE`, the shoelace area, the ellipse's centre and axes (not
 * its angle) and the enclosing circle of up to ten points.
 */
object OpenCV {

    /** One contour, its points in OpenCV's order; x/y in image pixels. */
    class Contour(val x: IntArray, val y: IntArray) {
        val size: Int get() = x.size
    }

    /** `cv::RotatedRect` without the angle, which the detector never reads. */
    data class RotatedRect(val cx: Float, val cy: Float, val width: Float, val height: Float)

    /** `minEnclosingCircle`'s two outputs. */
    data class Circle(val cx: Float, val cy: Float, val radius: Float)

    // ------------------------------------------------------------------ contours

    private val DX = intArrayOf(1, 1, 0, -1, -1, -1, 0, 1)
    private val DY = intArrayOf(0, -1, -1, -1, 0, 1, 1, 1)
    private const val MARK_NEW: Byte = 2                    // MASK8_NEW
    private val MARK_RIGHT: Byte = (2 or 0x80).toByte()     // MASK8_NEW | MASK8_RIGHT, i.e. -126

    /**
     * `cv2.findContours(mask, RETR_EXTERNAL, CHAIN_APPROX_SIMPLE)`: Suzuki-Abe
     * border following as `contours_new.cpp` implements it, on the mask padded
     * with one background pixel all round. [mask] is non-zero for foreground,
     * row-major, [width] wide; [offsetX]/[offsetY] are added to every point.
     *
     * Order matters and is OpenCV's: each new contour is PREPENDED to the root's
     * children, so the list comes back last-found first — bottom of the frame
     * first, not top. A component inside another's hole is not returned at all.
     */
    fun findContours(mask: ByteArray, width: Int, height: Int,
                     offsetX: Int = 0, offsetY: Int = 0): List<Contour> {
        require(mask.size >= width * height) { "findContours: mask too small" }
        val w = width + 2
        val h = height + 2
        val img = ByteArray(w * h)
        for (y in 0 until height) {
            for (x in 0 until width) {
                if (mask[y * width + x].toInt() != 0) img[(y + 1) * w + x + 1] = 1
            }
        }
        val delta = IntArray(8) { DX[it] + DY[it] * w }
        val found = ArrayList<Contour>()

        // ContourScanner_ state: where the raster scan resumes, and the last
        // border pixel it passed (lnbd), which decides nesting.
        var ptX = 1
        var ptY = 1
        var lnbdX = 0
        var lnbdY = 1
        while (true) {
            var x = ptX
            var y = ptY
            var lastX = lnbdX
            var lastY = lnbdY
            var prev = img[y * w + x - 1].toInt()
            var traced = false
            rows@ while (y < h - 1) {
                var p: Int
                while (x < w - 1) {
                    // findNextX
                    p = prev
                    while (x < w - 1) {
                        p = img[y * w + x].toInt()
                        if (p != prev) break
                        x += 1
                    }
                    if (x >= w - 1) break
                    // contourScan, RETR_EXTERNAL on an 8-bit image
                    var take = true
                    var isHole = false
                    if (!(prev == 0 && p == 1)) {
                        if (p != 0 || prev < 1) {
                            take = false
                        } else {
                            if ((prev and -2) != 0) lastX = x - 1
                            isHole = true
                        }
                    }
                    if (take && (isHole || img[lastY * w + lastX] > 0)) take = false
                    if (take) {
                        lastX = x
                        found.add(fetchContour(img, w, delta, x, y, offsetX - 1, offsetY - 1))
                        ptX = x + 1
                        ptY = y
                        lnbdX = lastX
                        lnbdY = lastY
                        traced = true
                        break@rows
                    }
                    prev = p
                    if ((prev and -2) != 0) lastX = x
                    x += 1
                }
                lastX = 0
                lastY = y + 1
                x = 1
                prev = 0
                y += 1
            }
            if (!traced) break
        }
        found.reverse()
        return found
    }

    /** `icvFetchContourEx` for an outer border with CHAIN_APPROX_SIMPLE: a point wherever the chain turns. */
    private fun fetchContour(img: ByteArray, w: Int, delta: IntArray, startX: Int, startY: Int,
                             ox: Int, oy: Int): Contour {
        val xs = ArrayList<Int>()
        val ys = ArrayList<Int>()
        val i0 = startY * w + startX
        var ptx = startX + ox
        var pty = startY + oy
        var sEnd = 4
        var s = sEnd
        var i1: Int
        do {
            s = (s - 1) and 7
            i1 = i0 + delta[s]
        } while (img[i1].toInt() == 0 && s != sEnd)

        if (s == sEnd) {                                    // a single pixel
            img[i0] = MARK_RIGHT
            xs.add(ptx); ys.add(pty)
        } else {
            var i3 = i0
            var prevS = s xor 4
            while (true) {
                sEnd = s
                s = minOf(s, 15)
                var i4 = i3
                while (s < 15) {
                    s += 1
                    i4 = i3 + delta[s and 7]
                    if (img[i4].toInt() != 0) break
                }
                s = s and 7
                // (unsigned)(s - 1) < (unsigned)s_end: the pixel's right was examined and empty.
                if (s >= 1 && s - 1 < sEnd) {
                    img[i3] = MARK_RIGHT
                } else if (img[i3].toInt() == 1) {
                    img[i3] = MARK_NEW
                }
                if (s != prevS) {
                    xs.add(ptx); ys.add(pty)
                }
                prevS = s
                ptx += DX[s]
                pty += DY[s]
                if (i4 == i0 && i3 == i1) break
                i3 = i4
                s = (s + 4) and 7
            }
        }
        return Contour(xs.toIntArray(), ys.toIntArray())
    }

    /** `cv2.contourArea(c)`: the shoelace polygon area, unsigned. Not a pixel count — a filled disc reads smaller. */
    fun contourArea(c: Contour): Double {
        val n = c.size
        if (n == 0) return 0.0
        var a00 = 0.0
        var px = c.x[n - 1].toDouble()
        var py = c.y[n - 1].toDouble()
        for (i in 0 until n) {
            val x = c.x[i].toDouble()
            val y = c.y[i].toDouble()
            a00 += px * y - py * x
            px = x
            py = y
        }
        return abs(a00 * 0.5)
    }

    // ------------------------------------------------------------------ ellipse

    private const val FLT_EPSILON = 1.1920928955078125e-07
    private const val DBL_EPSILON = 2.220446049250313e-16

    /**
     * `cv2.fitEllipse(c)`, which in OpenCV 5 is two algorithms: the direct
     * least-squares fit for exactly five points, the general-conic fit with a
     * re-fitted centre otherwise. The centre is what the detector probes from.
     */
    fun fitEllipse(c: Contour): RotatedRect {
        require(c.size >= 5) { "fitEllipse needs at least 5 points" }
        val rng = CvRng()
        return if (c.size == 5) fitEllipseDirect(c, rng) else fitEllipseNoDirect(c, rng)
    }

    /**
     * `fitEllipseNoDirect`. The perturbed retry below is OpenCV's answer to a
     * degenerate point set; the reference draws its offsets from the process-wide
     * `theRNG()`, so its own result there depends on every earlier call and no
     * fixture can pin it. Here the draws come from a fresh `cv::RNG` — what a
     * new process would use — which at least makes the Kotlin repeatable.
     */
    private fun fitEllipseNoDirect(c: Contour, rng: CvRng): RotatedRect {
        val n = c.size
        val px = FloatArray(n) { c.x[it].toFloat() }
        val py = FloatArray(n) { c.y[it].toFloat() }
        var cx = 0f
        var cy = 0f
        for (i in 0 until n) {
            cx += px[i]
            cy += py[i]
        }
        cx /= n.toFloat()
        cy /= n.toFloat()
        var s = 0.0
        for (i in 0 until n) s += (abs(px[i] - cx) + abs(py[i] - cy)).toDouble()
        val scale = 100.0 / (if (s > FLT_EPSILON) s else FLT_EPSILON)

        fun conicRows(): Array<DoubleArray> = Array(n) { i ->
            val x = (px[i] - cx).toDouble() * scale
            val y = (py[i] - cy).toDouble() * scale
            doubleArrayOf(-x * x, -y * y, -x * y, x, y)    // A - C signs inverted, as OpenCV has them
        }
        val b = DoubleArray(n) { 10000.0 }
        var svd = Svd(conicRows())
        if (svd.wMax * FLT_EPSILON > svd.wMin) {
            val eps = (s / (n * 2) * 1e-3).toFloat()
            for (i in 0 until n) {
                px[i] = px[i] + rng.uniform(-eps, eps)
                py[i] = py[i] + rng.uniform(-eps, eps)
            }
            svd = Svd(conicRows())
        }
        val gfp = svd.solve(b)

        // The centre, from the gradient of the general conic.
        val rp = DoubleArray(5)
        val centre = Svd(arrayOf(doubleArrayOf(2 * gfp[0], gfp[2]), doubleArrayOf(gfp[2], 2 * gfp[1])))
            .solve(doubleArrayOf(gfp[3], gfp[4]))
        rp[0] = centre[0]
        rp[1] = centre[1]

        // A - C again, with that centre held.
        val refit = Svd(Array(n) { i ->
            val x = (px[i] - cx).toDouble() * scale
            val y = (py[i] - cy).toDouble() * scale
            doubleArrayOf((x - rp[0]) * (x - rp[0]), (y - rp[1]) * (y - rp[1]), (x - rp[0]) * (y - rp[1]))
        }).solve(DoubleArray(n) { 1.0 })
        gfp[0] = refit[0]
        gfp[1] = refit[1]
        gfp[2] = refit[2]

        val minEps = 1e-8
        rp[4] = -0.5 * atan2(gfp[2], gfp[1] - gfp[0])
        val t = if (abs(gfp[2]) > minEps) gfp[2] / sin(-2.0 * rp[4]) else gfp[1] - gfp[0]
        rp[2] = abs(gfp[0] + gfp[1] - t)
        if (rp[2] > minEps) rp[2] = sqrt(2.0 / rp[2])
        rp[3] = abs(gfp[0] + gfp[1] + t)
        if (rp[3] > minEps) rp[3] = sqrt(2.0 / rp[3])

        val ecx = (rp[0] / scale).toFloat() + cx
        val ecy = (rp[1] / scale).toFloat() + cy
        var width = (rp[2] * 2 / scale).toFloat()
        var height = (rp[3] * 2 / scale).toFloat()
        if (width > height) {
            val tmp = width; width = height; height = tmp
        }
        return RotatedRect(ecx, ecy, width, height)
    }

    /**
     * `fitEllipseDirect` (Fitzgibbon's constrained fit), which `fitEllipse` uses
     * for exactly five points. The eigenvector is found by a different route
     * from OpenCV's (characteristic cubic, not Hessenberg QR), which is free:
     * the code normalises it and keeps only its direction, and the centre comes
     * back as a float32 either way.
     */
    private fun fitEllipseDirect(c: Contour, rng: CvRng): RotatedRect {
        val n = c.size
        var mx = 0.0
        var my = 0.0
        for (i in 0 until n) {
            mx += c.x[i].toFloat().toDouble()
            my += c.y[i].toFloat().toDouble()
        }
        mx /= n
        my /= n
        var s = 0.0
        for (i in 0 until n) s += abs(c.x[i].toFloat() - mx) + abs(c.y[i].toFloat() - my)
        val scale = 100.0 / (if (s > FLT_EPSILON) s else FLT_EPSILON)

        var eps = 0f
        var iter = 0
        var pick = -1
        var vecs: List<DoubleArray> = emptyList()
        val tm = Array(3) { DoubleArray(3) }
        var ts = 0.0
        while (iter < 2) {
            val a = Array(n) { DoubleArray(6) }
            for (i in 0 until n) {
                // getOfs(eps) draws twice per point even when eps is zero.
                val ox = rng.uniform(-eps, eps)
                val oy = rng.uniform(-eps, eps)
                val x = ((c.x[i].toFloat() + ox).toDouble() - mx) * scale
                val y = ((c.y[i].toFloat() + oy).toDouble() - my) * scale
                a[i][0] = x * x; a[i][1] = x * y; a[i][2] = y * y
                a[i][3] = x; a[i][4] = y; a[i][5] = 1.0
            }
            val dm = Array(6) { DoubleArray(6) }
            for (i in 0 until 6) {
                for (j in i until 6) {
                    var sum = 0.0
                    for (k in 0 until n) sum += a[k][i] * a[k][j]
                    dm[i][j] = sum
                    dm[j][i] = sum
                }
            }
            val inv = 1.0 / n
            for (i in 0 until 6) for (j in 0 until 6) dm[i][j] *= inv
            fun d(i: Int, j: Int) = dm[i][j]
            for (col in 0 until 3) {
                tm[0][col] = d(col, 5) * d(3, 5) * d(4, 4) - d(col, 5) * d(3, 4) * d(4, 5) - d(col, 4) * d(3, 5) * d(5, 4) +
                    d(col, 3) * d(4, 5) * d(5, 4) + d(col, 4) * d(3, 4) * d(5, 5) - d(col, 3) * d(4, 4) * d(5, 5)
                tm[1][col] = d(col, 5) * d(3, 3) * d(4, 5) - d(col, 5) * d(3, 5) * d(4, 3) + d(col, 4) * d(3, 5) * d(5, 3) -
                    d(col, 3) * d(4, 5) * d(5, 3) - d(col, 4) * d(3, 3) * d(5, 5) + d(col, 3) * d(4, 3) * d(5, 5)
                tm[2][col] = d(col, 5) * d(3, 4) * d(4, 3) - d(col, 5) * d(3, 3) * d(4, 4) - d(col, 4) * d(3, 4) * d(5, 3) +
                    d(col, 3) * d(4, 4) * d(5, 3) + d(col, 4) * d(3, 3) * d(5, 4) - d(col, 3) * d(4, 3) * d(5, 4)
            }
            ts = (-(d(3, 5) * d(4, 4) * d(5, 3)) + d(3, 4) * d(4, 5) * d(5, 3) + d(3, 5) * d(4, 3) * d(5, 4) -
                d(3, 3) * d(4, 5) * d(5, 4) - d(3, 4) * d(4, 3) * d(5, 5) + d(3, 3) * d(4, 4) * d(5, 5))
            if (abs(ts) < DBL_EPSILON) {
                eps = (s / (n * 2) * 1e-2).toFloat()
                iter += 1
                continue
            }
            val m = Array(3) { DoubleArray(3) }
            for (col in 0 until 3) {
                m[0][col] = (d(2, col) + (d(2, 3) * tm[0][col] + d(2, 4) * tm[1][col] + d(2, 5) * tm[2][col]) / ts) / 2.0
                m[1][col] = -d(1, col) - (d(1, 3) * tm[0][col] + d(1, 4) * tm[1][col] + d(1, 5) * tm[2][col]) / ts
                m[2][col] = (d(0, col) + (d(0, 3) * tm[0][col] + d(0, 4) * tm[1][col] + d(0, 5) * tm[2][col]) / ts) / 2.0
            }
            vecs = realEigenvectors3(m)
            // The eigenvector with 4ac - b^2 > 0 is the ellipse; the others are hyperbolae.
            val cond = DoubleArray(3) { k ->
                if (k < vecs.size) 4.0 * vecs[k][0] * vecs[k][2] - vecs[k][1] * vecs[k][1] else Double.NEGATIVE_INFINITY
            }
            pick = if (cond[0] < cond[1]) (if (cond[1] < cond[2]) 2 else 1) else (if (cond[0] < cond[2]) 2 else 0)
            if (pick < vecs.size) {
                val v = vecs[pick]
                if (cond[pick] > 1e-6 * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2])) break
            }
            eps = (s / (n * 2) * 1e-2).toFloat()
            iter += 1
        }
        if (iter >= 2) return fitEllipseNoDirect(c, rng)

        val v = vecs[pick]
        var norm = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
        val signs = (if (v[0] < 0.0) -1 else 1) * (if (v[1] < 0.0) -1 else 1) * (if (v[2] < 0.0) -1 else 1)
        if (signs <= 0) norm = -norm
        val p0 = v[0] / norm
        val p1 = v[1] / norm
        val p2 = v[2] / norm
        val q0 = (tm[0][0] * p0 + tm[0][1] * p1 + tm[0][2] * p2) / ts
        val q1 = (tm[1][0] * p0 + tm[1][1] * p1 + tm[1][2] * p2) / ts
        val q2 = (tm[2][0] * p0 + tm[2][1] * p1 + tm[2][2] * p2) / ts
        val u1 = p2 * q0 * q0 - p1 * q0 * q1 + p0 * q1 * q1 + p1 * p1 * q2
        val u2 = p0 * p2 * q2
        val l1 = sqrt(p1 * p1 + (p0 - p2) * (p0 - p2))
        val l2 = p0 + p2
        val l3 = p1 * p1 - 4 * p0 * p2
        val e1 = 2 * p2 * q0 - p1 * q1
        val e2 = 2 * p0 * q1 - p1 * q0
        val x0 = (e1 / l3 / scale) + mx
        val y0 = (e2 / l3 / scale) + my
        val a = sqrt(2.0) * sqrt((u1 - 4.0 * u2) / ((l1 - l2) * l3)) / scale
        val b = sqrt(2.0) * sqrt(-1.0 * ((u1 - 4.0 * u2) / ((l1 + l2) * l3))) / scale
        var width = (2.0 * a).toFloat()
        var height = (2.0 * b).toFloat()
        if (width > height) {
            val tmp = width; width = height; height = tmp
        }
        return RotatedRect(x0.toFloat(), y0.toFloat(), width, height)
    }

    // ------------------------------------------------------------------ circle

    private const val EPS_F = 1.0e-4f

    private fun norm(dx: Float, dy: Float): Double =
        sqrt(dx.toDouble() * dx.toDouble() + dy.toDouble() * dy.toDouble())

    /**
     * `cv2.minEnclosingCircle(c)`, Welzl's recursion as OpenCV writes it, in its
     * float32. Above ten points OpenCV shuffles the input with a seeded `cv::RNG`
     * first; the detector only asks for fewer than five, so that is not ported.
     */
    fun minEnclosingCircle(c: Contour): Circle {
        val n = c.size
        if (n == 0) return Circle(0f, 0f, 0f)
        require(n <= 10) { "minEnclosingCircle: the >10-point shuffle is not ported" }
        val px = FloatArray(n) { c.x[it].toFloat() }
        val py = FloatArray(n) { c.y[it].toFloat() }
        if (n == 1) return Circle(px[0], py[0], EPS_F)

        var ccx = 0f
        var ccy = 0f
        var rad = 0f
        // (float)(pts[i] + pts[j]) / 2.0f, on the integer points
        fun mid(i: Int, j: Int, xs: IntArray) = (xs[i] + xs[j]).toFloat() / 2.0f
        fun half(i: Int, j: Int): Float =
            norm((c.x[i] - c.x[j]).toFloat(), (c.y[i] - c.y[j]).toFloat()).toFloat() / 2.0f + EPS_F

        fun circle3(i: Int, j: Int, k: Int) {
            val ax = px[i]; val ay = py[i]
            val v1x = px[j] - ax; val v1y = py[j] - ay
            val v2x = px[k] - ax; val v2y = py[k] - ay
            val m1x = (ax + px[j]) / 2.0f; val m1y = (ay + py[j]) / 2.0f
            val c1 = m1x * v1x + m1y * v1y
            val m2x = (ax + px[k]) / 2.0f; val m2y = (ay + py[k]) / 2.0f
            val c2 = m2x * v2x + m2y * v2y
            val det = v1x * v2y - v1y * v2x
            if (abs(det) <= EPS_F) return              // degenerate: OpenCV keeps what it had
            var x = (c1 * v2y - c2 * v1y) / det
            var y = (v1x * c2 - v2x * c1) / det
            ccx = x
            ccy = y
            x -= ax
            y -= ay
            rad = sqrt(x * x + y * y) + EPS_F
        }

        ccx = mid(0, 1, c.x); ccy = mid(0, 1, c.y); rad = half(0, 1)
        for (i in 2 until n) {
            val d = norm(px[i] - ccx, py[i] - ccy).toFloat()
            if (d < rad) continue
            // findSecondPoint
            ccx = mid(0, i, c.x); ccy = mid(0, i, c.y); rad = half(0, i)
            for (j in 1 until i) {
                if (norm(ccx - px[j], ccy - py[j]) < rad) continue
                // findThirdPoint
                ccx = mid(j, i, c.x); ccy = mid(j, i, c.y); rad = half(j, i)
                for (k in 0 until j) {
                    if (norm(ccx - px[k], ccy - py[k]) < rad) continue
                    circle3(i, j, k)
                }
            }
        }
        return Circle(ccx, ccy, rad)
    }

    // ------------------------------------------------------------------ linear algebra

    /**
     * One-sided Jacobi SVD of a small dense matrix ([rows] x columns), and the
     * least-squares solve `cv::solve(..., DECOMP_SVD)` / `SVBackSubst` make with
     * it: singular values at or under `2 * DBL_EPSILON * sum(w)` are dropped.
     * OpenCV's own SVD is one-sided Jacobi too (or LAPACK, where it is linked);
     * the solution of a well-posed system does not depend on which.
     */
    private class Svd(rows: Array<DoubleArray>) {
        private val m = rows.size
        private val k = rows[0].size
        private val u = Array(k) { c -> DoubleArray(m) { r -> rows[r][c] } }   // columns, orthogonalised in place
        private val v = Array(k) { i -> DoubleArray(k) { j -> if (i == j) 1.0 else 0.0 } }
        val w = DoubleArray(k)

        init {
            val eps = DBL_EPSILON * 10
            for (sweep in 0 until 60) {
                var changed = false
                for (i in 0 until k - 1) {
                    for (j in i + 1 until k) {
                        val ai = u[i]
                        val aj = u[j]
                        var alpha = 0.0
                        var beta = 0.0
                        var gamma = 0.0
                        for (r in 0 until m) {
                            alpha += ai[r] * ai[r]
                            beta += aj[r] * aj[r]
                            gamma += ai[r] * aj[r]
                        }
                        if (gamma == 0.0 || abs(gamma) <= eps * sqrt(alpha * beta)) continue
                        changed = true
                        val zeta = (beta - alpha) / (2.0 * gamma)
                        val t = (if (zeta < 0) -1.0 else 1.0) / (abs(zeta) + sqrt(1.0 + zeta * zeta))
                        val cs = 1.0 / sqrt(1.0 + t * t)
                        val sn = cs * t
                        for (r in 0 until m) {
                            val x = ai[r]
                            val y = aj[r]
                            ai[r] = cs * x - sn * y
                            aj[r] = sn * x + cs * y
                        }
                        val vi = v[i]
                        val vj = v[j]
                        for (r in 0 until k) {
                            val x = vi[r]
                            val y = vj[r]
                            vi[r] = cs * x - sn * y
                            vj[r] = sn * x + cs * y
                        }
                    }
                }
                if (!changed) break
            }
            for (i in 0 until k) {
                var ss = 0.0
                for (r in 0 until m) ss += u[i][r] * u[i][r]
                w[i] = sqrt(ss)
                if (w[i] > 0) for (r in 0 until m) u[i][r] /= w[i]
            }
        }

        val wMax: Double get() = w.max()
        val wMin: Double get() = w.min()

        fun solve(b: DoubleArray): DoubleArray {
            val threshold = w.sum() * DBL_EPSILON * 2
            val x = DoubleArray(k)
            for (i in 0 until k) {
                if (abs(w[i]) <= threshold) continue
                var s = 0.0
                for (r in 0 until m) s += u[i][r] * b[r]
                s /= w[i]
                for (j in 0 until k) x[j] += s * v[i][j]
            }
            return x
        }
    }

    /**
     * The real eigenvectors of a 3x3 matrix, one per real eigenvalue: roots of
     * the characteristic cubic polished by Newton, each vector the largest cross
     * product of two rows of (M - lambda I).
     */
    private fun realEigenvectors3(mat: Array<DoubleArray>): List<DoubleArray> {
        val tr = mat[0][0] + mat[1][1] + mat[2][2]
        val c1 = (mat[0][0] * mat[1][1] - mat[0][1] * mat[1][0]) +
            (mat[0][0] * mat[2][2] - mat[0][2] * mat[2][0]) +
            (mat[1][1] * mat[2][2] - mat[1][2] * mat[2][1])
        val det = mat[0][0] * (mat[1][1] * mat[2][2] - mat[1][2] * mat[2][1]) -
            mat[0][1] * (mat[1][0] * mat[2][2] - mat[1][2] * mat[2][0]) +
            mat[0][2] * (mat[1][0] * mat[2][1] - mat[1][1] * mat[2][0])
        // lambda^3 + a lambda^2 + b lambda + c, depressed to t^3 + p t + q.
        val a = -tr
        val b = c1
        val cc = -det
        val p = b - a * a / 3.0
        val q = 2.0 * a * a * a / 27.0 - a * b / 3.0 + cc
        val roots = ArrayList<Double>()
        if (p < 0) {
            val r = sqrt(-p / 3.0)
            val arg = (if (r > 0) -q / (2.0 * r * r * r) else 0.0).coerceIn(-1.0, 1.0)
            val phi = kotlin.math.acos(arg)
            for (kk in 0 until 3) roots.add(2.0 * r * kotlin.math.cos((phi - 2.0 * Math.PI * kk) / 3.0) - a / 3.0)
        } else {
            val disc = sqrt(q * q / 4.0 + p * p * p / 27.0)
            roots.add(Math.cbrt(-q / 2.0 + disc) + Math.cbrt(-q / 2.0 - disc) - a / 3.0)
        }
        val out = ArrayList<DoubleArray>()
        for (root in roots) {
            var lam = root
            repeat(3) {
                val f = ((lam - tr) * lam + c1) * lam - det
                val df = (3.0 * lam - 2.0 * tr) * lam + c1
                if (df != 0.0) lam -= f / df
            }
            val r0 = doubleArrayOf(mat[0][0] - lam, mat[0][1], mat[0][2])
            val r1 = doubleArrayOf(mat[1][0], mat[1][1] - lam, mat[1][2])
            val r2 = doubleArrayOf(mat[2][0], mat[2][1], mat[2][2] - lam)
            var best = DoubleArray(3)
            var bestNorm = -1.0
            for ((u, v) in listOf(r0 to r1, r0 to r2, r1 to r2)) {
                val cr = doubleArrayOf(u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
                val nn = cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2]
                if (nn > bestNorm) {
                    best = cr
                    bestNorm = nn
                }
            }
            out.add(best)
        }
        return out
    }

    /** `cv::RNG`, the multiply-with-carry generator, from its default state. */
    private class CvRng {
        private var state: Long = 0xffffffffL

        private fun next(): Int {
            state = (state and 0xffffffffL) * 4164903690L + (state ushr 32)
            return state.toInt()
        }

        /** `RNG::uniform(float, float)`: `(float)next * 2^-32 * (b - a) + a`, in float. */
        fun uniform(a: Float, b: Float): Float =
            ((next().toLong() and 0xffffffffL).toFloat() * 2.3283064365386962890625e-10f) * (b - a) + a
    }
}
