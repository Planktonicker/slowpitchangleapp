// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.swinglab"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.swinglab"
        // Android 11, what the Galaxy S21 shipped with. Nothing this app needs
        // (Camera2 high-speed sessions, the photo picker back-port, scoped
        // storage) is newer than that.
        minSdk = 30
        targetSdk = 36
        versionCode = 4
        versionName = "1.0.1"
    }

    // ONE signing key for every build, wherever it is built.
    //
    // Android refuses to install an update signed with a different key than the
    // installed copy, and the only way past that refusal is to uninstall — which
    // deletes every stored swing. CI runners generate a fresh debug key per run,
    // so without this every downloaded build would be a different app as far as
    // the phone is concerned. The key is a development key, committed on
    // purpose: see android/keystore/README.md for what that does and does not
    // protect.
    signingConfigs {
        create("dev") {
            storeFile = rootProject.file("keystore/swinglab-dev.jks")
            storePassword = "swinglab-dev"
            keyAlias = "swinglab-dev"
            keyPassword = "swinglab-dev"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("dev")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("dev")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":core"))

    val composeBom = platform("androidx.compose:compose-bom:2026.06.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation(kotlin("test"))
}
