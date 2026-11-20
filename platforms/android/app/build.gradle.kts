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
        versionCode = 30
        versionName = "0.28.0"
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

// 整句搭配模型：从仓库内共享的 base.lm 复制进 assets，随 APK 分发。
// 没有它整句不看上下文，实测整句 Top-1 从 64.2% 掉到 47.5%。
val sharedModel = rootProject.file("../../crates/dict/data/lm/base.lm")
tasks.register<Copy>("copySharedModel") {
    onlyIf { sharedModel.exists() }
    from(sharedModel)
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.matching { it.name.startsWith("preBuild") }.configureEach { dependsOn("copySharedModel") }