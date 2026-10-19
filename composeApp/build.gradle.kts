import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.4.21"
    id("org.jetbrains.compose") version "1.12.2"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21"
}

group = "app.kapylaun.ch"
version = providers.gradleProperty("appVersion").orElse("1.0.0").get()

val generatedLauncherResources = layout.buildDirectory.dir("generated/launcher-resources")
val microsoftClientId = providers.environmentVariable("KAPYLAUNCHER_MICROSOFT_CLIENT_ID").orElse("")
val generateLauncherBuildConfig by tasks.registering {
    inputs.property("microsoftClientId", microsoftClientId)
    outputs.dir(generatedLauncherResources)
    doLast {
        val value = microsoftClientId.get()
            .replace("\\", "\\\\")
            .replace("\r", "")
            .replace("\n", "")
        val configFile = generatedLauncherResources.get().file("kapylauncher.properties").asFile
        configFile.parentFile.mkdirs()
        configFile.writeText("microsoft.client.id=$value\n")
    }
}

sourceSets.getByName("main").resources.srcDir(generatedLauncherResources)
tasks.processResources {
    dependsOn(generateLauncherBuildConfig)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")
    testImplementation(kotlin("test"))
}

compose.desktop {
    application {
        mainClass = "app.kapylaun.ch.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "kapylauncher"
            packageVersion = project.version.toString()
            description = "Kotlin desktop Minecraft launcher"
            vendor = "KapyLauncher"

            windows {
                menuGroup = "KapyLauncher"
                upgradeUuid = "45fb0448-433f-4e83-aef2-ea920f33d185"
                shortcut = true
            }

            macOS {
                bundleID = "app.kapylaun.ch"
                appCategory = "public.app-category.games"
            }

            linux {
                packageName = "kapylauncher"
            }
        }
    }
}

tasks.test {
    useJUnitPlatform()
}
