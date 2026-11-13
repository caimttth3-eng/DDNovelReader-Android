import java.util.Properties
import java.io.FileInputStream
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val signingPropertiesPath = System.getenv("DDNOVEL_SIGNING_PROPERTIES")?.takeIf { it.isNotBlank() }
val keystorePropertiesFile = signingPropertiesPath?.let { file(it) }
if (keystorePropertiesFile != null) {
    require(keystorePropertiesFile.isFile) { "Signing properties file is missing." }
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    for (name in listOf("storeFile", "storePassword", "keyAlias", "keyPassword", "storeType")) {
        require(!keystoreProperties.getProperty(name).isNullOrBlank()) { "Incomplete signing properties." }
    }
    require(keystoreProperties.getProperty("storeType") == "PKCS12") { "A PKCS12 fixed signing key is required." }
    val expected = rootProject.file("signing-certificate.sha256").readText()
        .replace(Regex("[:\\s]"), "").lowercase()
    require(expected.matches(Regex("[0-9a-f]{64}"))) { "Invalid public signing certificate fingerprint." }
    val keytool = File(System.getProperty("java.home"), "bin/keytool" + if (System.getProperty("os.name").startsWith("Windows")) ".exe" else "")
    val command = ProcessBuilder(keytool.absolutePath, "-exportcert", "-keystore",
        keystoreProperties.getProperty("storeFile"), "-alias", keystoreProperties.getProperty("keyAlias"),
        "-storetype", "PKCS12", "-storepass:env", "DD_STORE_PASSWORD")
    command.environment()["DD_STORE_PASSWORD"] = keystoreProperties.getProperty("storePassword")
    val process = command.start()
    val certificate = process.inputStream.readBytes()
    process.errorStream.readBytes()
    require(process.waitFor() == 0) { "Could not validate signing certificate." }
    val actual = MessageDigest.getInstance("SHA-256").digest(certificate)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    require(actual == expected) { "Signing certificate differs from the pinned public certificate." }
}

android {
    namespace = "com.ddnovelreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.ddnovelreader"
        minSdk = flutter.minSdkVersion
        // audio_service 0.18.19 startForeground 未传 foregroundServiceType,
        // Android 15 全面屏沉浸：targetSdk 35 强制 edge-to-edge，
        // 导航条透明、内容延伸到底部，消除系统白条
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeType = "PKCS12"
            keyAlias = keystoreProperties["keyAlias"] as String? ?: ""
            keyPassword = keystoreProperties["keyPassword"] as String? ?: ""
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String? ?: ""
        }
    }

    buildTypes {
        release {
            // Missing secrets produce an unsigned APK. Never invent a new key.
            signingConfig = if (keystorePropertiesFile != null) {
                signingConfigs.getByName("release")
            } else {
                null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
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
