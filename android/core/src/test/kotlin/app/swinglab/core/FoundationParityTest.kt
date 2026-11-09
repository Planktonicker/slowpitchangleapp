// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Port of the `app/Tests/ParityTests.swift` cases whose functions live in the
 * foundation files (SLAConstants, Geometry, FlightModel, TiltRectifier), against
 * the same `parity.json`. Method names mirror the Swift `testXxx` names.
 *
 * Where a Swift test also exercises a type another slice owns (TrackBuilder,
 * MotionMask, BallDetector), only its constant assertions are ported here, in a
 * method named `...Constants...`; the case loop belongs to that slice.
 */
class FoundationParityTest {

    private val constants get() = Fixtures.constants

    /** The Swift test's own `assertClose` defaults: rel 1e-6, abs 1e-9. */
    private fun close(actual: Double, expected: Double, label: String,
                      rel: Double = 1e-6, abs: Double = 1e-9) =
        assertClose(actual, expected, label, abs = abs, rel = rel)

    /** `XCTAssertEqual(value, constants[key]!, accuracy:)`. */
    private fun constantWithin(value: Double, key: String, accuracy: Double = 1e-12) =
        assertEquals(Fixtures.constant(key), value, accuracy, key)

    private fun JsonObject.observation() = BallObservation(
        frame = i("frame"), t = d("t"), x = d("x"), y = d("y"),
        diameterPx = d("diameter_px"), areaPx = d("area_px"),
    )

    // Constants

    /** Constant half of `testSeededTrackingMatchesReference`; the case loop is TrackBuilder's. */
    @Test
    fun seededTrackingConstantsMatchReference() {
        for ((key, value) in listOf(
            "SEED_SEARCH_RADIUS_PX" to SLA.seedSearchRadiusPx,
            "SEED_SEARCH_RADIUS_FRAC" to SLA.seedSearchRadiusFrac,
            "SEED_GATE_BASE_PX" to SLA.seedGateBasePx,
            "SEED_GATE_PREDICTED_PX" to SLA.seedGatePredictedPx,
            "SEED_GATE_SPEED_MULT" to SLA.seedGateSpeedMult,
            "SEED_MAX_COAST_FRAMES" to SLA.seedMaxCoastFrames.toDouble(),
            "SEED_SPEED_RATIO_MAX" to SLA.seedSpeedRatioMax,
            "SEED_MAX_TURN_DEG" to SLA.seedMaxTurnDeg,
            "SEED_OUTLIER_MIN_PX" to SLA.seedOutlierMinPx,
            "SEED_OUTLIER_SIGMA" to SLA.seedOutlierSigma,
        )) {
            constantWithin(value, key)
        }
    }

    /** Constant half of `testStitchTracksMatchesReference`; the case loop is TrackBuilder's. */
    @Test
    fun stitchTracksConstantsMatchReference() {
        constantWithin(SLA.stitchMaxGapS, "STITCH_MAX_GAP_S")
        constantWithin(SLA.stitchBaseTolPx, "STITCH_BASE_TOL_PX")
        constantWithin(SLA.stitchTolPxPerS, "STITCH_TOL_PX_PER_S")
        constantWithin(SLA.stitchAccelK, "STITCH_ACCEL_K")
        constantWithin(SLA.stitchVelocityNoisePxS, "STITCH_VELOCITY_NOISE_PX_S")
        constantWithin(SLA.stitchMaxAngleDeg, "STITCH_MAX_ANGLE_DEG")
        constantWithin(SLA.stitchVelocityWindow.toDouble(), "STITCH_VELOCITY_WINDOW")
    }

    /** Constant half of `testTrackBuildingMatchesReference`; the case loop is TrackBuilder's. */
    @Test
    fun trackBuildingConstantsMatchReference() {
        constantWithin(SLA.buildMaxTurnDeg, "BUILD_MAX_TURN_DEG")
        constantWithin(SLA.buildTurnMinStepPx, "BUILD_TURN_MIN_STEP_PX")
        constantWithin(SLA.buildHeadingWindow.toDouble(), "BUILD_HEADING_WINDOW")
    }

    /** Constant half of `testSelectionUsesContactTime`; the selection itself is TrackBuilder's. */
    @Test
    fun selectionUsesContactTimeConstantsMatchReference() {
        constantWithin(SLA.selectContactTolS, "SELECT_CONTACT_TOL_S")
    }

