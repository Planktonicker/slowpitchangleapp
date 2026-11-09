// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "SwingLab"

// `core` is plain Kotlin on the JVM, with no Android dependency at all. That
// is the point of it: the measurement port runs its parity tests in seconds on
// any machine with a JDK, without an emulator or the Android SDK, so the rule
// "parity must never go red" can be checked on every edit rather than only in
// CI.
include(":core")
include(":app")
