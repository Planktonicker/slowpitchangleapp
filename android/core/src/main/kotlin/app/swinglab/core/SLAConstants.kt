// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Port of `SLAConstants.swift` `enum SLA` (the constants and small functions of
 * `spike/sla_common.py`); the reasoning behind every number lives there.
 * Pinned by the shared `parity.json` — never change a value here alone.
 */
object SLA {

    // Physical constants

    const val g = 9.80665
    const val ballCircumferenceM = 12.0 * 0.0254
    const val ballDiameterM = ballCircumferenceM / PI
    const val ballMassKg = 0.190
    const val airDensity = 1.225
    const val dragCd = 0.47
    const val mphPerMps = 2.23694

    const val kOverM = 0.5 * airDensity * dragCd * PI *
        (ballDiameterM / 2) * (ballDiameterM / 2) / ballMassKg

    // Detection defaults

    // Getters handing out a fresh value, where the Swift has `static let`: a
    // Swift struct is copied on assignment, a Kotlin data class with `var`
    // fields is shared, and one shared default would be edited in place by
    // the first venue tuning that started from it.
    val hsvLoDefault: HSVBounds get() = HSVBounds(h = 18.0, s = 100.0, v = 120.0)
    val hsvHiDefault: HSVBounds get() = HSVBounds(h = 40.0, s = 255.0, v = 255.0)

    val batHSVLoDefault: HSVBounds get() = HSVBounds(h = 160.0, s = 90.0, v = 110.0)
    val batHSVHiDefault: HSVBounds get() = HSVBounds(h = 179.0, s = 255.0, v = 255.0)

    const val minRadiusPxDefault = 4.0
    const val maxRadiusPxDefault = 60.0

    const val diameterProfileStepPx = 0.25
    const val diameterProbeDirections = 16
    const val diameterBgInner = 2.2
    const val diameterBgOuter = 3.2
    const val diameterBgPadPx = 5.0

    // Analysis defaults

    const val velocityWindowS = 0.12
    const val gravityWindowS = 0.35
    const val minTrackFrames = 8

    const val trackStraightnessMin = 0.55

    const val stitchMaxGapS = 0.10
    const val stitchBaseTolPx = 30.0
    const val stitchTolPxPerS = 0.35
    const val stitchMaxAngleDeg = 40.0
    const val stitchAccelK = 3.0
    const val stitchVelocityNoisePxS = 400.0
    const val stitchVelocityWindow = 6

    // Seeded tracking

    const val seedSearchRadiusPx = 45.0
    const val seedSearchRadiusFrac = 0.06

    const val speedOfSoundMps = 343.0
    const val contactAudioMaxDistanceM = 60.0

    const val contactMaxBackExtrapolationS = 0.06

    /** Port of `SLA.contactTimeFromAudio` (sla_common.contact_time_from_audio); the reasoning lives there. */
    fun contactTimeFromAudio(audioT: Double, distanceM: Double?): Double {
        val d = distanceM
        if (d == null || !(d > 0) || !(d <= contactAudioMaxDistanceM)) return audioT
        return swiftMax(0.0, audioT - d / speedOfSoundMps)
    }

    const val selectContactTolS = 0.05
    const val selectContactLateS = 0.25
    const val nearContactMinFrames = 4

    const val buildMaxTurnDeg = 60.0
    const val buildTurnMinStepPx = 5.0
    const val buildHeadingWindow = 5

    const val motionDiffThreshold = 18.0
    const val motionDilatePx = 3.0

    /** Port of `SLA.seedSearchRadius` (sla_common.seed_search_radius_px); the reasoning lives there. */
    fun seedSearchRadius(frameWidthPx: Double): Double =
        swiftMax(seedSearchRadiusPx, frameWidthPx * seedSearchRadiusFrac)

    const val seedGateBasePx = 70.0
    const val seedGatePredictedPx = 22.0
    const val seedGateSpeedMult = 0.6
    const val seedMaxCoastFrames = 8
    const val seedSpeedRatioMax = 1.8
    const val seedMaxTurnDeg = 25.0
    const val seedOutlierMinPx = 4.0
    const val seedOutlierSigma = 3.0
    const val minGravityTrackS = 0.20
    const val scaleDisagreeTol = 0.08
    const val diameterDriftTol = 0.10
    const val residualTolPx = 3.0

    // Contact-trigger calibration

