import net.legacylauncher.gradle.*

val gitVersion = providers.of(StdOutExecValueSource::class) {
    parameters {
        args("git", "describe", "--tags", "--always", "--match", "[0-9].*")
        failureResult = "detached"
    }
}.get()
val semanticVersion = System.getenv("KAPYLAUNCHER_VERSION")
    ?: gitVersion.takeIf { it.matches(Regex("""\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?""")) }
    ?: "0.0.0-${gitVersion.replace(Regex("[^0-9A-Za-z.-]"), "-")}"

project.version = semanticVersion
