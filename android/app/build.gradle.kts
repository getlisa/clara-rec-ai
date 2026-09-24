plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

import java.util.Properties

val localProperties =
    Properties().apply {
        val file = rootProject.file("local.properties")
        if (file.exists()) {
            file.inputStream().use { load(it) }
        }
    }

fun getBuildProperty(name: String): String {
    val value =
        project.findProperty(name)?.toString()
            ?: localProperties.getProperty(name)
            ?: ""
    return value.trim().replace("\"", "\\\"")
}

android {
    namespace = "com.metalens.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.metalens.app"
        minSdk = 31
        targetSdk = 34
        versionCode = 1
        versionName = "0.2.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

        // Prototype only: set -POPENAI_API_KEY / -POPENAI_MODEL, or define them in:
        // - ~/.gradle/gradle.properties
        // - android/local.properties (NOT committed)
        // (Do NOT commit API keys.)
        buildConfigField(
            "String",
            "OPENAI_API_KEY",
            "\"${getBuildProperty("OPENAI_API_KEY")}\"",
        )
        buildConfigField(
            "String",
            "OPENAI_MODEL",
            "\"${getBuildProperty("OPENAI_MODEL")}\"",
        )

        // Image upload to S3. Same rules as above: define these in android/local.properties
        // (NOT committed) or pass them with -P. Leaving them blank disables uploading.
        //
        // Anything compiled in here is extractable from the APK, so the IAM user behind these
        // keys must be limited to s3:PutObject on this one bucket. See android/README.md.
        listOf(
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "AWS_REGION",
            "S3_BUCKET",
        ).forEach { name ->
            buildConfigField("String", name, "\"${getBuildProperty(name)}\"")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.androidx.navigation.compose)

    implementation(libs.mwdat.core)
    implementation(libs.mwdat.camera)
    implementation(libs.androidx.exifinterface)

    implementation(libs.okhttp)

    testImplementation(libs.junit)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
