plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.whisperandroid"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.whisperandroid"
        minSdk = 27
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += listOf(
                "lib/arm64-v8a/libc++_shared.so",
                "lib/arm64-v8a/libomp.so",
                "lib/arm64-v8a/libonnxruntime.so",
                "lib/arm64-v8a/libsherpa-onnx-c-api.so",
                "lib/arm64-v8a/libsherpa-onnx-cxx-api.so",
                "lib/arm64-v8a/libsherpa-onnx-jni.so"
            )
        }
    }
}

dependencies {
    // Use Sherpa Java/Kotlin API classes only. Native Sherpa libs come from runanywhere-onnx
    // to avoid loading two incompatible libsherpa-onnx versions in one process.
    implementation(files("libs/sherpa-onnx-1.12.23-classes.jar"))
    implementation("ai.nexa:core:0.0.22")
    implementation("io.github.sanchitmonga22:runanywhere-sdk-android:0.16.1")
    implementation("io.github.sanchitmonga22:runanywhere-onnx-android:0.16.1")

    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7.0")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    implementation(platform("androidx.compose:compose-bom:2024.02.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")

    implementation("com.google.android.material:material:1.11.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
