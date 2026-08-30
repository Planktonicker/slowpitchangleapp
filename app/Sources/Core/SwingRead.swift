// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Turning the measurements into sentences.
///
/// Kept out of the views on purpose. This is where the app comes closest to
/// telling somebody what to do differently, which is exactly the material
/// `docs/BIOMECHANICS.md` is strictest about, so it should be readable and
/// testable in one place rather than assembled inline in three view builders.
///
/// Two rules hold throughout.
///
/// **Nothing is scored against a population.** There are no published
/// slow-pitch swing-kinematics norms. Where a direction is given it comes from
/// coaching convention or from physics, and it says which — never from a band
/// this app pretends to have measured. Smash factor is the one exception, and
/// it is a collision-efficiency ratio from the physics of the impact, not a
/// population statistic.
///
/// **A missing number produces no sentence.** Padding a read with "stride: not
/// available" teaches somebody to skim past the whole panel, and the panel is
/// where the withheld measurements are supposed to be conspicuous.
enum SwingRead {

    // MARK: - Contact

    struct Contact {
        /// One line. What happened at the collision.
        var headline: String
        /// Why the numbers say that.
        var why: String
        /// What to try, or nil when the reading does not support advice.
        var tryThis: String?
    }

    /// Why the contact was good or poor.
    ///
    /// The two readings answer different questions and are useless apart.
    /// Smash factor says how much of the bat's speed reached the ball —
    /// efficiency. Undercut says WHERE on the vertical the barrel met it, which
    /// is what sets launch angle and backspin. A ball can be struck flush and
    /// still be a ground ball, and the pair is what tells those apart.
    static func contact(smash: Double?,
                        quality: SmashQuality,
                        contactQuality: ContactQuality,
                        undercutMm: Double?,
                        launchAngleDeg: Double) -> Contact? {
        guard smash != nil || undercutMm != nil else { return nil }

        let inWindow = launchAngleDeg >= SLA.slowpitchLaunchLo
            && launchAngleDeg <= SLA.slowpitchLaunchHi

        var headline: String
        var why: String
        var tryThis: String?

        switch (quality, contactQuality) {
        case (.flush, .underCarry):
            headline = "Flush, and under the ball — the one that carries."
            why = "Most of the bat's speed reached the ball, and the barrel passed just below its centre, which is what puts backspin on it."
            tryThis = nil

        case (.flush, .centered):
            headline = "Flush contact, straight through the middle."
            why = "Efficient collision, but the barrel went through the ball's centre rather than under it, so there is little backspin to hold it up."
            tryThis = inWindow ? nil : "Meeting it a centimetre or two lower turns this into carry without needing any more bat speed."

        case (.flush, .topped):
            headline = "Struck well, but over the top of it."
            why = "The speed was there — the barrel just arrived above the ball's centre, which drives it down."
            tryThis = "Same swing, barrel a touch lower through the zone."

        case (.flush, .underPopup):
            headline = "All the speed, most of it under the ball."
            why = "The barrel passed well below centre. That is where the energy goes into spin and height instead of distance."
            tryThis = "Same swing, meeting it higher on the ball."

        case (.poor, _):
            headline = "Not much of the bat's speed reached the ball."
            why = "Smash factor is the ratio of ball speed out to bat speed in. A low one means the collision was off the sweet spot, or off the end, or on the handle — the swing may have been fine."
            tryThis = "Worth checking where on the barrel it is actually hitting; the tape marks the sweet spot."

        case (.fair, .topped):
            headline = "Slightly over the ball, and not quite flush."
            why = "The barrel arrived above centre and off the middle of the sweet spot at the same time."
            tryThis = "Barrel a little lower through contact."

        case (.fair, _):
            headline = "Decent contact, not the best of it."
            why = "Some of the bat's speed went into the ball, but not the share a flush strike gives."
            tryThis = nil

        case (.unknown, let c) where c != .unknown && c != .implausible:
            // Undercut without bat speed: the tape was tracked but the fit was
            // not confident enough for a speed. The vertical read still stands.
            headline = c.label + "."
            why = "Where the barrel met the ball on the vertical. There is no bat speed for this swing, so how flush it was cannot be said."
            tryThis = nil

        default:
            return nil
        }

        if let u = undercutMm, contactQuality != .unknown, contactQuality != .implausible {
            why += String(format: " Barrel centre passed %.0f mm %@ the ball centre.",
                          abs(u), u >= 0 ? "below" : "above")
        }
        if let s = smash {
            why += String(format: " Smash factor %.2f.", s)
        }
        return Contact(headline: headline, why: why, tryThis: tryThis)
    }