    /** Constant half of `testMotionMaskMatchesReference`; the case loop is MotionMask's. */
    @Test
    fun motionMaskConstantsMatchReference() {
        close(SLA.motionDiffThreshold, constants.d("MOTION_DIFF_THRESHOLD"), "motion threshold")
        close(SLA.motionDilatePx, constants.d("MOTION_DILATE_PX"), "motion dilate")
    }

    /** Constant half of `testSubpixelDiameterMatchesReference`; the case loop is BallDetector's. */
    @Test
    fun subpixelDiameterConstantsMatchReference() {
        close(SLA.diameterProbeDirections.toDouble(), constants.d("DIAMETER_PROBE_DIRECTIONS"), "probe directions")
        close(SLA.diameterBgInner, constants.d("DIAMETER_BG_INNER"), "bg inner")
        close(SLA.diameterBgOuter, constants.d("DIAMETER_BG_OUTER"), "bg outer")
        close(SLA.diameterBgPadPx, constants.d("DIAMETER_BG_PAD_PX"), "bg pad")
    }

    @Test
    fun constantsMatchReference() {
        val c = constants
        close(SLA.g, c.d("G"), "G")
        close(SLA.ballCircumferenceM, c.d("BALL_CIRCUMFERENCE_M"), "ball circumference")
        close(SLA.ballDiameterM, c.d("BALL_DIAMETER_M"), "ball diameter")
        close(SLA.ballMassKg, c.d("BALL_MASS_KG"), "ball mass")
        close(SLA.airDensity, c.d("AIR_DENSITY"), "air density")
        close(SLA.dragCd, c.d("DRAG_CD"), "drag Cd")
        close(SLA.mphPerMps, c.d("MPH_PER_MPS"), "mph per m/s")
        close(SLA.velocityWindowS, c.d("VELOCITY_WINDOW_S"), "velocity window")
        close(SLA.gravityWindowS, c.d("GRAVITY_WINDOW_S"), "gravity window")
        close(SLA.minGravityTrackS, c.d("MIN_GRAVITY_TRACK_S"), "min gravity track")
        close(SLA.scaleDisagreeTol, c.d("SCALE_DISAGREE_TOL"), "scale disagree tol")
        close(SLA.diameterDriftTol, c.d("DIAMETER_DRIFT_TOL"), "diameter drift tol")
        close(SLA.residualTolPx, c.d("RESIDUAL_TOL_PX"), "residual tol")
        close(SLA.diameterProfileStepPx, c.d("DIAMETER_PROFILE_STEP_PX"), "profile step")
        assertEquals(c.d("MIN_TRACK_FRAMES").toInt(), SLA.minTrackFrames)
        assertEquals(c.d("NEAR_CONTACT_MIN_FRAMES").toInt(), SLA.nearContactMinFrames)
        close(SLA.selectContactLateS, c.d("SELECT_CONTACT_LATE_S"), "contact late bound")

        close(SLA.kOverM, c.d("k_over_m"), "k/m", rel = 1e-12)

        close(SLA.hsvLoDefault.h, c.d("HSV_LO_H"), "hsv lo H")
        close(SLA.hsvLoDefault.s, c.d("HSV_LO_S"), "hsv lo S")
        close(SLA.hsvLoDefault.v, c.d("HSV_LO_V"), "hsv lo V")
        close(SLA.hsvHiDefault.h, c.d("HSV_HI_H"), "hsv hi H")
        close(SLA.hsvHiDefault.s, c.d("HSV_HI_S"), "hsv hi S")
        close(SLA.hsvHiDefault.v, c.d("HSV_HI_V"), "hsv hi V")
        close(SLA.minRadiusPxDefault, c.d("MIN_RADIUS_PX_DEFAULT"), "min radius")
        close(SLA.trackStraightnessMin, c.d("TRACK_STRAIGHTNESS_MIN"), "track straightness min")
        close(SLA.maxRadiusPxDefault, c.d("MAX_RADIUS_PX_DEFAULT"), "max radius")

        close(SLA.smashPoorBelow, c.d("SMASH_POOR_BELOW"), "smash poor")
        close(SLA.smashGoodLo, c.d("SMASH_GOOD_LO"), "smash good lo")
        close(SLA.smashGoodHi, c.d("SMASH_GOOD_HI"), "smash good hi")
        close(SLA.slowpitchLaunchLo, c.d("SLOWPITCH_LAUNCH_LO"), "slow-pitch launch lo")
        close(SLA.slowpitchLaunchHi, c.d("SLOWPITCH_LAUNCH_HI"), "slow-pitch launch hi")
    }

