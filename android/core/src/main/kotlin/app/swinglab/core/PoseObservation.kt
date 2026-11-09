// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

// Codable / CodingKeyRepresentable / Sendable are dropped throughout, as in the
// foundation: no kotlinx.serialization in main, and persistence (including the
// joint-name-keyed JSON object the Swift writes) belongs to the app layer. The
// raw values below are those joint names.

/** Port of `PoseObservation.swift` `enum PoseJoint` (sla_common joint-name constants); the reasoning lives there. */
enum class PoseJoint(val raw: String) {
    nose("nose"),
    neck("neck"),
    leftShoulder("left_shoulder"),
    rightShoulder("right_shoulder"),
    leftHip("left_hip"),
    rightHip("right_hip"),
    leftKnee("left_knee"),
    rightKnee("right_knee"),
    leftAnkle("left_ankle"),
    rightAnkle("right_ankle"),
    leftElbow("left_elbow"),
    rightElbow("right_elbow"),
    leftWrist("left_wrist"),
    rightWrist("right_wrist");

    /** Port of `PoseJoint.isDrawingOnly`: drawn, never measured. */
    val isDrawingOnly: Boolean
        get() = when (this) {
            leftElbow, rightElbow, leftWrist, rightWrist -> true
            else -> false
        }

    companion object {
        fun fromRaw(raw: String): PoseJoint? = entries.firstOrNull { it.raw == raw }

        /** Port of `PoseJoint.segments`: the skeleton's strokes, in draw order. */
        val segments: List<List<PoseJoint>> = listOf(
            listOf(leftShoulder, neck, rightShoulder),
            listOf(neck, nose),
            listOf(leftShoulder, leftHip),
            listOf(rightShoulder, rightHip),
            listOf(leftHip, rightHip),
            listOf(leftHip, leftKnee, leftAnkle),
            listOf(rightHip, rightKnee, rightAnkle),
            listOf(leftShoulder, leftElbow, leftWrist),
            listOf(rightShoulder, rightElbow, rightWrist),
        )
    }
}

/** Port of `PoseObservation.swift` `struct PosePoint`: buffer pixels, y down; the reasoning lives there. */
data class PosePoint(val x: Double, val y: Double, val confidence: Double)

/** Port of `PoseObservation.swift` `struct PoseObservation`; the reasoning lives there. */
data class PoseObservation(
    val frame: Int,
    val t: Double,
    val joints: Map<PoseJoint, PosePoint>,
) {
    /** Port of `PoseObservation.point(_:minConfidence:)`: the joint only if the model was confident about it. */
    fun point(joint: PoseJoint, minConfidence: Double = SLA.jointConfidenceMin): Point? {
        val p = joints[joint] ?: return null
        if (!(p.confidence >= minConfidence)) return null
        return Point(p.x, p.y)
    }

    /** Port of `PoseObservation.midpoint(_:_:minConfidence:)`: both joints confident, or nothing. */
    fun midpoint(a: PoseJoint, b: PoseJoint, minConfidence: Double = SLA.jointConfidenceMin): Point? {
        val p = point(a, minConfidence) ?: return null
        val q = point(b, minConfidence) ?: return null
        return Point((p.x + q.x) / 2, (p.y + q.y) / 2)
    }
}

/** Port of `PoseObservation.swift` `struct BodyMetrics` (sagittal plane only); the reasoning lives there. */
data class BodyMetrics(
    var strideM: Double? = null,
    var headDriftM: Double? = null,
    var weightShiftM: Double? = null,
    var frontKneeDeg: Double? = null,
    var spineTiltDeg: Double? = null,
    var coverage: Double = 0.0,
    var frames: Int = 0,
) {
    val hasAnything: Boolean
        get() = strideM != null || headDriftM != null || weightShiftM != null ||
            frontKneeDeg != null || spineTiltDeg != null
}
