// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

// CoreGraphics stand-ins. The Swift core uses CGPoint / CGSize / CGRect /
// CGAffineTransform (CGFloat is Double on every iPhone); these carry the same
// field names and the CoreGraphics semantics the core relies on, so ported
// code reads like the Swift beside it.

/** Stand-in for `CGPoint`. */
data class Point(val x: Double, val y: Double) {
    /** `CGPoint.applying(_:)`. */
    fun applying(t: AffineTransform): Point =
        Point(t.a * x + t.c * y + t.tx, t.b * x + t.d * y + t.ty)

    companion object {
        val zero = Point(0.0, 0.0)
    }
}

/** Stand-in for `CGSize`. */
data class Size(val width: Double, val height: Double) {
    /** `CGSize.applying(_:)`: the linear part only, no translation. */
    fun applying(t: AffineTransform): Size =
        Size(t.a * width + t.c * height, t.b * width + t.d * height)

    companion object {
        val zero = Size(0.0, 0.0)
    }
}

/**
 * Stand-in for `CGRect`. Like CoreGraphics, the edge and extent accessors are
 * standardized — a negative-size rect reports the same minX/maxX/width as its
 * positive twin — while [origin] and [size] are stored exactly as given.
 */
data class Rect(val origin: Point, val size: Size) {
    constructor(x: Double, y: Double, width: Double, height: Double) :
        this(Point(x, y), Size(width, height))

    val minX: Double get() = minOf(origin.x, origin.x + size.width)
    val maxX: Double get() = maxOf(origin.x, origin.x + size.width)
    val minY: Double get() = minOf(origin.y, origin.y + size.height)
    val maxY: Double get() = maxOf(origin.y, origin.y + size.height)
    val midX: Double get() = origin.x + size.width / 2
    val midY: Double get() = origin.y + size.height / 2
    val width: Double get() = abs(size.width)
    val height: Double get() = abs(size.height)
    val isEmpty: Boolean get() = size.width == 0.0 || size.height == 0.0

    /** `CGRect.contains(_: CGPoint)`: min edges inclusive, max edges exclusive. */
    fun contains(p: Point): Boolean =
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY

    companion object {
        val zero = Rect(0.0, 0.0, 0.0, 0.0)
    }
}

/**
 * Stand-in for `CGAffineTransform`: `x' = a x + c y + tx`, `y' = b x + d y + ty`.
 */
data class AffineTransform(
    val a: Double,
    val b: Double,
    val c: Double,
    val d: Double,
    val tx: Double,
    val ty: Double,
) {
    /** `CGAffineTransform(rotationAngle:)`. */
    constructor(rotationAngle: Double) :
        this(cos(rotationAngle), sin(rotationAngle), -sin(rotationAngle), cos(rotationAngle), 0.0, 0.0)

    /** `CGAffineTransform.inverted()`: returned unchanged when singular, as CoreGraphics does. */
    fun inverted(): AffineTransform {
        val det = a * d - b * c
        if (det == 0.0) return this
        return AffineTransform(
            a = d / det,
            b = -b / det,
            c = -c / det,
            d = a / det,
            tx = (c * ty - d * tx) / det,
            ty = (b * tx - a * ty) / det,
        )
    }

    /**
     * `CGAffineTransform.isIdentity`. Compared field by field because data-class
     * equality treats -0.0 and 0.0 as different and CoreGraphics does not.
     */
    val isIdentity: Boolean
        get() = a == 1.0 && b == 0.0 && c == 0.0 && d == 1.0 && tx == 0.0 && ty == 0.0

    companion object {
        val identity = AffineTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    }
}

/** Port of `Geometry.swift` `enum Geometry` (sla_common.fit_quadratic / solve_gravity_scale); the reasoning lives there. */
object Geometry {

    /** The unnamed `(a, b, c, rms)` tuple `fitQuadratic` returns, highest power first. */
    data class QuadraticFit(val a: Double, val b: Double, val c: Double, val rms: Double)

    /** Port of `Geometry.fitQuadratic` (sla_common.fit_quadratic); the reasoning lives there. */
    fun fitQuadratic(ts: List<Double>, vs: List<Double>): QuadraticFit {
        require(ts.size == vs.size) { "fitQuadratic: mismatched input lengths" }
        val n = ts.size
        if (n <= 0) return QuadraticFit(0.0, 0.0, 0.0, 0.0)

        val distinct = ts.map { it.toRawBits() }.toSet().size
        if (n < 3 || distinct < 3) {
            return fitLowOrder(ts, vs)
        }

        var s0 = 0.0; var s1 = 0.0; var s2 = 0.0; var s3 = 0.0; var s4 = 0.0
        var b0 = 0.0; var b1 = 0.0; var b2 = 0.0
        for (i in 0 until n) {
            val t = ts[i]; val v = vs[i]
            val t2 = t * t
            s0 += 1
            s1 += t
            s2 += t2
            s3 += t2 * t
            s4 += t2 * t2
            b0 += t2 * v
            b1 += t * v
            b2 += v
        }
        val m = arrayOf(
            doubleArrayOf(s4, s3, s2, b0),
            doubleArrayOf(s3, s2, s1, b1),
            doubleArrayOf(s2, s1, s0, b2),
        )

        val sol = solve3x3(m) ?: return fitLowOrder(ts, vs)
        val a = sol[0]; val b = sol[1]; val c = sol[2]

        var sumSq = 0.0
        for (i in 0 until n) {
            val r = vs[i] - (a * ts[i] * ts[i] + b * ts[i] + c)
            sumSq += r * r
        }
        return QuadraticFit(a, b, c, sqrt(sumSq / n.toDouble()))
    }

