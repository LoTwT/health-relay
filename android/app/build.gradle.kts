plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}
android {
    namespace = "app.healthrelay.android"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "app.healthrelay.android"
        minSdk = 34
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("boolean", "HC_AGGREGATION_TESTS", providers.gradleProperty("healthRelayAggregateTests").orElse("false").get())
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isReturnDefaultValues = true }
    sourceSets {
        if (providers.gradleProperty("healthRelayAggregateTests").orElse("false").get() == "true") getByName("debug").manifest.srcFile("src/hcAggregation/AndroidManifest.xml")
        getByName("test").resources.srcDir("../../fixtures")
        getByName("androidTest").assets.srcDir("../../fixtures")
    }
    signingConfigs {
        create("personalRelease") {
            val keyPath = providers.environmentVariable("HEALTH_RELAY_KEYSTORE").orNull
            if (keyPath != null) {
                storeFile = file(keyPath)
                storePassword = providers.environmentVariable("HEALTH_RELAY_STORE_PASSWORD").orNull
                keyAlias = providers.environmentVariable("HEALTH_RELAY_KEY_ALIAS").orNull
                keyPassword = providers.environmentVariable("HEALTH_RELAY_KEY_PASSWORD").orNull
            }
        }
    }
    buildTypes { release { signingConfig = signingConfigs.getByName("personalRelease") } }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
ksp { arg("room.schemaLocation", "$projectDir/schemas") }
dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.compose)
    implementation(libs.lifecycle.viewmodel)
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
    implementation(libs.serialization.json)
    implementation(libs.coroutines.android)
    implementation(libs.health.connect)
    implementation(libs.zxing)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
}
