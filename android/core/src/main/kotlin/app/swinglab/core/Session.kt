// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.time.Instant
import java.util.UUID

/**
 * The fields of `SwingDTO` (Storage/SwingModels.swift) that Session.swift reads.
 *
 * Not in the Swift, which hands `Session` and `SessionSummary` the `SwingDTO`
 * itself. That record is the app layer's persistence type and is not part of
 * core, so the round logic — which is pure, and has a tie-break worth keeping
 * exact — is written against this, and the app's record implements it.
 */
interface SessionSwing {
    val sessionID: UUID?
    val capturedAt: Instant
    val setting: SwingSetting
    val launchAngleDeg: Double
    val exitVeloMph: Double
    val highConfidence: Boolean
}

/**
 * Port of `Session.swift` `struct Session` (one round of hitting, derived from
 * its swings rather than stored); the reasoning lives there. `Date` is
 * [Instant] and `TimeInterval` is seconds as a Double.
 *
 * `endedAt` is a `val` although the Swift's is a `var`: the Swift only ever
 * mutates a copy (`var closed = session; closed.endedAt = Date()`), which is
 * `copy(endedAt = ...)` here, and a Kotlin `var` would let that edit reach
 * every holder of the original.
 */
data class Session(
    val id: UUID = UUID.randomUUID(),
    val mode: SessionMode = SessionMode.live,
    val startedAt: Instant = Instant.now(),
    val endedAt: Instant? = null,
) {
    val isOpen: Boolean get() = endedAt == null

    val duration: Double get() = timeIntervalSince(endedAt ?: Instant.now(), startedAt)

    companion object {
        /** Port of `Session.derived(id:from:)`: a finished round rebuilt from the swings that carry its id. */
        fun derived(id: UUID, from: List<SessionSwing>): Session? {
            val mine = from.filter { it.sessionID == id }.sortedBy { it.capturedAt }
            val first = mine.firstOrNull() ?: return null
            val last = mine.last()
            return Session(id = id,
                           mode = dominantMode(mine),
                           startedAt = first.capturedAt,
                           endedAt = last.capturedAt)
        }

        /**
         * Port of `Session.allDerived(from:)`: every finished round, newest first.
         * Rounds that start at the same instant keep first-seen order, where the
         * Swift's `Set` leaves their order unspecified.
         */
        fun allDerived(from: List<SessionSwing>): List<Session> {
            val ids = from.mapNotNull { it.sessionID }.toSet()
            return ids.mapNotNull { derived(id = it, from = from) }
                .sortedByDescending { it.startedAt }
        }

        /** Port of `Session.dominantMode(of:)`: most common mode; a tie goes to the lower raw value. */
        private fun dominantMode(swings: List<SessionSwing>): SessionMode {
            val tally = LinkedHashMap<SessionMode, Int>()
            for (s in swings) {
                val m = SessionMode(setting = s.setting)
                tally[m] = (tally[m] ?: 0) + 1
            }
            return tally.entries.maxWithOrNull { a, b ->
                if (a.value != b.value) a.value.compareTo(b.value) else b.key.raw.compareTo(a.key.raw)
            }?.key ?: SessionMode.live
        }

        /** `Date.timeIntervalSince(_:)`, in seconds. */
        private fun timeIntervalSince(end: Instant, start: Instant): Double =
            (end.epochSecond - start.epochSecond).toDouble() + (end.nano - start.nano) / 1e9
    }
}

/** Port of `Session.swift` `enum SessionMode` (how the ball is being delivered); the reasoning lives there. */
enum class SessionMode(val raw: String) {
    live("live"),
    toss("toss"),
    tee("tee");

    val id: String get() = raw

    val title: String
        get() = when (this) {
            live -> "Live pitching"
            toss -> "Soft toss"
            tee -> "Tee"
        }

    val blurb: String
        get() = when (this) {
            live -> "Someone is pitching to you."
            toss -> "Someone is tossing the ball in."
            tee -> "The ball starts still."
        }

    /** The SF Symbol name the iOS start screen shows; kept so both apps name the same picture. */
    val symbol: String
        get() = when (this) {
            live -> "figure.baseball"
            toss -> "hand.raised"
            tee -> "cone"
        }

    /** Port of `SessionMode.swingSetting`. */
    val swingSetting: SwingSetting
        get() = when (this) {
            live -> SwingSetting.live
            toss -> SwingSetting.toss
            tee -> SwingSetting.tee
        }

    companion object {
        fun fromRaw(raw: String): SessionMode? = entries.firstOrNull { it.raw == raw }

        /** Swift's `SessionMode(setting:)`, so call sites read the same. */
        operator fun invoke(setting: SwingSetting): SessionMode = when (setting) {
            SwingSetting.tee, SwingSetting.teeid -> tee
            SwingSetting.toss -> toss
            SwingSetting.live, SwingSetting.cage, SwingSetting.net, SwingSetting.fly -> live
        }
    }
}

/**
 * Port of `Session.swift` `struct SessionSummary` (what a finished round comes
 * to: confident swings apart from flagged ones); the reasoning lives there.
 * Generic over the swing record for the reason given on [SessionSwing].
 */
data class SessionSummary<S : SessionSwing>(
    val session: Session,
    val confident: List<S>,
    val flagged: List<S>,
) {
    val id: UUID get() = session.id

    val total: Int get() = confident.size + flagged.size

    /** Swift's `Sequence.max()`, which skips a NaN after the first element where `maxOrNull()` would return it. */
    val bestExitVeloMph: Double?
        get() {
            val xs = confident.map { it.exitVeloMph }
            if (xs.isEmpty()) return null
            var result = xs[0]
            for (e in xs.drop(1)) if (result < e) result = e
            return result
        }

    val medianLaunchAngleDeg: Double?
        get() {
            val xs = confident.map { it.launchAngleDeg }
            if (xs.isEmpty()) return null
            return Geometry.median(xs)
        }

    val inLaunchWindow: Int
        get() = confident.count { SLA.inSlowpitchLaunchWindow(it.launchAngleDeg) }

    val isEmpty: Boolean get() = total == 0

    companion object {
        /** Port of `SessionSummary.build(session:swings:)`. */
        fun <S : SessionSwing> build(session: Session, swings: List<S>): SessionSummary<S> {
            val mine = swings
                .filter { it.sessionID == session.id }
                .sortedBy { it.capturedAt }
            return SessionSummary(session = session,
                                  confident = mine.filter { it.highConfidence },
                                  flagged = mine.filter { !it.highConfidence })
        }
    }
}
