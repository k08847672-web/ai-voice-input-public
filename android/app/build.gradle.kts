plugins {
    id("com.android.application")
}

android {
    namespace = "com.aivoiceinput.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.aivoiceinput.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 3
        versionName = "0.1.2"

        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    testOptions {
        unitTests.all {
            it.useJUnit()
        }
    }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
}
