// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Port of the pure maths of `Wizard/LevelSensor.swift` (`tiltDown`,
 * `rollOffSquare`); the reasoning lives there. The stateful half — the motion
 * subscription, smoothing, latch and zero — is sensor plumbing and belongs to
 * the app layer, which feeds this from `SensorManager` through
 * [gravityFromAndroid].
 *
 * Sign conventions, the Swift's and therefore what `TiltRectifier`,
 * `CameraPose` and `SwingAnalyzer` expect:
 *  - tilt is positive when the REAR LENS AIMS DOWN;
 *  - roll is positive when the phone is turned CLOCKWISE as seen by someone
 *    looking at its screen (the horizon then rises to the right in the
 *    picture, and `analyze_track` rotates the velocity clockwise to undo it).
 */
object LevelSensor {

    /**
     * Kotlin-only stand-in for CoreMotion's `CMDeviceMotion.gravity`, which is
     * what the Swift maths reads: a unit vector, in g, pointing DOWN, in device
     * axes (x to the right and y to the top edge with the phone in portrait, z
     * out of the screen). Flat on a table screen up it is (0, 0, -1).
     */
    data class Gravity(val x: Double, val y: Double, val z: Double)

    /** Port of `LevelSensor.tiltDown(gravityZ:)`; the reasoning lives there. */
    fun tiltDown(gravityZ: Double): Double =
        -asin(swiftMax(-1.0, swiftMin(1.0, gravityZ))) * 180 / PI

    /**
     * Port of `LevelSensor.rollOffSquare(portraitDeg:)`; the reasoning lives
     * there. Swift's half-away-from-zero `rounded()`, not Kotlin's half-even
     * `round`: ±45° is an exact tie, and the two disagree on which way it folds.
     */
    fun rollOffSquare(portraitDeg: Double): Double =
        portraitDeg - (portraitDeg / 90).rounded() * 90

    /**
     * Kotlin-only: gravity's angle in the screen plane, zero when the phone is
     * upright in portrait — the `portraitRoll` the Swift computes inline in
     * `start()`, lifted out so the app's sensor listener calls the same line the
     * tests pin instead of retyping it.
     */
    fun portraitRollDeg(gravity: Gravity): Double =
        atan2(gravity.x, -gravity.y) * 180 / PI

    /**
     * Kotlin-only: Android's gravity reading in the convention [tiltDown] and
     * [portraitRollDeg] were written for.
     *
     * `SensorManager`'s device axes are CoreMotion's (x right, y to the top
     * edge in the natural portrait orientation, z out of the screen) — never
     * remapped for the display's rotation, and [rollOffSquare] needs no remap,
     * because it does not care which quarter turn the phone is in. The SIGN is
     * the opposite: `TYPE_GRAVITY` and `TYPE_ACCELEROMETER` report the force
     * holding the phone up, so a phone lying screen up reads about +9.81 on z
     * where CoreMotion reads -1. Fed in unnegated, that phone's lens would read
     * as aimed at the sky, every tilt correction would run backwards, and
     * nothing on screen would look wrong.
     *
     * Normalised by the reading's own length rather than by standard gravity:
     * CoreMotion's gravity is a unit vector, and an accelerometer whose scale is
     * a percent or two off would otherwise move every tilt by that fraction of
     * its sine. `null` for a reading with no direction (zero or non-finite) —
     * "no reading" must not look like "level", which is the mistake the Swift's
     * `hasReading` exists to prevent.
     */
    fun gravityFromAndroid(x: Double, y: Double, z: Double): Gravity? {
        val n = sqrt(x * x + y * y + z * z)
        if (!(n > 0) || !n.isFinite()) return null
        return Gravity(-x / n, -y / n, -z / n)
    }
}
