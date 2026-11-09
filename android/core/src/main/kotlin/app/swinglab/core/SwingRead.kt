// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.math.abs

/**
 * Port of `SwingRead.swift` `enum SwingRead` (turning the measurements into
 * sentences); the reasoning lives there. Nothing is scored against a
 * population, and a missing number produces no sentence.
 */
object SwingRead {

    // Contact

    /** Port of `SwingRead.Contact`. */
    data class Contact(
        val headline: String,
        val why: String,
        val tryThis: String?,
    )

    /** Port of `SwingRead.contact(smash:quality:contactQuality:undercutMm:launchAngleDeg:)`. */
    fun contact(
        smash: Double?,
        quality: SmashQuality,
        contactQuality: ContactQuality,
        undercutMm: Double?,
        launchAngleDeg: Double,
    ): Contact? {
        if (smash == null && undercutMm == null) return null

        val inWindow = SLA.inSlowpitchLaunchWindow(launchAngleDeg)

        val headline: String
        var why: String
        val tryThis: String?

        // The Swift switches on the (quality, contactQuality) tuple; the arms
        // are tested in the same order.
        val c = contactQuality
        when {
            quality == SmashQuality.flush && c == ContactQuality.underCarry -> {
                headline = "Flush, and under the ball — the one that carries."
                why = "Most of the bat's speed reached the ball, and the barrel passed just below its centre, which is what puts backspin on it."
                tryThis = null
            }
            quality == SmashQuality.flush && c == ContactQuality.centered -> {
                headline = "Flush contact, straight through the middle."
                why = "Efficient collision, but the barrel went through the ball's centre rather than under it, so there is little backspin to hold it up."
                tryThis = if (inWindow) null else "Meeting it a centimetre or two lower turns this into carry without needing any more bat speed."
            }
            quality == SmashQuality.flush && c == ContactQuality.topped -> {
                headline = "Struck well, but over the top of it."
                why = "The speed was there — the barrel just arrived above the ball's centre, which drives it down."
                tryThis = "Same swing, barrel a touch lower through the zone."
            }
            quality == SmashQuality.flush && c == ContactQuality.underPopup -> {
                headline = "All the speed, most of it under the ball."
                why = "The barrel passed well below centre. That is where the energy goes into spin and height instead of distance."
                tryThis = "Same swing, meeting it higher on the ball."
            }
            quality == SmashQuality.poor -> {
                headline = "Not much of the bat's speed reached the ball."
                why = "Smash factor is the ratio of ball speed out to bat speed in. A low one means the collision was off the sweet spot, or off the end, or on the handle — the swing may have been fine."
                tryThis = "Worth checking where on the barrel it is actually hitting; the tape marks the sweet spot."
            }
            quality == SmashQuality.fair && c == ContactQuality.topped -> {
                headline = "Slightly over the ball, and not quite flush."
                why = "The barrel arrived above centre and off the middle of the sweet spot at the same time."
                tryThis = "Barrel a little lower through contact."
            }
            quality == SmashQuality.fair -> {
                headline = "Decent contact, not the best of it."
                why = "Some of the bat's speed went into the ball, but not the share a flush strike gives."
                tryThis = null
            }
            quality == SmashQuality.unknown && c != ContactQuality.unknown && c != ContactQuality.implausible -> {
                headline = c.label + "."
                why = "Where the barrel met the ball on the vertical. There is no bat speed for this swing, so how flush it was cannot be said."
                tryThis = null
            }
            else -> return null
        }

        if (undercutMm != null && contactQuality != ContactQuality.unknown &&
            contactQuality != ContactQuality.implausible) {
            val u = undercutMm
            why += " Barrel centre passed " + formatFixed(abs(u), 0) + " mm " +
                (if (u >= 0) "below" else "above") + " the ball centre."
        }
        if (smash != null) {
            why += " Smash factor " + formatFixed(smash, 2) + "."
        }
        return Contact(headline = headline, why = why, tryThis = tryThis)
    }

    // Body

