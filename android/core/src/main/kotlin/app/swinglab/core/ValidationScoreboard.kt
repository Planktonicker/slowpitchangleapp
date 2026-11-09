// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import java.util.UUID

/**
 * The fields of `SwingDTO` (Storage/SwingModels.swift) that
 * ValidationScoreboard.swift reads.
 *
 * Not in the Swift, which hands the scoreboard the `SwingDTO` itself. That
 * record is the app layer's persistence type and is not part of core, so the
 * gates — which are pure, and are the go/no-go decision VALIDATION.md asks
 * for — are written against this, and the app's record implements it, as it
 * does [SessionSwing].
 */
interface ScoreboardSwing {
    val id: UUID
    val setting: SwingSetting
    val clipFilename: String?
    val contactTime: Double
    val launchAngleDeg: Double
    val exitVeloMph: Double
    val exitVeloMps: Double
    val scaleBallMPerPx: Double
    val scaleGravityMPerPx: Double?
    val scaleDisagreement: Double?
    val diameterDrift: Double
    val trackedFrames: Int
    val trackDurationS: Double
    val fitRmsPx: Double
    val flags: List<SwingFlag>
    val autoTriggered: Boolean
    val hangS: Double?
    val carryM: Double?
    val captureFlags: List<CaptureFlag>

    /** Port of `SwingDTO.meetsG1`: G1 counts a clip as tracked at 12+ frames, matching `G1_MIN_FRAMES`. */
    val meetsG1: Boolean get() = trackedFrames >= 12
}

/**
 * Port of `ValidationScoreboard.swift` `struct ValidationScoreboard` (the
 * Phase 0 go/no-go scoreboard of docs/VALIDATION.md, computed on the device);
 * the reasoning lives there.
 */
