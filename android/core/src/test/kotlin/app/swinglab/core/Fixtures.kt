// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `spike/fixtures/parity.json`, the numbers `spike/sla_common.py` produced.
 *
 * Read in place — the Gradle test task passes its path in. Never copy it into
 * this module: two copies of the reference is how a port drifts without any
 * test noticing. (The frozen iOS app keeps its own snapshot under app/Tests;
 * that one is deliberately not this module's reference.)
 */
object Fixtures {
    val root: JsonObject by lazy {
        val path = System.getProperty("parity.fixtures")
            ?: fail("parity.fixtures system property not set — run through Gradle")
        Json.parseToJsonElement(File(path).readText()).jsonObject
    }

    val constants: JsonObject get() = root.getValue("constants").jsonObject

    fun block(name: String): List<JsonObject> =
        root[name]?.jsonArray?.map { it.jsonObject } ?: fail("no fixture block '$name'")

    fun constant(name: String): Double =
        constants[name]?.jsonPrimitive?.double ?: fail("no constant '$name' in fixtures")
}

// Small readers, so a test reads like the Swift one it mirrors.
fun JsonObject.d(key: String): Double = getValue(key).jsonPrimitive.double
fun JsonObject.dOrNull(key: String): Double? =
    this[key]?.let { if (it is JsonNull) null else it.jsonPrimitive.doubleOrNull }
fun JsonObject.i(key: String): Int = d(key).toInt()
fun JsonObject.s(key: String): String = getValue(key).jsonPrimitive.content
fun JsonObject.b(key: String): Boolean = getValue(key).jsonPrimitive.booleanOrNull ?: fail("$key not a bool")
fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject
fun JsonObject.arr(key: String): JsonArray = getValue(key).jsonArray
fun JsonObject.has(key: String): Boolean = this[key] != null && this[key] !is JsonNull
fun JsonElement.doubles(): List<Double> = jsonArray.map { it.jsonPrimitive.double }

/**
 * Same tolerance rule as the Swift `assertClose`: absolute `abs` or relative
 * `rel`, whichever is looser.
 */
fun assertClose(actual: Double, expected: Double, message: String,
                abs: Double = 1e-9, rel: Double = 1e-9) {
    if (actual.isNaN() && expected.isNaN()) return
    val tol = max(abs, rel * abs(expected))
    assertTrue(abs(actual - expected) <= tol,
        "$message: got $actual, expected $expected (|diff| ${abs(actual - expected)} > $tol)")
}

@Suppress("unused")
private fun JsonPrimitive.isNumber() = doubleOrNull != null
