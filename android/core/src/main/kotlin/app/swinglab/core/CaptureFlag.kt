// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Port of `CaptureFlag.swift` `CaptureFlag` (app-only: deliberately NOT part of
 * [SwingFlag] or the parity fixtures); the reasoning lives there.
 */
enum class CaptureFlag(val raw: String) {
    cameraTilted("CAMERA_TILTED"),
    tiltCorrected("TILT_CORRECTED"),
    notLevel("NOT_LEVEL"),
    levelUnknown("LEVEL_UNKNOWN"),
    distanceOutsideProtocol("DISTANCE_OUTSIDE_PROTOCOL"),
    distanceNotMeasured("DISTANCE_NOT_MEASURED"),
    scaleFromManualDistance("SCALE_FROM_MANUAL_DISTANCE"),
    distanceFromHitterHeight("DISTANCE_FROM_HITTER_HEIGHT"),
    triggeredOnWrongSound("TRIGGERED_ON_WRONG_SOUND"),
    hitterGateDisabled("HITTER_GATE_DISABLED"),
    cameraHeightOffProtocol("CAMERA_HEIGHT_OFF_PROTOCOL"),
    ballUnconfirmed("BALL_UNCONFIRMED"),
    framesDropped("FRAMES_DROPPED"),
    importedClip("IMPORTED_CLIP");

    val explanation: String
        get() = when (this) {
            cameraTilted ->
                "The camera was pointing up or down steeply, or its lens field of view was unknown, so the tilt could not be corrected. That leaves the flight plane projected — treat the launch angle as approximate. Raise the tripod and keep it level rather than aiming up at contact height."
            tiltCorrected ->
                "The camera was aimed up or down, and the track was rectified to what a level camera would have recorded before anything was measured. Costs little accuracy at this angle; recorded so a surprising reading can be traced."
            notLevel ->
                "The horizon sat at an angle in frame. This one IS corrected in the maths, so it costs little accuracy; it is recorded so a surprising reading can be explained."
            levelUnknown ->
                "No motion-sensor reading was available, so the camera's angle is unknown rather than known-good."
            distanceOutsideProtocol ->
                "The camera was outside the 3.5–8.5 m window the capture protocol asks for. Readings are still computed, but the ball is smaller or larger in frame than the detector is tuned for."
            distanceNotMeasured ->
                "The camera distance was never measured for this swing — the ball was not tapped during setup. Launch angle and exit velocity do not need it: the scale comes from the ball's own size in the picture. What was skipped is the sound-travel correction on contact time, about three frames at 240fps, and the lens-height estimate."
            scaleFromManualDistance ->
                "Scale came from a typed distance rather than a measured object, so it inherits whatever error is in that number."
            distanceFromHitterHeight ->
                "The camera distance was measured from the hitter's body — the typed standing height, and the pose's nose-to-ankle span taken to be 0.87 of it. That fraction is a population average: it varies by two or three percent between people, and it has never been checked against a taped distance on this app's own footage. Launch angle and exit velocity do not use the distance at all — their scale comes from the ball's own size in the picture. What does use it is the sound-travel correction on contact time and the lens-height estimate, and both tolerate far more error than this."
            triggeredOnWrongSound ->
                "Something during this clip was much louder than the sound that started the recording, so the trigger fired on something that was not the hit — and once a clip is recording the trigger is off, so it never heard the real one. The contact time on this swing is the time of the wrong sound. Launch angle and exit velocity survive it (the analysis falls back to the first frame of the flight and flags that), but the bat metrics do not, and the next swing here will do the same. Settings → Trigger → Calibrate measures what a hit at this venue actually sounds like."
            hitterGateDisabled ->
                "The requirement for a person in frame was switched off for this session, so a loud noise alone could have started this clip."
            ballUnconfirmed ->
                "No struck ball could be identified in this clip, so the launch angle and exit velocity here are measurements of whatever the detector settled on — not of the swing. On cluttered footage the pipeline chooses between hundreds of candidate tracks, and when it chooses wrong the numbers look ordinary. Open the swing, tap \"Point at the ball\", and touch the ball on any frame where you can see it: the flight is then followed from there and this flag clears."
            cameraHeightOffProtocol ->
                "The lens was measured well away from the 1.1 m contact height the capture protocol asks for. A level camera sees the same geometry from any height, so this costs no accuracy by itself — the ball simply rides higher or lower in the picture. It is recorded because the on-screen framing guide is drawn for 1.1 m, so it was not a valid target for this shot, and because the usual reaction to a low camera is to aim it upward, which does cost accuracy."
            importedClip ->
                "This clip was imported, not filmed by the app. Launch angle and exit velocity still hold — both come from the ball's own size in the picture, which travels with the footage. What is missing is everything the app measures at capture time: no camera distance, no level or tilt reading to correct with, and no audio trigger, so contact is taken to be the first frame the ball was tracked in rather than the crack of the bat."
            framesDropped ->
                "The camera dropped frames while this clip was recorded. Every measurement here assumes a constant frame interval, so timing — and therefore exit velocity — may be off. Close other apps and let the phone cool down. Frames are only counted as dropped while armed; a clip is flagged when the count moved between the previous swing and this one, and the count now runs for the whole round rather than restarting after each swing — before that it could only flag a swing that dropped more frames than the one before it, so a phone shedding a steady few per clip flagged one swing and then went quiet."
        }

    /** Short label for the chip row. */
    val shortLabel: String
        get() = when (this) {
            cameraTilted -> "tilted"
            tiltCorrected -> "tilt corrected"
            notLevel -> "off level"
            levelUnknown -> "level unknown"
            distanceOutsideProtocol -> "distance"
            distanceNotMeasured -> "no distance"
            scaleFromManualDistance -> "typed distance"
            distanceFromHitterHeight -> "hitter-height distance"
            triggeredOnWrongSound -> "wrong trigger sound"
            hitterGateDisabled -> "no hitter check"
            cameraHeightOffProtocol -> "camera height"
            ballUnconfirmed -> "ball not identified"
            importedClip -> "imported"
            framesDropped -> "dropped frames"
        }

    companion object {
        fun fromRaw(raw: String): CaptureFlag? = entries.firstOrNull { it.raw == raw }
    }
}
