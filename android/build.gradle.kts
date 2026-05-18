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
    
    // FORCE NDK DAN SDK VERSION UNTUK SEMUA SUBPROJECTS
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.findByName("android")?.let { android ->
                try {
                    // Force NDK
                    android.javaClass.getMethod("setNdkVersion", String::class.java).invoke(android, "27.2.12479018")
                    // Force Compile SDK
                    android.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType ?: Int::class.java).invoke(android, 36)
                    
                    // Force Target SDK via defaultConfig if it exists
                    val defaultConfig = android.javaClass.getMethod("getDefaultConfig").invoke(android)
                    defaultConfig.javaClass.getMethod("setTargetSdkVersion", Int::class.javaPrimitiveType ?: Int::class.java).invoke(defaultConfig, 36)
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