    @Test
    fun contactTimeFromAudioMatchesReference() {
        close(SLA.speedOfSoundMps, constants.d("SPEED_OF_SOUND_MPS"), "speed of sound")
        close(SLA.contactAudioMaxDistanceM, constants.d("CONTACT_AUDIO_MAX_DISTANCE_M"), "max distance")
        close(SLA.contactMaxBackExtrapolationS, constants.d("CONTACT_MAX_BACK_EXTRAPOLATION_S"),
            "max back-extrapolation")

        val cases = Fixtures.block("contact_from_audio")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            close(SLA.contactTimeFromAudio(audioT = c.d("audio_t"), distanceM = c.dOrNull("distance_m")),
                c.d("expected"), "contact from audio ${c.s("name")}")
        }

        val corrected = SLA.contactTimeFromAudio(audioT = 0.781, distanceM = 4.6)
        assertTrue(corrected >= 0.7667, "earlier than the pitch's last frame")
        assertTrue(corrected <= 0.7708, "later than the hit's first frame")
    }

    @Test
    fun listenOnlyThresholdMatchesReference() {
        close(SLA.triggerListenOnlyMarginDb, constants.d("TRIGGER_LISTEN_ONLY_MARGIN_DB"), "listen-only margin")
        val cases = Fixtures.block("listen_only_threshold")
        assertFalse(cases.isEmpty())
        for (c in cases) {
            close(SLA.thresholdFromBackground(backgroundPeakDb = c.d("background_peak_db")),
                c.d("expected_threshold_db"), "listen-only from ${c.d("background_peak_db")} dB")
        }
    }

    @Test
    fun listeningAloneAgreesWithThreeHitsOnTheCorpusVenue() {
        val listenOnly = SLA.thresholdFromBackground(backgroundPeakDb = 30.1)
        val withHits = SLA.suggestTriggerDb(backgroundPeakDb = 30.1, quietestHitDb = 45.7)
        assertEquals(withHits.thresholdDb, listenOnly, 1.0)
        assertEquals(TriggerCalibrationVerdict.good, withHits.verdict, "15.6 dB of room is a usable venue")
        assertTrue(SLA.triggerDb >= 32)
        assertTrue(SLA.triggerDb <= 36)
    }

    // Least squares

    @Test
    fun fitQuadraticMatchesNumPy() {
        for (c in Fixtures.block("fit_quadratic")) {
            val name = c.s("name")
            val fit = Geometry.fitQuadratic(ts = c.arr("ts").doubles(), vs = c.arr("vs").doubles())
            close(fit.a, c.d("a"), "$name a", rel = 1e-6, abs = 1e-9)
            close(fit.b, c.d("b"), "$name b", rel = 1e-6, abs = 1e-9)
            close(fit.c, c.d("c"), "$name c", rel = 1e-6, abs = 1e-9)
            close(fit.rms, c.d("rms"), "$name rms", rel = 1e-6, abs = 1e-9)
        }
    }

    // Drag-aware scale (finding #1)

    @Test
    fun solveGravityScaleMatchesReference() {
        for (c in Fixtures.block("solve_gravity_scale")) {
            val name = c.s("name")
            val got = Geometry.solveGravityScale(
                ayPx = c.d("ay_px"),
                vxPxMid = c.d("vx_px_mid"),
                vyPxMid = c.d("vy_px_mid"),
                scaleHint = c.dOrNull("scale_hint"),
            )
            val expected = c.dOrNull("expected")
            when {
                got == null && expected == null -> {}
                got != null && expected != null -> close(got, expected, name, rel = 1e-9)
                else -> fail("$name: Kotlin $got vs Python $expected")
            }
        }
    }

    @Test
    fun naiveGravityScaleIsMateriallyWrong() {
        val c = Fixtures.block("solve_gravity_scale").firstOrNull { it.s("name") == "rising_two_roots" }
            ?: fail("missing the rising_two_roots fixture")
        val expected = c.dOrNull("expected") ?: fail("missing the rising_two_roots fixture")
        val naive = SLA.g / c.d("ay_px")
        val error = abs(naive - expected) / expected
        assertTrue(error > 0.20,
            "Naive g/ay is only ${error * 100}% off here; the fixture no longer demonstrates why the drag-aware solve is needed.")
    }

    // Full analysis (flag coverage only; analyze_track itself is SwingAnalyzer's)

    @Test
    fun fixturesCoverEveryFlag() {
        val seen = Fixtures.block("analyze_track")
            .flatMap { it.obj("expected").arr("flags").map { f -> f.jsonPrimitive.content } }
            .toSet()
        for (flag in SwingFlag.entries) {
            assertTrue(flag.raw in seen, "no parity fixture produces ${flag.raw}")
        }
    }

    // Flight model

    @Test
    fun simulateFlightMatchesReference() {
        for (c in Fixtures.block("simulate_flight")) {
            val name = c.s("name")
            val f = FlightModel.simulate(
                evMps = c.d("ev_mps"),
                laDeg = c.d("la_deg"),
                contactHeightM = c.d("contact_height_m"),
            )
            close(f.carryM, c.d("carry_m"), "$name carry", rel = 1e-9)
            close(f.hangS, c.d("hang_s"), "$name hang", rel = 1e-9)
            close(f.apexM, c.d("apex_m"), "$name apex", rel = 1e-9)
        }
    }

    @Test
    fun vy0FromHangTimeMatchesReference() {
        for (c in Fixtures.block("vy0_from_hang_time")) {
            close(FlightModel.vy0FromHangTime(c.d("hang_s")), c.d("expected"),
                "vy0(${c.d("hang_s")})", rel = 1e-12)
        }
    }

    // Bat speed + smash factor

    @Test
    fun batMetricsMatchReference() {
        for (c in Fixtures.block("bat_metrics")) {
            val name = c.s("name")
            val bs = SLA.batSpeedMps(vxPxS = c.d("vx_px_s"), vyPxS = c.d("vy_px_s"),
                scaleMPerPx = c.d("scale_m_per_px"))
            close(bs, c.d("bat_speed_mps"), "$name bat speed m/s", rel = 1e-9)
            close(bs * SLA.mphPerMps, c.d("bat_speed_mph"), "$name bat speed mph", rel = 1e-9)

            val smash = SLA.smashFactor(exitVeloMps = c.d("exit_velo_mps"), batSpeedMps = bs)
            val expected = c.dOrNull("smash_factor")
            when {
                smash == null && expected == null -> {}
                smash != null && expected != null -> close(smash, expected, "$name smash", rel = 1e-9)
                else -> fail("$name: smash presence differs")
            }

            assertEquals(c.s("smash_quality"), SmashQuality(smash = smash).raw, "$name smash quality")
        }
    }

    // Contact offset / undercut

    @Test
    fun contactOffsetMatchesReference() {
        for (c in Fixtures.block("contact_offset")) {
            val name = c.s("name")
            val u = SLA.undercutM(ballY0Px = c.d("ball_y0_px"), batY0Px = c.d("bat_y0_px"),
                scaleMPerPx = c.d("scale_m_per_px"))
            close(u, c.d("undercut_m"), "$name undercut m", rel = 1e-9)
            close(u * 1000, c.d("undercut_mm"), "$name undercut mm", rel = 1e-9)
            assertEquals(c.s("quality"), ContactQuality(undercutM = u).raw, "$name quality")
        }
        assertEquals(ContactQuality.unknown, ContactQuality(undercutM = null))
    }

    // Camera tilt rectification

    @Test
    fun focalFromFOVMatchesReference() {
        for (c in Fixtures.block("focal_px_from_fov")) {
            val f = TiltRectifier.focalPx(widthPx = c.d("width_px"), fovDeg = c.d("fov_deg"))
            close(f, c.d("expected"), "${c.s("name")} focal px", rel = 1e-9)
        }
    }

    @Test
    fun tiltRectificationMatchesReference() {
        for (c in Fixtures.block("rectify_tilt")) {
            val name = c.s("name")
            val r = TiltRectifier.rectify(x = c.d("x"), y = c.d("y"), tiltDeg = c.d("tilt_deg"),
                focalPx = c.d("focal_px"), cx = c.d("cx"), cy = c.d("cy"))
            close(r.x, c.d("expected_x"), "$name x", rel = 1e-9)
            close(r.y, c.d("expected_y"), "$name y", rel = 1e-9)
            close(r.magnification, c.d("expected_magnification"), "$name magnification", rel = 1e-9)
            close(c.d("diameter_px") * r.magnification, c.d("expected_diameter_px"),
                "$name diameter", rel = 1e-9)
        }
    }

    @Test
    fun tiltRectificationOfATrackIsIdentityAtZeroTilt() {
        val track = Fixtures.block("analyze_track")[0].arr("track").map { it.jsonObject.observation() }
        val same = TiltRectifier.rectify(track = track, tiltDeg = 0.0,
            focalPx = 1662.77, cx = 960.0, cy = 540.0)
        assertEquals(track, same)
        val noOptics = TiltRectifier.rectify(track = track, tiltDeg = 8.0,
            focalPx = 0.0, cx = 960.0, cy = 540.0)
        assertEquals(track, noOptics)

        val warped = TiltRectifier.rectify(track = track, tiltDeg = 8.0,
            focalPx = 1662.77, cx = 960.0, cy = 540.0)
        assertEquals(track.size, warped.size)
        for ((a, b) in track.zip(warped)) {
            val r = TiltRectifier.rectify(x = a.x, y = a.y, tiltDeg = 8.0,
                focalPx = 1662.77, cx = 960.0, cy = 540.0)
            close(b.x, r.x, "track x", rel = 1e-12)
            close(b.y, r.y, "track y", rel = 1e-12)
            close(b.diameterPx, a.diameterPx * r.magnification, "track diameter", rel = 1e-12)
            assertEquals(a.t, b.t)
            assertEquals(a.frame, b.frame)
        }
    }

    @Test
    fun tiltRectificationInvertsAForwardProjection() {
        val f = 1662.77; val cx = 960.0; val cy = 540.0
        val tilt = 11.0
        val t = tilt * PI / 180
        for ((lx, ly) in listOf(200.0 to 150.0, 960.0 to 540.0, 1500.0 to 820.0, 700.0 to 960.0)) {
            val u = lx - cx; val v = ly - cy
            val d = f * cos(t) + v * sin(t)
            val tiltedX = cx + f * u / d
            val tiltedY = cy + f * (v * cos(t) - f * sin(t)) / d

            val back = TiltRectifier.rectify(x = tiltedX, y = tiltedY,
                tiltDeg = tilt, focalPx = f, cx = cx, cy = cy)
            close(back.x, lx, "round trip x", rel = 1e-9, abs = 1e-7)
            close(back.y, ly, "round trip y", rel = 1e-9, abs = 1e-7)
        }
    }

    // Trigger calibration

    @Test
    fun triggerCalibrationMatchesReference() {
        for (c in Fixtures.block("trigger_calibration")) {
            val name = c.s("name")
            val r = SLA.suggestTriggerDb(backgroundPeakDb = c.d("background_peak_db"),
                quietestHitDb = c.d("quietest_hit_db"))
            close(r.thresholdDb, c.d("expected_threshold_db"), "$name threshold", rel = 1e-9)
            close(r.separationDb, c.d("expected_separation_db"), "$name separation", rel = 1e-9)
            assertEquals(c.s("expected_verdict"), r.verdict.raw, "$name verdict")
            assertTrue(r.thresholdDb > c.d("background_peak_db"),
                "$name: threshold must clear the background")
        }
    }

    @Test
    fun triggerCalibrationConstantsMatchReference() {
        val c = constants
        close(SLA.triggerMarginFraction, c.d("TRIGGER_MARGIN_FRACTION"), "margin fraction")
        close(SLA.triggerMinSeparationDb, c.d("TRIGGER_MIN_SEPARATION_DB"), "min separation")
    }

    @Test
    fun bodyConstantsMatchReference() {
        val c = constants
        close(SLA.jointConfidenceMin, c.d("JOINT_CONFIDENCE_MIN"), "joint confidence")
        close(SLA.headDriftImplausibleM, c.d("HEAD_DRIFT_IMPLAUSIBLE_M"), "head drift limit")
    }

    @Test
    fun contactConstantsMatchReference() {
        val c = constants
        close(SLA.batBarrelDiameterM, c.d("BAT_BARREL_DIAMETER_M"), "barrel diameter")
        close(SLA.contactPlausibleM, c.d("CONTACT_PLAUSIBLE_M"), "plausibility limit")
        close(SLA.undercutToppedBelowM, c.d("UNDERCUT_TOPPED_BELOW_M"), "topped band")
        close(SLA.undercutCenteredMaxM, c.d("UNDERCUT_CENTERED_MAX_M"), "centered band")
        close(SLA.undercutCarryMaxM, c.d("UNDERCUT_CARRY_MAX_M"), "carry band")
        close(SLA.tiltCorrectableMaxDeg, c.d("TILT_CORRECTABLE_MAX_DEG"), "tilt correctable limit")
    }
}
