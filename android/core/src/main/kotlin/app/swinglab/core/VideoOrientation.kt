// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.atan2

/**
 * Port of `VideoOrientation.swift` `enum VideoOrientation` (buffer pixels to the
 * displayed frame); the reasoning lives there.
 */
object VideoOrientation {

    /** The `(width: Int, height: Int)` tuple [displaySize] returns. */
    data class DisplaySize(val width: Int, val height: Int)

    /** Port of `VideoOrientation.quarterTurns(_:)`: clockwise quarter turns, 0-3, snapped. */
    fun quarterTurns(t: AffineTransform): Int {
        val angle = atan2(t.b, t.a)
        val turns = (angle / (PI / 2)).rounded().toInt()
        return ((turns % 4) + 4) % 4
    }

    /** Port of `VideoOrientation.displaySize(width:height:quarterTurns:)`. */
    fun displaySize(width: Int, height: Int, quarterTurns: Int): DisplaySize {
        val q = quarterTurns
        return if (q % 2 == 0) DisplaySize(width, height) else DisplaySize(height, width)
    }

    /**
     * Port of `VideoOrientation.point(x:y:width:height:quarterTurns:)`: buffer
     * pixels in, display pixels out, y down in both. The Swift's `(x:, y:)`
     * tuple is a [Point].
     */
    fun point(x: Double, y: Double, width: Int, height: Int, quarterTurns: Int): Point {
        val w = width.toDouble()
        val h = height.toDouble()
        return when (quarterTurns) {
            1 -> Point(h - 1 - y, x)          // 90 clockwise
            2 -> Point(w - 1 - x, h - 1 - y)  // 180
            3 -> Point(y, w - 1 - x)          // 270 clockwise
            else -> Point(x, y)
        }
    }

    /** Port of `VideoOrientation.quarterTurns(from:)`, for clips with no display matrix. */
    fun quarterTurns(from: ImagePropertyOrientation): Int = when (from) {
        ImagePropertyOrientation.right, ImagePropertyOrientation.rightMirrored -> 1
        ImagePropertyOrientation.down, ImagePropertyOrientation.downMirrored -> 2
        ImagePropertyOrientation.left, ImagePropertyOrientation.leftMirrored -> 3
        else -> 0
    }

    /** Port of `VideoOrientation.imageOrientation(quarterTurns:)`. */
    fun imageOrientation(quarterTurns: Int): ImagePropertyOrientation =
        when (((quarterTurns % 4) + 4) % 4) {
            1 -> ImagePropertyOrientation.right
            2 -> ImagePropertyOrientation.down
            3 -> ImagePropertyOrientation.left
            else -> ImagePropertyOrientation.up
        }

    /** Port of `VideoOrientation.rotate(pose:width:height:quarterTurns:)`; each joint keeps its confidence. */
    // Both rotate overloads erase to rotate(List, int, int, int) on the JVM, so
    // this one gets its own bytecode name; Kotlin callers still write rotate(pose = ...).
    @JvmName("rotatePose")
    fun rotate(pose: List<PoseObservation>, width: Int, height: Int, quarterTurns: Int): List<PoseObservation> {
        val q = quarterTurns
        if (q == 0) return pose
        return pose.map { obs ->
            val joints = obs.joints.mapValues { (_, pt) ->
                val p = point(x = pt.x, y = pt.y, width = width, height = height, quarterTurns = q)
                PosePoint(x = p.x, y = p.y, confidence = pt.confidence)
            }
            PoseObservation(frame = obs.frame, t = obs.t, joints = joints)
        }
    }

    /** Port of `VideoOrientation.rotate(track:width:height:quarterTurns:)`; diameters are lengths and do not rotate. */
    fun rotate(track: List<BallObservation>, width: Int, height: Int, quarterTurns: Int): List<BallObservation> {
        val q = quarterTurns
        if (q == 0) return track
        return track.map { o ->
            val p = point(x = o.x, y = o.y, width = width, height = height, quarterTurns = q)
            BallObservation(frame = o.frame, t = o.t, x = p.x, y = p.y,
                            diameterPx = o.diameterPx, areaPx = o.areaPx)
        }
    }
}
