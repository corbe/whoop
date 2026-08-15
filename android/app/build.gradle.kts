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

// ============================================================================
// WORKAROUND x86_64 EMULATOR (JuggleIM E2EE) — NÃO remover sem ler isto.
//
// POR QUE EXISTE:
//   O módulo proprietário com.juggle.ultimate:juggle (1.8.19.1, "JuggleUltimate",
//   E2EE do JuggleIM) publica libimsdk_libs.so APENAS para armeabi-v7a e
//   arm64-v8a — NÃO existe build x86_64 do artefato (verificado: AAR contém
//   só jni/{armeabi-v7a,arm64-v8a}/libimsdk_libs.so; sem fonte pública, sem
//   build system, binário stripped). Emulador Android desta máquina é x86_64
//   (ARM64 AVD não roda no host x86_64 — QEMU2 rejeita). Sem o .so, o
//   EncryptionUtils (System.loadLibrary("imsdk_libs")) falha e a chamada JNI
//   gera UnsatisfiedLinkError / FATAL EXCEPTION J_SEND ao abrir o Chat.
//
// COMO FUNCIONA:
//   O SDK principal (com.juggle.im:juggle:1.8.39) lida GRACEFULLY com a
//   ausência do DataConverter: PBData.fetchUltConverter() faz
//   Class.forName("com.juggle.im.ultimate.encrypt.DataConverter"), captura a
//   exceção, loga "DataConverter not exist" e usa mConverter2 = null (todos os
//   call-sites têm null-check) → conexão/WebSocket/histórico/composer seguem
//   com o SDK REAL do JuggleIM, apenas sem a camada E2EE nativa. Não é
//   reimplementação de crypto, nem substituição do JuggleIM.
//
// DETECÇÃO AUTOMÁTICA DO ALVO (sem flag manual):
//   O Flutter CLI SEMPRE passa -Ptarget-platform=<abi> para o Gradle com base
//   no device real: `flutter run -d emulator-5554` (x86_64) → ro.product.cpu.abi
//   = x86_64 → TargetPlatform.android_x64 → -Ptarget-platform=android-x64
//   (verificado no flutter_tools: android_device.dart targetArchs:
//   <AndroidArch>[androidArch] → gradle.dart "-Ptarget-platform=$targetPlatforms").
//   A exclusão abaixo só dispara quando o alvo é EXATAMENTE android-x64.
//
// ESCOPO (segurança em camadas):
//   1. target-platform == "android-x64" (único ABI) — emulador x86_64 apenas.
//   2. Mesmo com o alvo x86_64, a exclusão só é aplicada a configurações DEBUG
//      (nomes contendo "debug"); configurações de RELEASE jamais são tocadas.
//   Builds ARM (android-arm64/android-arm) e builds universais SEM a propriedade
//   (default = todas as ABIs) NUNCA excluem → produção ARM preserva o módulo
//   E2EE oficial (com.juggle.ultimate presente + libimsdk_libs.so arm64).
// ============================================================================
val flutterTargetPlatform: String? =
    project.findProperty("target-platform") as? String
val isX86_64EmulatorOnly: Boolean =
    flutterTargetPlatform?.split(",")?.map { it.trim() } == listOf("android-x64")

if (isX86_64EmulatorOnly) {
    configurations.configureEach {
        if (name.contains("debug")) {
            exclude(group = "com.juggle.ultimate", module = "juggle")
        }
    }
    println("WARN[emulator-x86_64]: com.juggle.ultimate EXCLUÍDO de configurações debug (target-platform=android-x64; E2EE nativa desabilitada só neste build de emulador).")
}

android {
    namespace = "br.com.noana.noana_wellness_app"
    // compileSdk fixo em 37: flutter_secure_storage 11.x exige compileSdk >= 37
    // (o default do Flutter 3.41 é 36 → warning "flutter_secure_storage
    // requires compileSdk = 37"). minSdk/targetSdk continuam do Flutter.
    compileSdk = 37
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