    /** Port of `Geometry.fitLowOrder`; the reasoning lives there. */
    private fun fitLowOrder(ts: List<Double>, vs: List<Double>): QuadraticFit {
        val n = ts.size
        if (n <= 0) return QuadraticFit(0.0, 0.0, 0.0, 0.0)
        val meanT = ts.fold(0.0) { acc, x -> acc + x } / n.toDouble()
        val meanV = vs.fold(0.0) { acc, x -> acc + x } / n.toDouble()
        var sxx = 0.0; var sxy = 0.0
        for (i in 0 until n) {
            val dt = ts[i] - meanT
            sxx += dt * dt
            sxy += dt * (vs[i] - meanV)
        }
        val b = if (sxx > 0) sxy / sxx else 0.0
        val c = meanV - b * meanT
        var sumSq = 0.0
        for (i in 0 until n) {
            val r = vs[i] - (b * ts[i] + c)
            sumSq += r * r
        }
        return QuadraticFit(0.0, b, c, sqrt(sumSq / n.toDouble()))
    }

    /** Port of `Geometry.solve3x3` (partial pivoting on an augmented 3x4); mutates [m] as the Swift's inout does. */
    private fun solve3x3(m: Array<DoubleArray>): DoubleArray? {
        for (col in 0 until 3) {
            var pivot = col
            for (r in col + 1 until 3) {
                if (abs(m[r][col]) > abs(m[pivot][col])) pivot = r
            }
            if (abs(m[pivot][col]) < 1e-18) return null
            if (pivot != col) {
                val tmp = m[pivot]; m[pivot] = m[col]; m[col] = tmp
            }
            val d = m[col][col]
            for (r in col + 1 until 3) {
                val f = m[r][col] / d
                if (f == 0.0) continue
                for (c in col until 4) {
                    m[r][c] -= f * m[col][c]
                }
            }
        }
        val out = DoubleArray(3)
        for (row in 2 downTo 0) {
            var acc = m[row][3]
            for (c in row + 1 until 3) {
                acc -= m[row][c] * out[c]
            }
            out[row] = acc / m[row][row]
        }
        return out
    }

    /** Port of `Geometry.solveGravityScale` (sla_common.solve_gravity_scale); the reasoning lives there. */
    fun solveGravityScale(
        ayPx: Double,
        vxPxMid: Double,
        vyPxMid: Double,
        scaleHint: Double?,
    ): Double? {
        if (!(ayPx > 1e-6)) return null
        val speedPx = sqrt(vxPxMid * vxPxMid + vyPxMid * vyPxMid)
        val a = SLA.kOverM * speedPx * vyPxMid
        val b = ayPx
        val c = -SLA.g
        if (abs(a) < 1e-9) return SLA.g / ayPx

        val disc = b * b - 4 * a * c
        if (disc < 0) return null
        val sq = sqrt(disc)
        val roots = listOf((-b + sq) / (2 * a), (-b - sq) / (2 * a)).filter { it > 0 }
        if (roots.isEmpty()) return null

        if (scaleHint != null && scaleHint > 0) {
            var best = roots[0]
            var bestErr = abs(roots[0] - scaleHint)
            for (r in roots.drop(1)) {
                val e = abs(r - scaleHint)
                if (e < bestErr) { best = r; bestErr = e }
            }
            return best
        }
        return roots.min()
    }

    /** Port of `Geometry.median` (NumPy-compatible: even counts average the middle two); the reasoning lives there. */
    fun median(xs: List<Double>): Double {
        if (xs.isEmpty()) return Double.NaN
        val s = xs.sorted()
        val n = s.size
        if (n % 2 == 1) return s[n / 2]
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /** Port of `Geometry.sampleStdDev` (ddof = 1); the reasoning lives there. */
    fun sampleStdDev(xs: List<Double>): Double? {
        if (xs.size < 2) return null
        val mean = xs.fold(0.0) { acc, x -> acc + x } / xs.size.toDouble()
        val ss = xs.fold(0.0) { acc, x -> acc + (x - mean) * (x - mean) }
        return sqrt(ss / (xs.size - 1).toDouble())
    }
}
