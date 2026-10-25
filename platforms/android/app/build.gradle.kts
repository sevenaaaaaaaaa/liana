plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 发布签名从环境变量注入（CI 用）；变量齐全才挂 signingConfig，
// 缺省时 assembleRelease 产出未签名 APK，行为与从前一致。
val releaseStoreFile = System.getenv("LIANA_RELEASE_STORE_FILE")
val releaseStorePassword = System.getenv("LIANA_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = System.getenv("LIANA_RELEASE_KEY_ALIAS")
val releaseKeyPassword = System.getenv("LIANA_RELEASE_KEY_PASSWORD")

android {
    namespace = "dev.liana.ime"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.liana.ime"
        minSdk = 24
        targetSdk = 36
        versionCode = 6
        versionName = "0.7.0"
    }

    // 原生库是预构建好的（platforms/android/build_native.sh 产物），无需 NDK 构建
    sourceSets {
        getByName("main") {
            jniLibs.srcDir("src/main/jniLibs")
        }
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (releaseStoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// 零 androidx：IME 服务与键盘 UI 全部用 framework API，保持 APK 最小
dependencies {
}