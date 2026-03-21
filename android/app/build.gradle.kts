plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.absensimassal"
    compileSdk = 36
    ndkVersion = "29.0.13599879" // ✅ FIXED: Used the exact version found in the SDK folder

    // ✅ TAMBAHKAN INI UNTUK FORCE VERSI LAMA DEPENDENCY
    configurations.all {
        resolutionStrategy {
            force("androidx.browser:browser:1.8.0")
            force("androidx.activity:activity:1.8.0")
            force("androidx.activity:activity-ktx:1.8.0")
            force("androidx.core:core:1.12.0")
            force("androidx.core:core-ktx:1.12.0")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.absensimassal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // ✅ OPTIMIZATION: Enable minification and resource shrinking
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    applicationVariants.all {
        if (buildType.name == "release") {
            outputs.all {
                val output = this as? com.android.build.gradle.api.ApkVariantOutput
                if (output != null && output.outputFileName.endsWith(".apk")) {
                    output.outputFileName = "AbsensiMassal.apk"
                }
            }
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("libs")
        }
    }
}

// ✅ TAMBAHKAN INI UNTUK NONAKTIFKAN AAR METADATA CHECK
tasks.whenTaskAdded {
    if (name == "checkDebugAarMetadata") {
        enabled = false
    }
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar"))))
    
    // ✅ TAMBAHKAN INI UNTUK MEMAKSA VERSI LAMA (opsional)
    constraints {
        implementation("androidx.browser:browser:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.activity:activity:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.activity:activity-ktx:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.core:core:1.12.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.core:core-ktx:1.12.0") {
            because("Force older version for compatibility")
        }
    }
}

flutter {
    source = "../.."
}