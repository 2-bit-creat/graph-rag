import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials, kept out of the repository. Create
// android/key.properties (see android/key.properties.example) holding
// storeFile / storePassword / keyAlias / keyPassword. When it is absent —
// every developer machine and CI job that only ever builds debug — the release
// type falls back to the debug key exactly as before, so `flutter run
// --release` keeps working locally.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.example.graphrag_mobile"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.graphrag_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Shipping a store build signed with the debug key is not possible
            // (Play rejects it) and would also lock the app out of future
            // updates, so a real keystore is required for anything published.
            // Without key.properties this stays on the debug key so local
            // release runs still work — the check below is what stops that
            // build from being mistaken for a shippable one.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 shrinking is deliberately left off here: it needs keep rules
            // verified against a real release build, which is a separate task
            // from getting signing right.
        }
    }
}

// Fail loudly when someone assembles a release bundle for distribution without
// the keystore in place. `-PallowDebugSigning=true` is the deliberate escape
// hatch for a local `flutter build apk --release` smoke test.
tasks.matching { it.name == "bundleRelease" }.configureEach {
    doFirst {
        val allowDebug = project.findProperty("allowDebugSigning") == "true"
        if (!hasReleaseKeystore && !allowDebug) {
            throw GradleException(
                "Release bundle is signed with the DEBUG key. Create " +
                    "android/key.properties (see key.properties.example) with " +
                    "your upload keystore, or pass -PallowDebugSigning=true if " +
                    "this build is only a local smoke test.",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