data class ValidationScoreboard(
    val g1: List<G1Row> = emptyList(),
    val g2MedianPct: Double? = null,
    val g2Count: Int = 0,
    val g3: List<G3Row> = emptyList(),
    val g4EvSd: Double? = null,
    val g4LaSd: Double? = null,
    val g4Count: Int = 0,
    val g5AutoTriggered: Int = 0,
    val g5Total: Int = 0,
) {
    /** Port of `ValidationScoreboard.G1Row`. */
    data class G1Row(
        val setting: SwingSetting,
        val tracked: Int,
        val total: Int,
        val threshold: Double?,
    ) {
        val id: String get() = setting.raw
        val fraction: Double get() = if (total > 0) tracked.toDouble() / total.toDouble() else 0.0
        val passes: Boolean?
            get() {
                val t = threshold
                if (t == null || !(total > 0)) return null
                return fraction >= t
            }
    }

    /** Port of `ValidationScoreboard.G3Row`. */
    data class G3Row(
        val id: UUID,
        val label: String,
        val hangErrorPct: Double?,
        val carryErrorPct: Double?,
        val hangPasses: Boolean?,
        val carryPasses: Boolean?,
    )

    val g2Passes: Boolean? get() = g2MedianPct?.let { it <= SLA.scaleDisagreeTol * 100 }
    val g4EvPasses: Boolean? get() = g4EvSd?.let { it <= 3.0 }
    val g4LaPasses: Boolean? get() = g4LaSd?.let { it <= 3.0 }
    val g5Fraction: Double? get() = if (g5Total > 0) g5AutoTriggered.toDouble() / g5Total.toDouble() else null
    val g5Passes: Boolean? get() = g5Fraction?.let { it >= 0.90 }

    fun g1Passes(setting: SwingSetting): Boolean? = g1.firstOrNull { it.setting == setting }?.passes

    /** Port of `ValidationScoreboard.Verdict` (the decision rule at the bottom of docs/VALIDATION.md). */
    enum class Verdict(val raw: String) {
        go("GO"),
        goOutdoorOnly("GO — outdoor only"),
        noGo("NO-GO"),
        notEnoughData("Not enough data yet"),
    }

    val verdict: Verdict
        get() {
            val teeG1 = g1Passes(SwingSetting.tee)
            val g2 = g2Passes
            val evOK = g4EvPasses
            val laOK = g4LaPasses
            if (teeG1 == null || g2 == null || evOK == null || laOK == null) {
                return Verdict.notEnoughData
            }
            if (!teeG1) return Verdict.noGo
            if (!(g2 && evOK && laOK)) return Verdict.noGo
            val cage = g1Passes(SwingSetting.cage)
            if (cage != null && !cage) return Verdict.goOutdoorOnly
            return Verdict.go
        }

    val verdictExplanation: String
        get() = when (verdict) {
            Verdict.notEnoughData ->
                "Needs outdoor tee clips, at least three teeid_ swings, and enough tracked flight for the gravity cross-check."
            Verdict.noGo ->
                if (g1Passes(SwingSetting.tee) == false) {
                    "Outdoor tee trackability failed. Per the decision rule this is a full stop — rethink capture (shorter distance, brighter ball, cleaner background) before any more app work."
                } else {
                    "Trackability holds but the accuracy gates do not. Check scale agreement and repeatability before trusting any number."
                }
            Verdict.goOutdoorOnly ->
                "Outdoor path is good. The cage did not reach 70% trackability, so it is capture-and-replay only — a documented limitation, not a blocker."
            Verdict.go ->
                "All three deciding gates pass. Phases 1-2 are cleared."
        }

    companion object {
        /** Port of `ValidationScoreboard.build(from:)`; the reasoning lives there. */
        fun build(from: List<ScoreboardSwing>): ValidationScoreboard {
            val swings = from

            // G1 — trackability, per setting.
            val g1 = mutableListOf<G1Row>()
            for (setting in SwingSetting.entries) {
                val rows = swings.filter { it.setting == setting }
                if (rows.isEmpty()) continue
                g1.add(G1Row(setting = setting,
                             tracked = rows.count { it.meetsG1 },
                             total = rows.size,
                             threshold = setting.g1Threshold))
            }

            // G2 — median scale disagreement across outdoor clips.
            val disagreements = swings
                .filter { it.setting.isOutdoor }
                .mapNotNull { it.scaleDisagreement }
                .map { it * 100 }
            val g2MedianPct = if (disagreements.isEmpty()) null else Geometry.median(disagreements)

            // G3 — fly balls with hand-measured hang time and carry.
            val g3 = mutableListOf<G3Row>()
            for (swing in swings) {
                if (swing.hangS == null && swing.carryM == null) continue
                val check = FlightModel.check(
                    metrics = SwingMetrics(launchAngleDeg = swing.launchAngleDeg,
                                           exitVeloMph = swing.exitVeloMph,
                                           exitVeloMps = swing.exitVeloMps,
                                           scaleBallMPerPx = swing.scaleBallMPerPx,
                                           scaleGravityMPerPx = swing.scaleGravityMPerPx,
                                           scaleDisagreement = swing.scaleDisagreement,
                                           diameterDrift = swing.diameterDrift,
                                           nFrames = swing.trackedFrames,
                                           trackDurationS = swing.trackDurationS,
                                           fitRmsPx = swing.fitRmsPx,
                                           t0 = swing.contactTime,
                                           vxPxS = 0.0, vyPxS = 0.0,
                                           flags = swing.flags),
                    hangS = swing.hangS,
                    carryM = swing.carryM)
                g3.add(G3Row(id = swing.id,
                             label = swing.clipFilename ?: "swing",
                             hangErrorPct = check.hangErrorPct,
                             carryErrorPct = check.carryErrorPct,
                             hangPasses = check.hangPasses,
                             carryPasses = check.carryPasses))
            }

            // G4 — repeatability over the identical-intent tee swings.
            val ident = swings.filter { it.setting == SwingSetting.teeid && it.trackedFrames > 0 }
            val enough = ident.size >= 3

            // G5 — the audio trigger, over the app's OWN captures only.
            val ownCaptures = swings.filter { !it.captureFlags.contains(CaptureFlag.importedClip) }

            return ValidationScoreboard(
                g1 = g1,
                g2MedianPct = g2MedianPct,
                g2Count = disagreements.size,
                g3 = g3,
                g4EvSd = if (enough) Geometry.sampleStdDev(ident.map { it.exitVeloMph }) else null,
                g4LaSd = if (enough) Geometry.sampleStdDev(ident.map { it.launchAngleDeg }) else null,
                g4Count = ident.size,
                g5AutoTriggered = ownCaptures.count { it.autoTriggered },
                g5Total = ownCaptures.size,
            )
        }
    }
}
