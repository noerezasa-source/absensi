plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.absensimassal"
    compileSdk = 36
    ndkVersion = "27.2.12479018"

    configurations.all {
        resolutionStrategy {
            force("androidx.browser:browser:1.8.0")
            force("androidx.activity:activity:1.8.0")
            force("androidx.activity:activity-ktx:1.8.0")
            force("androidx.core:core:1.13.1")
            force("androidx.core:core-ktx:1.13.1")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    lint {
        abortOnError = false
        disable.add("HardcodedDebugMode")
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
        }
    }

    defaultConfig {
        applicationId = "com.example.absensimassal"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    applicationVariants.all {
        if (buildType.name == "release") {
            outputs.all {
                (this as? com.android.build.gradle.api.ApkVariantOutput)?.let { output ->
                    if (output.outputFileName.endsWith(".apk")) {
                        output.outputFileName = "AbsensiMassal.apk"
                    }
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

tasks.whenTaskAdded {
    if (name.contains("AarMetadata")) {
        enabled = false
    }
}

dependencies {

    implementation(
        files(
            "libs/zkandroidcore.jar",
            "libs/zkandroidfpreader.jar",
            "libs/zkandroidfingerservice.jar"
        )
    )

    implementation(
        fileTree(
            mapOf(
                "dir" to "libs",
                "include" to listOf("*.jar")
            )
        )
    )

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

        implementation("androidx.core:core:1.13.1") {
            because("Force older version for compatibility")
        }

        implementation("androidx.core:core-ktx:1.13.1") {
            because("Force older version for compatibility")
        }
    }
}

flutter {
    source = "../.."
}