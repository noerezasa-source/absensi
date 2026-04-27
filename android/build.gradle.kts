buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.13.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.21")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: java.io.File = rootProject.layout.buildDirectory.asFile.orNull?.resolve("../../build") ?: error("Cannot resolve build directory")
rootProject.layout.buildDirectory.set(file(newBuildDir))

subprojects {
    val newSubprojectBuildDir = file(newBuildDir.resolve(project.name))
    project.layout.buildDirectory.set(newSubprojectBuildDir)
    
    // FORCE NDK VERSION UNTUK SEMUA SUBPROJECTS
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.findByName("android")?.let { android ->
                try {
                    android.javaClass.getMethod("setNdkVersion", String::class.java).invoke(android, "27.2.12479018")
                } catch (e: Exception) {
                    // Ignore if method doesn't exist
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// ========== CARA SIMPLE NONAKTIFKAN CHECK AAR ==========
tasks.matching { it.name.contains("checkDebugAarMetadata") }.all {
    enabled = false
}
tasks.matching { it.name.contains("checkReleaseAarMetadata") }.all {
    enabled = false
}