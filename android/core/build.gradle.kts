// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Bytecode for Java 17, the level Android's toolchain consumes, built by
// whatever JDK is installed (21 here and on CI) — no toolchain download.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}

tasks.test {
    useJUnitPlatform()
    // The live fixtures, read in place from beside the Python that writes them —
    // never a copy. (app/Tests/Fixtures/parity.json is the frozen iOS app's
    // snapshot and stops moving; it is not this module's reference.)
    val fixtures = rootProject.projectDir.resolve("../spike/fixtures/parity.json")
    systemProperty("parity.fixtures", fixtures.canonicalPath)
    // Declared as an input so regenerating the fixtures re-runs the tests.
    // Without it Gradle calls the task UP-TO-DATE and stays green on numbers
    // that no longer exist.
    inputs.file(fixtures).withPropertyName("parityFixtures")
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
