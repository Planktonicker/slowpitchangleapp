// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

/**
 * Port of `Storage/SwingModels.swift` `SwingSetting` (the capture settings of
 * docs/CAPTURE_PROTOCOL.md; raw values are spike/batch_run.py's clip-name
 * prefixes); the reasoning lives there.
 *
 * Only `SwingSetting` from that file is here, because [SessionMode] is written
 * against it. `SwingDTO`, the persistence record, belongs to the app layer.
 */
enum class SwingSetting(val raw: String) {
    teeid("teeid"),
    tee("tee"),
    toss("toss"),
    live("live"),
    cage("cage"),
    net("net"),
    fly("fly");

    val id: String get() = raw

    val displayName: String
        get() = when (this) {
            teeid -> "Tee (repeatability)"
            tee -> "Outdoor tee"
            toss -> "Soft toss"
            live -> "Field, live pitching"
            cage -> "Cage (camera inside)"
            net -> "Cage (through net)"
            fly -> "Fly ball (ground truth)"
        }

    val blurb: String
        get() = when (this) {
            teeid -> "The five identical-intent swings for gate G4."
            tee -> "The gate that decides the whole project (G1)."
            toss -> "Normal variety off soft toss."
            live -> "Also proves the pitch is separated from the hit."
            cage -> "Tripod inside the cage. The main CV risk."
            net -> "Expected to fail — filmed so the failure is documented."
            fly -> "Pace off the landing spot and time the hang."
        }

    /** G1 trackability thresholds, matching `G1_THRESHOLDS` in `batch_run.py`. */
    val g1Threshold: Double?
        get() = when (this) {
            tee, teeid, toss -> 0.90
            live, fly -> 0.80
            cage -> 0.70
            net -> null   // expected failure, not a gate
        }

    /** Counts toward the outdoor G2 median. */
    val isOutdoor: Boolean
        get() = when (this) {
            cage, net -> false
            else -> true
        }

    companion object {
        fun fromRaw(raw: String): SwingSetting? = entries.firstOrNull { it.raw == raw }
    }
}
