plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ua.beamdeck.agent"
    compileSdk = 35

    defaultConfig {
        applicationId = "ua.beamdeck.agent"
        minSdk = 26
        targetSdk = 34
        versionCode = 5
        versionName = "0.3.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

tasks.withType<Test>().configureEach {
    System.getProperty("bleOut")?.let { systemProperty("bleOut", it) }
}

val webDist = rootProject.layout.projectDirectory.dir("../web/dist")
val bundledWeb = layout.buildDirectory.dir("generated/beamdeck-assets")
val bundleWeb by tasks.registering(Sync::class) {
    from(webDist)
    into(bundledWeb.map { it.dir("remote") })
    doFirst {
        check(webDist.file("index.html").asFile.isFile) {
            "Build the Remote first: cd ../web && npm ci && npm run build"
        }
    }
}
android.sourceSets["main"].assets.srcDir(bundledWeb)
tasks.named("preBuild") { dependsOn(bundleWeb) }

dependencies {
    implementation("io.ktor:ktor-server-cio-jvm:2.3.13")
    implementation("io.ktor:ktor-client-cio-jvm:2.3.13")
    implementation("io.ktor:ktor-server-websockets-jvm:2.3.13")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.1")
    implementation("org.slf4j:slf4j-nop:1.7.36")
    implementation("com.google.zxing:core:3.5.3")
    implementation("dev.mobile:dadb:1.2.10")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
