plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yuchuan.app"
    // 插件 (rust_flutter_ui_native) 要求 SDK 36 + NDK 27（docs/permissions.md T0.1）
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yuchuan.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 本项目只发布 Android ARM（真机主架构）：显式收口打包的 ABI。
        // 必要性：cargokit 只把「本次构建的架构」拷进 build/rust_flutter_ui_native/jniLibs/，
        // 从不清理上一次构建留下的其它架构目录，于是 --target-platform=android-arm64
        // 之后 APK 里仍会混进 armeabi-v7a / x86_64 的 librust_flutter_ui_native.so
        // （却没有对应的 libflutter.so / libapp.so）——32 位 ARM 真机会判定「兼容」并安装，
        // 启动即崩，同时白白多出约 3MB。abiFilters 让打包结果只含 arm64-v8a。
        // 如需在模拟器上调试，请临时改为 listOf("arm64-v8a", "x86_64")。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // MainActivity 的 edge-to-edge / 系统栏控制（WindowCompat / WindowInsetsControllerCompat）
    implementation("androidx.core:core-ktx:1.13.1")
}
