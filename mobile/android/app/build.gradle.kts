import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Play upload key. `android/key.properties` names the keystore and its
// password; both are gitignored, and in CI the release workflow writes them from
// repository secrets. See RELEASING.md → Google Play.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}
val hasUploadKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "uk.co.mojoandco.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Permanent once the first bundle is on Google Play — Play will never
        // accept a different one for this listing. It is not the iOS bundle ID
        // (uk.co.mojoandco.mojoApp), and does not need to be.
        applicationId = "uk.co.mojoandco.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The upload key when there is one. Without it — any machine but the
            // release workflow — a release build still signs with the debug key,
            // so `flutter run --release` keeps working. Play refuses a
            // debug-signed bundle outright, and the workflow checks the
            // signature before handing one over, so this cannot ship by mistake.
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("upload")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