    const val triggerMarginFraction = 0.35
    const val triggerMinSeparationDb = 6.0
    const val triggerListenOnlyMarginDb = 6.0

    /** Port of `SLA.thresholdFromBackground` (sla_common.threshold_from_background); the reasoning lives there. */
    fun thresholdFromBackground(backgroundPeakDb: Double): Double =
        backgroundPeakDb + triggerListenOnlyMarginDb

    /** Port of `SLA.suggestTriggerDb` (sla_common.suggest_trigger_db); the reasoning lives there. */
    fun suggestTriggerDb(backgroundPeakDb: Double, quietestHitDb: Double): TriggerDbSuggestion {
        val separation = quietestHitDb - backgroundPeakDb
        var threshold = backgroundPeakDb + triggerMarginFraction * separation
        threshold = swiftMax(threshold, backgroundPeakDb + 1.0)

        val verdict = if (separation < triggerMinSeparationDb) {
            TriggerCalibrationVerdict.unusable
        } else if (separation < 2 * triggerMinSeparationDb) {
            TriggerCalibrationVerdict.marginal
        } else {
            TriggerCalibrationVerdict.good
        }
        return TriggerDbSuggestion(threshold, separation, verdict)
    }

    // Body pose

    const val jointConfidenceMin = 0.30
    const val headDriftImplausibleM = 0.40
    const val tiltCorrectableMaxDeg = 20.0

    // Capture defaults

    const val targetFPS = 240.0
    const val targetWidth = 1920
    const val targetHeight = 1080
    const val preRollS = 1.50
    const val postRollS = 1.40
    const val maxPreRollS = 3.0
    const val triggerDb = 36.0
    const val triggerHighPassHz = 6000.0
    const val triggerHighPassOrder = 4
    const val retriggerMarginDb = 6.0

    // Bat / contact quality (Phase 3+)

    const val smashPoorBelow = 1.20
    const val smashGoodLo = 1.35
    const val smashGoodHi = 1.45

    const val slowpitchLaunchLo = 10.0
    const val slowpitchLaunchHi = 25.0

    /** Port of `SLA.batSpeedMps` (sla_common.bat_speed_mps); the reasoning lives there. */
    fun batSpeedMps(vxPxS: Double, vyPxS: Double, scaleMPerPx: Double): Double =
        sqrt(vxPxS * vxPxS + vyPxS * vyPxS) * scaleMPerPx

    /** Port of `SLA.smashFactor` (sla_common.smash_factor); the reasoning lives there. */
    fun smashFactor(exitVeloMps: Double, batSpeedMps: Double): Double? =
        if (batSpeedMps <= 0) null else exitVeloMps / batSpeedMps

    /** Port of `SLA.inSlowpitchLaunchWindow` (sla_common.in_slowpitch_launch_window); the reasoning lives there. */
    fun inSlowpitchLaunchWindow(launchAngleDeg: Double): Boolean =
        launchAngleDeg >= slowpitchLaunchLo && launchAngleDeg <= slowpitchLaunchHi

    // Contact offset ("undercut")

    const val batBarrelDiameterM = 2.25 * 0.0254
    const val contactPlausibleM = (ballDiameterM + batBarrelDiameterM) / 2

    const val undercutToppedBelowM = -0.006
    const val undercutCenteredMaxM = 0.010
    const val undercutCarryMaxM = 0.030

    /** Port of `SLA.undercutM` (sla_common.undercut_m); the reasoning lives there. */
    fun undercutM(ballY0Px: Double, batY0Px: Double, scaleMPerPx: Double): Double =
        (batY0Px - ballY0Px) * scaleMPerPx
}

/** The unnamed `(thresholdDb, separationDb, verdict)` tuple `SLA.suggestTriggerDb` returns. */
data class TriggerDbSuggestion(
    val thresholdDb: Double,
    val separationDb: Double,
    val verdict: TriggerCalibrationVerdict,
)

/** Port of `SLAConstants.swift` `ContactQuality` (sla_common.contact_quality); the reasoning lives there. */
enum class ContactQuality(val raw: String) {
    unknown("unknown"),
    implausible("implausible"),
    topped("topped"),
    centered("centered"),
    underCarry("under_carry"),
    underPopup("under_popup");

    val label: String
        get() = when (this) {
            unknown -> "—"
            implausible -> "Not readable"
            topped -> "Over the ball"
            centered -> "Centered"
            underCarry -> "Under it — carry"
            underPopup -> "Way under it"
        }