    // MARK: - Body

    struct Note: Identifiable {
        var id: String { title }
        var title: String
        var text: String
        /// True when the note is coaching convention rather than anything this
        /// app measured against a reference. The UI marks these so nobody reads
        /// a rule of thumb as a result.
        var isConvention: Bool
    }

    /// A plain-language read of the sagittal-plane numbers.
    ///
    /// Every note explains what the measurement IS before it suggests anything,
    /// because "stride 41 cm" means nothing on its own and a hitter cannot act
    /// on a number whose meaning they have to guess. Directions are hedged and
    /// labelled, because there is no slow-pitch population to compare against —
    /// what this panel is genuinely good for is watching your OWN numbers move.
    static func body(_ m: BodyMetrics) -> [Note] {
        var notes: [Note] = []

        if let head = m.headDriftM {
            let cm = head * 100
            if cm > 15 {
                notes.append(Note(
                    title: "Head moved \(Int(cm.rounded())) cm",
                    text: "That is the straight-line distance your head travelled between load and contact. A head that moves a long way is a moving pair of eyes, and the ball is the only thing in the swing you cannot afford to lose track of. Quieter is the usual coaching aim.",
                    isConvention: true))
            } else {
                notes.append(Note(
                    title: "Head stayed quiet — \(Int(cm.rounded())) cm",
                    text: "Your head moved \(Int(cm.rounded())) cm between load and contact. Keeping it still is what lets you track the ball all the way in.",
                    isConvention: false))
            }
        }

        if let knee = m.frontKneeDeg {
            let deg = Int(knee.rounded())
            if knee > 165 {
                notes.append(Note(
                    title: "Front leg straight at contact — \(deg)°",
                    text: "180° is a locked leg. A front leg that straightens into contact is what the hips rotate against, so this is usually a good sign rather than a fault.",
                    isConvention: true))
            } else if knee < 130 {
                notes.append(Note(
                    title: "Front knee still bent — \(deg)°",
                    text: "The front leg was still collapsed at contact. Energy that would have gone into the ball goes into the leg instead. Hitting against a firmer front side is the usual fix.",
                    isConvention: true))
            } else {
                notes.append(Note(
                    title: "Front knee \(deg)° at contact",
                    text: "Part-way to straight. Watch whether this number climbs as the swing gets stronger.",
                    isConvention: false))
            }
        }

        if let stride = m.strideM, let shift = m.weightShiftM {
            notes.append(Note(
                title: "Stride \(Int((stride * 100).rounded())) cm, hips moved \(Int((shift * 100).rounded())) cm",
                text: "The stride is how far the front foot travelled toward the pitcher; the second number is how far your hips actually went with it. A long stride the hips do not follow is a step, not a weight shift.",
                isConvention: true))
        } else if let stride = m.strideM {
            notes.append(Note(
                title: "Stride \(Int((stride * 100).rounded())) cm",
                text: "How far the front foot travelled toward the pitcher between load and contact.",
                isConvention: false))
        }

        if let tilt = m.spineTiltDeg {
            notes.append(Note(
                title: "Spine \(Int(tilt.rounded()))° from vertical at contact",
                text: "The lean of your hip-to-shoulder line. Some tilt away from the pitcher is what gets the barrel under the ball; a lot of it usually comes with dropping the back shoulder.",
                isConvention: true))
        }

        return notes
    }

    /// The caption burned into an exported clip. Short on purpose — it has to
    /// stay legible on a phone screen at a glance.
    static func exportCaption(launchAngleDeg: Double, exitVeloMph: Double,
                              smash: Double?) -> String {
        var parts = [String(format: "%+.0f°", launchAngleDeg),
                     String(format: "%.0f mph", exitVeloMph)]
        if let smash { parts.append(String(format: "smash %.2f", smash)) }
        return parts.joined(separator: "   ")
    }
}
