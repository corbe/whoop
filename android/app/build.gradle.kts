import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Fase 9 — assinatura de release via CI secrets (env vars) APENAS.
// Nada de keystore/password commitado: o keystore chega via ANDROID_KEYSTORE_BASE64
// (decodificado em tempo de build, fora do repo) e as senhas via env.
// Sem as env vars, o release usa debug keys (dev local — NUNCA produção).

android {
    namespace = "br.com.noana.noana_wellness_app"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "br.com.noana.noana_wellness_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            val b64 = System.getenv("ANDROID_KEYSTORE_BASE64")
            val alias = System.getenv("ANDROID_KEY_ALIAS")
            val storePass = System.getenv("ANDROID_STORE_PASSWORD")
            val keyPass = System.getenv("ANDROID_KEY_PASSWORD")
            if (!b64.isNullOrBlank() && !alias.isNullOrBlank() &&
                !storePass.isNullOrBlank() && !keyPass.isNullOrBlank()
            ) {
                val keystoreFile = File(project.buildDir, "release-keystore.jks")
                keystoreFile.parentFile.mkdirs()
                keystoreFile.writeBytes(Base64.getDecoder().decode(b64))
                signingConfig = signingConfigs.create("release") {
                    storeFile = keystoreFile
                    storePassword = storePass
                    keyAlias = alias
                    keyPassword = keyPass
                }
            } else {
                println("WARN: release signing env vars ausentes -> debug keys (NAO e producao)")
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
