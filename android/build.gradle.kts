group = "io.github.terryhuanghd.local_wifi_join"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Kotlin support comes from AGP 9 built-in Kotlin, or is applied by the Flutter Gradle plugin
// (Flutter 3.44+) when the app still uses AGP 8.
plugins {
    id("com.android.library")
}

android {
    namespace = "io.github.terryhuanghd.local_wifi_join"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // WifiNetworkSpecifier requires API 29.
        minSdk = 29
    }

    testOptions {
        unitTests {
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Explicit JUnit 5 variant: built-in Kotlin (AGP 9) does not infer it from `kotlin-test`.
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
}