    companion object {
        fun fromRaw(raw: String): ContactQuality? = entries.firstOrNull { it.raw == raw }

        /** Swift's `ContactQuality(undercutM:)`, so call sites read the same. */
        operator fun invoke(undercutM: Double?): ContactQuality {
            val u = undercutM ?: return unknown
            return if (abs(u) > SLA.contactPlausibleM) implausible
            else if (u < SLA.undercutToppedBelowM) topped
            else if (u <= SLA.undercutCenteredMaxM) centered
            else if (u <= SLA.undercutCarryMaxM) underCarry
            else underPopup
        }
    }
}

/** Port of `SLAConstants.swift` `SmashQuality` (sla_common.smash_quality); the reasoning lives there. */
enum class SmashQuality(val raw: String) {
    unknown("unknown"),
    poor("poor"),
    fair("fair"),
    flush("flush");

    val label: String
        get() = when (this) {
            unknown -> "—"
            poor -> "Poor contact"
            fair -> "Fair contact"
            flush -> "Flush"
        }

    companion object {
        fun fromRaw(raw: String): SmashQuality? = entries.firstOrNull { it.raw == raw }

        /** Swift's `SmashQuality(smash:)`, so call sites read the same. */
        operator fun invoke(smash: Double?): SmashQuality {
            val s = smash ?: return unknown
            return if (s < SLA.smashPoorBelow) poor
            else if (s < SLA.smashGoodLo) fair
            else flush
        }
    }
}

/** Port of `SLAConstants.swift` `HSVBounds` (OpenCV HSV: H 0-179, S/V 0-255); the reasoning lives there. */
data class HSVBounds(
    var h: Double,
    var s: Double,
    var v: Double,
)

/** Port of `SLAConstants.swift` `SwingFlag` (the sla_common.FLAG_* strings); the reasoning lives there. */
enum class SwingFlag(val raw: String) {
    shortTrack("SHORT_TRACK"),
    noGravityCheck("NO_GRAVITY_CHECK"),
    scaleDisagree("SCALE_DISAGREE"),
    depthMotion("DEPTH_MOTION"),
    highResidual("HIGH_RESIDUAL"),
    contactTimeRejected("CONTACT_TIME_REJECTED");

    val explanation: String
        get() = when (this) {
            shortTrack ->
                "The ball was only tracked for a handful of frames. Numbers are a rough estimate."
            noGravityCheck ->
                "Flight was too brief to cross-check scale against gravity. Exit velocity rests on ball size alone."
            scaleDisagree ->
                "The two independent scale estimates disagree. Something is off — check camera distance and that the ball is in focus."
            depthMotion ->
                "The ball changed size through the track, so it flew toward or away from the camera. Stand more square to the line of play."
            highResidual ->
                "The tracked path was jittery. Likely a busy background or a partly hidden ball."
            contactTimeRejected ->
                "The trigger fired well before the ball was seen leaving the bat, so it heard something other than this hit. Contact has been taken as the first frame of the flight instead, which costs a few frames of accuracy — but it also means the bat panel is missing and the trigger is picking up something at this venue. Settings → Trigger → Calibrate."
        }

    companion object {
        fun fromRaw(raw: String): SwingFlag? = entries.firstOrNull { it.raw == raw }
    }
}

/** Port of `SLAConstants.swift` `TriggerCalibrationVerdict` (sla_common.TRIGGER_CAL_*); the reasoning lives there. */
enum class TriggerCalibrationVerdict(val raw: String) {
    good("good"),
    marginal("marginal"),
    unusable("unusable");

    val label: String
        get() = when (this) {
            good -> "Clear"
            marginal -> "Workable"
            unusable -> "Too noisy"
        }

    val advice: String
        get() = when (this) {
            good ->
                "Contact stands well clear of the background here. The trigger should be reliable."
            marginal ->
                "Contact is only just above the background. Expect the odd missed swing or false start — keep an eye on the ignored count."
            unusable ->
                "Contact is not louder than this venue's own noise, so no threshold can separate them. Use the manual button, or move somewhere quieter. Turning the threshold down would only fire on everything."
        }

    companion object {
        fun fromRaw(raw: String): TriggerCalibrationVerdict? = entries.firstOrNull { it.raw == raw }
    }
}