    /** Port of `SwingRead.Note`. */
    data class Note(
        val title: String,
        val text: String,
        val isConvention: Boolean,
    ) {
        val id: String get() = title
    }

    /**
     * Port of `SwingRead.body(_:)`.
     *
     * Takes `BodyMetrics`' five measurement fields rather than a `BodyMetrics`,
     * because that type lives in PoseObservation.swift, which this module does
     * not define yet. Once it does, the Swift's signature is one line:
     * `fun body(m: BodyMetrics) = body(m.strideM, m.headDriftM, m.weightShiftM, m.frontKneeDeg, m.spineTiltDeg)`.
     */
    fun body(
        strideM: Double?,
        headDriftM: Double?,
        weightShiftM: Double?,
        frontKneeDeg: Double?,
        spineTiltDeg: Double?,
    ): List<Note> {
        val notes = mutableListOf<Note>()

        if (headDriftM != null) {
            val cm = headDriftM * 100
            if (cm > 15) {
                notes.add(Note(
                    title = "Head moved ${cm.rounded().toInt()} cm",
                    text = "That is the straight-line distance your head travelled between load and contact. A head that moves a long way is a moving pair of eyes, and the ball is the only thing in the swing you cannot afford to lose track of. Quieter is the usual coaching aim.",
                    isConvention = true))
            } else {
                notes.add(Note(
                    title = "Head stayed quiet — ${cm.rounded().toInt()} cm",
                    text = "Your head moved ${cm.rounded().toInt()} cm between load and contact. Keeping it still is what lets you track the ball all the way in.",
                    isConvention = false))
            }
        }

        if (frontKneeDeg != null) {
            val knee = frontKneeDeg
            val deg = knee.rounded().toInt()
            if (knee > 165) {
                notes.add(Note(
                    title = "Front leg straight at contact — $deg°",
                    text = "180° is a locked leg. A front leg that straightens into contact is what the hips rotate against, so this is usually a good sign rather than a fault.",
                    isConvention = true))
            } else if (knee < 130) {
                notes.add(Note(
                    title = "Front knee still bent — $deg°",
                    text = "The front leg was still collapsed at contact. Energy that would have gone into the ball goes into the leg instead. Hitting against a firmer front side is the usual fix.",
                    isConvention = true))
            } else {
                notes.add(Note(
                    title = "Front knee $deg° at contact",
                    text = "Part-way to straight. Watch whether this number climbs as the swing gets stronger.",
                    isConvention = false))
            }
        }

        if (strideM != null && weightShiftM != null) {
            notes.add(Note(
                title = "Stride ${(strideM * 100).rounded().toInt()} cm, hips moved ${(weightShiftM * 100).rounded().toInt()} cm",
                text = "The stride is how far the front foot travelled toward the pitcher; the second number is how far your hips actually went with it. A long stride the hips do not follow is a step, not a weight shift.",
                isConvention = true))
        } else if (strideM != null) {
            notes.add(Note(
                title = "Stride ${(strideM * 100).rounded().toInt()} cm",
                text = "How far the front foot travelled toward the pitcher between load and contact.",
                isConvention = false))
        }

        if (spineTiltDeg != null) {
            notes.add(Note(
                title = "Spine ${spineTiltDeg.rounded().toInt()}° from vertical at contact",
                text = "The lean of your hip-to-shoulder line. Some tilt away from the pitcher is what gets the barrel under the ball; a lot of it usually comes with dropping the back shoulder.",
                isConvention = true))
        }

        return notes
    }

    /** Port of `SwingRead.exportCaption(launchAngleDeg:exitVeloMph:smash:unit:)`. */
    fun exportCaption(
        launchAngleDeg: Double,
        exitVeloMph: Double,
        smash: Double?,
        unit: SpeedUnit = SpeedUnit.mph,
    ): String {
        val parts = mutableListOf(
            formatFixed(launchAngleDeg, 0, plusSign = true) + "°",
            "${unit.format(mph = exitVeloMph)} ${unit.suffix}",
        )
        if (smash != null) parts.add("smash " + formatFixed(smash, 2))
        return parts.joinToString("   ")
    }
}
