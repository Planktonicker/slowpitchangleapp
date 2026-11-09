// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * The pure part of `SetupOverlay.swift`, which is otherwise a SwiftUI view.
 * Only [feetFraction] is ported: it feeds `CameraPose.lensHeightM` and is
 * pinned by `CameraPoseTests`, and the overlay itself belongs to the app
 * module's UI, not to core.
 */
object SetupOverlay {

    /** Port of `SetupOverlay.feetFraction(from:orientation:)`: mean ankle height, upright; null in portrait or with no ankle. */
    fun feetFraction(from: Map<PoseJoint, Point>?, orientation: ImagePropertyOrientation): Double? {
        val joints = from ?: return null
        val ankles = listOfNotNull(joints[PoseJoint.leftAnkle], joints[PoseJoint.rightAnkle])
        if (ankles.isEmpty()) return null
        val mean = ankles.fold(0.0) { acc, p -> acc + p.y } / ankles.size.toDouble()
        val upright = CameraPose.uprightBufferPoint(
            Point(0.0, mean), orientation = orientation, width = 1.0, height = 1.0,
        ) ?: return null
        return upright.y
    }
}
