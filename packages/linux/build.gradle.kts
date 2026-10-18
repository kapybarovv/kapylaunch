import org.apache.tools.ant.filters.ReplaceTokens
import org.gradle.api.tasks.bundling.Compression
import org.gradle.api.tasks.bundling.Tar
import org.gradle.api.tasks.Sync
import net.legacylauncher.gradle.*

plugins {
    base
    net.legacylauncher.brand
}

evaluationDependsOn(projects.launcher.path)
evaluationDependsOn(projects.packages.portable.path)

val portableBase = project(projects.packages.portable.path)
val preparePortableBaseBuild = portableBase.tasks.named("preparePortableBaseBuild")
val releaseVersion = "${projects.launcher.version}+${brand.brand.get()}"

val prepareLinuxBuild by tasks.registering(Sync::class) {
    dependsOn(preparePortableBaseBuild)
    into(layout.buildDirectory.dir("linux/${brand.brand.get()}/kapylauncher"))

    from(preparePortableBaseBuild) {
        exclude("LL.exe", "LL.pdb", "stubLauncher.args")
    }

    from("resources") {
        filter<ReplaceTokens>("tokens" to mapOf("version" to releaseVersion))
        filteringCharset = "UTF-8"
    }

    doLast {
        val appDir = layout.buildDirectory.dir("linux/${brand.brand.get()}/kapylauncher").get().asFile
        listOf("kapylauncher.sh").forEach { name ->
            val script = appDir.resolve(name)
            if (!script.setExecutable(true, false)) {
                throw GradleException("Unable to mark $script executable")
            }
        }
    }
}

val packageLinux by tasks.registering(Tar::class) {
    dependsOn(prepareLinuxBuild)
    archiveFileName.set("kapylauncher-linux-${releaseVersion.replace('+', '-')}.tar.gz")
    destinationDirectory.set(layout.buildDirectory.dir("update/${brand.brand.get()}"))
    compression = Compression.GZIP
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
    from(prepareLinuxBuild) {
        into("kapylauncher")
    }
}

tasks.named("assemble") {
    dependsOn(packageLinux)
}
