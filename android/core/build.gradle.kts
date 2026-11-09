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
    // The SAME fixture file the iOS tests read — never a copy. Two copies of
    // the reference numbers is how a port drifts without a test noticing.
    systemProperty(
        "parity.fixtures",
        rootProject.projectDir.resolve("../app/Tests/Fixtures/parity.json").canonicalPath,
    )
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
