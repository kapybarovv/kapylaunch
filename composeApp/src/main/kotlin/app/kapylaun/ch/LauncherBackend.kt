package app.kapylaun.ch

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.awt.Desktop
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.Locale
import java.util.Properties
import java.util.UUID
import java.util.zip.ZipInputStream
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class AccountKind { OFFLINE, MICROSOFT }

data class LauncherAccount(
    val id: String,
    val name: String,
    val kind: AccountKind,
    val minecraftId: String? = null,
) {
    val label: String get() = "$name · ${if (kind == AccountKind.MICROSOFT) "Microsoft" else "офлайн"}"
}

enum class LoaderKind(val title: String) { VANILLA("Vanilla"), FABRIC("Fabric"), FORGE("Forge") }

data class GameProfile(
    val id: String,
    val minecraftVersion: String,
    val loader: LoaderKind,
    val loaderVersion: String? = null,
    val type: String = "release",
    val releaseTime: String = "",
    val metadataUrl: String? = null,
    val metadataSha1: String? = null,
) {
    val label: String get() = when (loader) {
        LoaderKind.VANILLA -> minecraftVersion
        LoaderKind.FABRIC -> "$minecraftVersion · Fabric ${loaderVersion.orEmpty()}"
        LoaderKind.FORGE -> "$minecraftVersion · Forge ${loaderVersion.orEmpty()}"
    }
}

private data class DeviceCode(
    val userCode: String,
    val deviceCode: String,
    val verificationUri: String,
    val expiresIn: Int,
    val interval: Int,
)

private data class MinecraftIdentity(val account: LauncherAccount, val accessToken: String)

/**
 * Kotlin-only launcher backend for the Compose desktop UI. Game files are kept
 * under ~/.kapylauncher with a separate instance directory for every profile.
 */
class LauncherBackend : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = com.google.gson.GsonBuilder().setPrettyPrinting().create()
    private val root = File(System.getProperty("user.home"), ".kapylauncher")
    private val gameRoot = File(root, "game")
    private val accountsFile = File(root, "accounts.json")
    private val tokenStore = SecureTokenStore(File(root, "credentials"))
    private val httpUserAgent = "kapylauncher/${System.getProperty("kapylauncher.version", "dev")} (Kotlin desktop)"
    private val microsoftClientId: String? = System.getenv("KAPYLAUNCHER_MICROSOFT_CLIENT_ID")
        ?.trim()?.takeIf { it.isNotEmpty() }
        ?: runCatching {
            LauncherBackend::class.java.getResourceAsStream("/kapylauncher.properties")?.use { stream ->
                Properties().apply { load(stream) }.getProperty("microsoft.client.id")
            }
        }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }

    private val officialProfiles = linkedMapOf<String, GameProfile>()
    private val profileMetadataCache = mutableMapOf<String, JsonObject>()
    private val refreshTokens = mutableMapOf<String, String>()
    private var microsoftLoginJob: Job? = null

    val accounts = mutableStateListOf<LauncherAccount>()
    val profiles = mutableStateListOf<GameProfile>()
    var selectedAccountId by mutableStateOf<String?>(null)
        private set
    var selectedProfileId by mutableStateOf("")
        private set
    var busy by mutableStateOf(false)
        private set
    var progress by mutableStateOf(0f)
        private set
    var status by mutableStateOf("Подготовка лаунчера…")
        private set
    var lastError by mutableStateOf<String?>(null)
        private set
    var installedOnly by mutableStateOf(false)
    var delayedLaunch by mutableStateOf(false)
    var verifyFiles by mutableStateOf(true)
    var deviceCode by mutableStateOf<String?>(null)
        private set
    var deviceUrl by mutableStateOf<String?>(null)
        private set
    var deviceMessage by mutableStateOf<String?>(null)
        private set
    var awaitingMicrosoft by mutableStateOf(false)
        private set

    val selectedAccount: LauncherAccount? get() = accounts.firstOrNull { it.id == selectedAccountId }
    val visibleProfiles: List<GameProfile>
        get() = profiles.filter { !installedOnly || File(root, "instances/${safeName(it.id)}/.installed").isFile }

    fun isInstalled(profile: GameProfile): Boolean = File(root, "instances/${safeName(profile.id)}/.installed").isFile

    fun initialize() {
        scope.launch {
            withContext(Dispatchers.Main) { restoreAccounts() }
            refreshProfiles()
        }
    }

    fun refreshProfiles() {
        if (busy) return
        scope.launch {
            setBusy(true, "Загрузка версий Mojang, Fabric и Forge…")
            try {
                val (vanilla, fabric, forge) = withContext(Dispatchers.IO) {
                    val manifest = getJson(MOJANG_MANIFEST)
                    val officialVersions = manifest.array("versions").mapNotNull { item ->
                        val value = item.asJsonObject
                        val versionId = value.string("id")
                        val type = value.string("type")
                        if (versionId.isBlank() || type != "release") return@mapNotNull null
                        GameProfile(
                            id = versionId,
                            minecraftVersion = versionId,
                            loader = LoaderKind.VANILLA,
                            type = type,
                            releaseTime = value.string("releaseTime"),
                            metadataUrl = value.string("url"),
                            metadataSha1 = value.string("sha1"),
                        )
                    }
                    officialProfiles.clear()
                    officialVersions.forEach { officialProfiles[it.id] = it }

                    val availableFabric = runCatching { getJsonArray(FABRIC_GAME_VERSIONS) }
                        .getOrDefault(JsonArray())
                        .mapNotNull { it.asJsonObjectOrNull()?.string("version") }
                        .toSet()
                    val fabricLoader = runCatching { getJsonArray(FABRIC_LOADER_VERSIONS) }
                        .getOrDefault(JsonArray())
                        .firstOrNull { it.asJsonObjectOrNull()?.bool("stable") == true }
                        ?.asJsonObjectOrNull()?.obj("loader")?.string("version")

                    val fabricVersions = if (fabricLoader == null) emptyList() else officialVersions
                        .filter { it.minecraftVersion in availableFabric }
                        .map { base ->
                            GameProfile(
                                id = "fabric:${base.minecraftVersion}:$fabricLoader",
                                minecraftVersion = base.minecraftVersion,
                                loader = LoaderKind.FABRIC,
                                loaderVersion = fabricLoader,
                                type = "modified",
                                releaseTime = base.releaseTime,
                            )
                        }

                    val promotions = runCatching { getJson(FORGE_PROMOTIONS).obj("promos") }
                        .getOrDefault(JsonObject())
                    val forgeVersions = officialVersions.mapNotNull { base ->
                        val recommended = promotions.string("${base.minecraftVersion}-recommended")
                        val latest = promotions.string("${base.minecraftVersion}-latest")
                        val forgeVersion = recommended.ifBlank { latest }
                        if (forgeVersion.isBlank()) null else GameProfile(
                            id = "forge:${base.minecraftVersion}:$forgeVersion",
                            minecraftVersion = base.minecraftVersion,
                            loader = LoaderKind.FORGE,
                            loaderVersion = forgeVersion,
                            type = "modified",
                            releaseTime = base.releaseTime,
                        )
                    }
                    Triple(officialVersions, fabricVersions, forgeVersions)
                }
                val merged = (vanilla + fabric + forge).sortedWith(
                    compareByDescending<GameProfile> { it.releaseTime }.thenBy { it.loader.ordinal },
                )
                withContext(Dispatchers.Main) {
                    profiles.clear()
                    profiles.addAll(merged)
                    if (profiles.none { it.id == selectedProfileId }) {
                        selectedProfileId = profiles.firstOrNull { it.loader == LoaderKind.VANILLA }?.id.orEmpty()
                    }
                    status = "Версий: ${profiles.size} · готово"
                    progress = 1f
                    busy = false
                }
            } catch (failure: Exception) {
                withContext(Dispatchers.Main) {
                    status = "Не удалось обновить список версий"
                    lastError = failure.message ?: "Ошибка загрузки манифеста Minecraft"
                    busy = false
                }
            }
        }
    }

    fun selectAccount(account: LauncherAccount) {
        selectedAccountId = account.id
        saveAccounts()
    }

    fun selectProfile(profile: GameProfile) {
        selectedProfileId = profile.id
    }

    fun addOfflineAccount(rawName: String) {
        val name = rawName.trim()
        if (!name.matches(Regex("[A-Za-z0-9_]{3,16}"))) {
            lastError = "Имя должно содержать 3–16 латинских букв, цифр или символов подчёркивания."
            return
        }
        val existing = accounts.firstOrNull { it.name.equals(name, ignoreCase = true) }
        val account = existing ?: LauncherAccount(UUID.randomUUID().toString(), name, AccountKind.OFFLINE)
        if (existing == null) accounts.add(account)
        selectedAccountId = account.id
        saveAccounts()
        lastError = null
    }

    fun removeAccount(account: LauncherAccount) {
        accounts.removeAll { it.id == account.id }
        tokenStore.delete(account.id)
        refreshTokens.remove(account.id)
        if (selectedAccountId == account.id) selectedAccountId = accounts.firstOrNull()?.id
        saveAccounts()
    }

    fun signInWithMicrosoft() {
        if (busy) return
        if (microsoftClientId == null) {
            lastError = "Microsoft-вход выключен: задайте KAPYLAUNCHER_MICROSOFT_CLIENT_ID при запуске. Это публичный OAuth client ID, не секрет."
            return
        }
        microsoftLoginJob?.cancel()
        microsoftLoginJob = scope.launch {
            setBusy(true, "Запрос кода входа Microsoft…")
            try {
                val device = beginDeviceLogin(microsoftClientId)
                withContext(Dispatchers.Main) {
                    deviceCode = device.userCode
                    deviceUrl = device.verificationUri
                    deviceMessage = "Сначала скопируйте код, затем откройте страницу входа."
                    status = "Ожидание входа Microsoft…"
                    awaitingMicrosoft = true
                    busy = false
                }
                val microsoft = pollDeviceLogin(device, microsoftClientId)
                val identity = exchangeMicrosoftForMinecraft(microsoft.accessToken)
                val account = withContext(Dispatchers.Main) {
                    val existing = accounts.firstOrNull { it.kind == AccountKind.MICROSOFT && it.minecraftId == identity.account.minecraftId }
                    val account = if (existing != null) existing.copy(name = identity.account.name) else identity.account
                    if (existing != null) accounts.remove(existing)
                    accounts.add(account)
                    selectedAccountId = account.id
                    refreshTokens[account.id] = microsoft.refreshToken
                    saveAccounts()
                    deviceCode = null
                    deviceUrl = null
                    deviceMessage = null
                    awaitingMicrosoft = false
                    lastError = null
                    account
                }
                val storageFailure = runCatching { tokenStore.store(account.id, microsoft.refreshToken) }.exceptionOrNull()
                withContext(Dispatchers.Main) {
                    status = if (storageFailure == null) "Вход выполнен: ${account.name}"
                    else "Вход выполнен, но системное хранилище токена недоступно — потребуется повторный вход после перезапуска."
                }
            } catch (cancelled: CancellationException) {
                withContext(Dispatchers.Main) { status = "Вход отменён" }
            } catch (failure: Exception) {
                withContext(Dispatchers.Main) {
                    deviceCode = null
                    deviceUrl = null
                    deviceMessage = null
                    awaitingMicrosoft = false
                    lastError = "Ошибка входа Microsoft: ${failure.message ?: "неизвестная ошибка"}"
                    status = "Вход не выполнен"
                }
            } finally {
                withContext(Dispatchers.Main) { busy = false; awaitingMicrosoft = false }
            }
        }
    }

    fun openMicrosoftPageAfterCopy() {
        val code = deviceCode ?: return
        runCatching {
            val clipboard = java.awt.Toolkit.getDefaultToolkit().systemClipboard
            clipboard.setContents(java.awt.datatransfer.StringSelection(code), null)
            if (Desktop.isDesktopSupported()) Desktop.getDesktop().browse(URI(deviceUrl ?: MICROSOFT_DEVICE_URL))
            deviceMessage = "Код скопирован. Вставьте его на странице Microsoft."
        }.onFailure { lastError = "Не удалось открыть страницу входа: ${it.message}" }
    }

    fun cancelMicrosoftLogin() {
        microsoftLoginJob?.cancel()
        microsoftLoginJob = null
        deviceCode = null
        deviceUrl = null
        deviceMessage = null
        awaitingMicrosoft = false
        status = "Вход отменён"
    }

    fun launch() {
        if (busy) return
        val account = selectedAccount
        val profile = profiles.firstOrNull { it.id == selectedProfileId }
        if (account == null) {
            lastError = "Добавьте офлайн-профиль или войдите через Microsoft."
            return
        }
        if (profile == null) {
            lastError = "Не выбрана версия Minecraft. Обновите список версий."
            return
        }
        scope.launch {
            setBusy(true, "Подготовка Minecraft ${profile.label}…")
            try {
                if (delayedLaunch) {
                    for (seconds in 5 downTo 1) {
                        withContext(Dispatchers.Main) { status = "Запуск через $seconds…" }
                        delay(1000)
                    }
                }
                val identity = if (account.kind == AccountKind.MICROSOFT) getMinecraftIdentity(account) else null
                val metadata = installProfile(profile)
                val java = ensureJava(metadata.obj("javaVersion").int("majorVersion", inferredJavaMajor(profile.minecraftVersion)))
                setProgress(0.93f, "Подготовка параметров запуска…")
                val args = buildLaunchArguments(metadata, profile, account, identity)
                val workingDirectory = File(root, "instances/${safeName(profile.id)}")
                workingDirectory.mkdirs()
                File(workingDirectory, ".installed").writeText(profile.id)
                val log = File(workingDirectory, "latest-launch.log")
                val process = ProcessBuilder(listOf(java.absolutePath) + args)
                    .directory(workingDirectory)
                    .redirectErrorStream(true)
                    .redirectOutput(log)
                    .start()
                withContext(Dispatchers.Main) {
                    status = "Minecraft запущен · журнал: ${log.absolutePath}"
                    progress = 1f
                    busy = false
                }
                scope.launch {
                    val exit = process.waitFor()
                    withContext(Dispatchers.Main) {
                        status = if (exit == 0) "Minecraft закрыт" else "Minecraft завершился с кодом $exit"
                        if (exit != 0) lastError = "Игра завершилась с кодом $exit. Журнал: ${log.absolutePath}"
                    }
                }
            } catch (failure: Exception) {
                withContext(Dispatchers.Main) {
                    lastError = failure.message ?: "Не удалось запустить Minecraft"
                    status = "Ошибка запуска"
                    busy = false
                }
            }
        }
    }

    fun openGameFolder() {
        runCatching {
            root.mkdirs()
            if (Desktop.isDesktopSupported()) Desktop.getDesktop().open(root)
        }.onFailure { lastError = "Не удалось открыть папку: ${it.message}" }
    }

    fun dismissError() { lastError = null }

    private suspend fun installProfile(profile: GameProfile): JsonObject = withContext(Dispatchers.IO) {
        val versionDir = File(gameRoot, "versions/${safeName(profile.id)}")
        val metadataFile = File(versionDir, "${safeName(profile.id)}.json")
        versionDir.mkdirs()
        val metadata = when (profile.loader) {
            LoaderKind.VANILLA -> {
                val url = profile.metadataUrl ?: error("Нет ссылки на манифест версии ${profile.id}")
                getJsonToFile(url, metadataFile, profile.metadataSha1)
            }
            LoaderKind.FABRIC -> {
                val loader = profile.loaderVersion ?: error("Не определена версия Fabric")
                val url = "$FABRIC_PROFILE/${profile.minecraftVersion}/loader/$loader/profile/json"
                val child = getJson(url)
                val parent = loadVanillaMetadata(profile.minecraftVersion)
                mergeMetadata(parent, child).also { writeVerifiedMetadata(metadataFile, it, null) }
            }
            LoaderKind.FORGE -> installForge(profile, versionDir)
        }
        profileMetadataCache[profile.id] = metadata
        installClient(metadata, profile.minecraftVersion)
        installLibraries(metadata)
        installAssets(metadata)
        File(root, "instances/${safeName(profile.id)}").mkdirs()
        metadata
    }

    private fun loadVanillaMetadata(version: String): JsonObject {
        val base = officialProfiles[version] ?: error("Версия Minecraft $version отсутствует в официальном списке")
        val file = File(gameRoot, "versions/${safeName(version)}/${safeName(version)}.json")
        return getJsonToFile(base.metadataUrl ?: error("Нет URL версии $version"), file, base.metadataSha1)
    }

    private fun installForge(profile: GameProfile, versionDir: File): JsonObject {
        val forgeVersion = profile.loaderVersion ?: error("Не определена версия Forge")
        val forgeCoordinate = "${profile.minecraftVersion}-$forgeVersion"
        val installer = File(root, "installers/forge-$forgeCoordinate-installer.jar")
        val url = "$FORGE_MAVEN/net/minecraftforge/forge/$forgeCoordinate/forge-$forgeCoordinate-installer.jar"
        download(url, installer, null)
        setProgress(0.18f, "Установка Forge ${profile.label}…")
        val installerJava = ensureJava(inferredJavaMajor(profile.minecraftVersion))
        val process = ProcessBuilder(installerJava.absolutePath, "-jar", installer.absolutePath, "--installClient", gameRoot.absolutePath)
            .directory(root)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        val code = process.waitFor()
        if (code != 0) error("Официальный установщик Forge завершился с кодом $code: ${output.takeLast(1200)}")
        val versionsDirectory = File(gameRoot, "versions")
        val expectedName = "${profile.minecraftVersion}-forge-$forgeVersion"
        val candidates = versionsDirectory.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.contains("forge", true) }
            .sortedByDescending { it.lastModified() }
        val installed = (listOf(File(versionsDirectory, expectedName)) + candidates)
            .distinctBy { it.absolutePath }
            .firstOrNull { File(it, "${it.name}.json").isFile }
            ?: error("Установщик Forge не создал профиль клиента. Вывод: ${output.takeLast(1200)}")
        val installedJson = File(installed, "${installed.name}.json")
        val child = JsonParser.parseString(installedJson.readText()).asJsonObject
        val inherited = child.string("inheritsFrom")
        val metadata = if (inherited.isNotBlank()) mergeMetadata(loadVanillaMetadata(inherited), child) else child
        val destination = File(versionDir, "${safeName(profile.id)}.json")
        writeVerifiedMetadata(destination, metadata, null)
        return metadata
    }

    private fun installClient(metadata: JsonObject, version: String) {
        val client = metadata.obj("downloads").obj("client")
        val url = client.string("url")
        if (url.isBlank()) error("В метаданных нет ссылки на клиентский jar для Minecraft $version")
        val id = metadata.string("id").ifBlank { version }
        val clientFile = File(gameRoot, "versions/${safeName(id)}/${safeName(id)}.jar")
        download(url, clientFile, client.string("sha1").ifBlank { null })
    }

    private fun installLibraries(metadata: JsonObject) {
        val libraries = metadata.array("libraries")
        val nativesDir = File(root, "natives/${safeName(metadata.string("id"))}")
        nativesDir.mkdirs()
        val osName = currentMinecraftOs()
        val arch = if (System.getProperty("os.arch").contains("64")) "64" else "32"
        libraries.forEachIndexed { index, element ->
            val library = element.asJsonObject
            if (!rulesAllow(library.arrayOrNull("rules"))) return@forEachIndexed
            val downloads = library.obj("downloads")
            val artifact = downloads.obj("artifact")
            if (artifact.string("url").isNotBlank()) {
                val target = File(gameRoot, "libraries/${artifact.string("path")}")
                download(artifact.string("url"), target, artifact.string("sha1").ifBlank { null })
            }
            val classifierMap = downloads.obj("classifiers")
            val nativeName = library.obj("natives").string(osName).replace("\${arch}", arch)
            val classifier = classifierMap.get(nativeName)?.asJsonObject
                ?: if (nativeName.isBlank()) null else classifierMap.get(nativeName.replace("natives-macos", "natives-osx"))?.asJsonObject
            if (classifier != null && classifier.string("url").isNotBlank()) {
                val archive = File(gameRoot, "libraries/${classifier.string("path")}")
                download(classifier.string("url"), archive, classifier.string("sha1").ifBlank { null })
                extractNatives(archive, nativesDir)
            }
            if (index % 10 == 0) setProgress(0.30f + index.toFloat() / libraries.size().coerceAtLeast(1) * 0.25f, "Библиотеки ${index + 1}/${libraries.size()}…")
        }
    }

    private fun installAssets(metadata: JsonObject) {
        val assetIndex = metadata.obj("assetIndex")
        val id = assetIndex.string("id")
        val indexUrl = assetIndex.string("url")
        if (id.isBlank() || indexUrl.isBlank()) return
        val indexFile = File(gameRoot, "assets/indexes/$id.json")
        download(indexUrl, indexFile, assetIndex.string("sha1").ifBlank { null })
        val objects = JsonParser.parseString(indexFile.readText()).asJsonObject.obj("objects").entrySet().toList()
        objects.forEachIndexed { index, entry ->
            val hash = entry.value.asJsonObject.string("hash")
            if (hash.length != 40) return@forEachIndexed
            val target = File(gameRoot, "assets/objects/${hash.substring(0, 2)}/$hash")
            download("https://resources.download.minecraft.net/${hash.substring(0, 2)}/$hash", target, hash)
            if (index % 100 == 0) setProgress(0.58f + index.toFloat() / objects.size.coerceAtLeast(1) * 0.31f, "Ресурсы ${index + 1}/${objects.size}…")
        }
    }

    private fun buildLaunchArguments(
        metadata: JsonObject,
        profile: GameProfile,
        account: LauncherAccount,
        identity: MinecraftIdentity?,
    ): List<String> {
        val versionId = metadata.string("id").ifBlank { profile.minecraftVersion }
        val gameDirectory = File(root, "instances/${safeName(profile.id)}").absolutePath
        val assetsDirectory = File(gameRoot, "assets").absolutePath
        val assetIndex = metadata.obj("assetIndex").string("id")
        val clientJar = File(gameRoot, "versions/${safeName(versionId)}/${safeName(versionId)}.jar")
        val classpath = buildClasspath(metadata, clientJar)
        val natives = File(root, "natives/${safeName(versionId)}").absolutePath
        val uuid = identity?.account?.minecraftId ?: offlineUuid(account.name)
        val accessToken = identity?.accessToken ?: "0"
        val placeholders = mapOf(
            "\${auth_player_name}" to account.name,
            "\${version_name}" to versionId,
            "\${game_directory}" to gameDirectory,
            "\${assets_root}" to assetsDirectory,
            "\${assets_index_name}" to assetIndex,
            "\${auth_uuid}" to uuid.replace("-", ""),
            "\${auth_access_token}" to accessToken,
            "\${user_type}" to if (identity == null) "legacy" else "msa",
            "\${version_type}" to profile.type,
            "\${user_properties}" to "{}",
            "\${clientid}" to "",
            "\${auth_xuid}" to "",
            "\${launcher_name}" to "kapylauncher",
            "\${launcher_version}" to "1.0.0",
            "\${natives_directory}" to natives,
            "\${classpath}" to classpath,
            "\${classpath_separator}" to File.pathSeparator,
            "\${resolution_width}" to "1280",
            "\${resolution_height}" to "720",
            "\${game_assets}" to assetsDirectory,
        )
        val jvm = mutableListOf<String>()
        jvm += "-Xmx2G"
        jvm += "-Djava.library.path=$natives"
        jvm += "-Dminecraft.launcher.brand=kapylauncher"
        jvm += "-Dminecraft.launcher.version=1.0.0"
        val modernArgs = metadata.obj("arguments")
        val jvmDefinitions = modernArgs.arrayOrNull("jvm")
        if (jvmDefinitions != null) jvm += resolveArgumentArray(jvmDefinitions, placeholders)
        val gameDefinitions = modernArgs.arrayOrNull("game")
        val game = if (gameDefinitions != null) resolveArgumentArray(gameDefinitions, placeholders) else {
            metadata.string("minecraftArguments").split(Regex("\\s+")).filter { it.isNotBlank() }.map { substitute(it, placeholders) }
        }
        val mainClass = metadata.string("mainClass").ifBlank { error("В метаданных не указан mainClass") }
        return jvm + listOf("-cp", classpath, mainClass) + game
    }

    private fun resolveArgumentArray(array: JsonArray, placeholders: Map<String, String>): List<String> {
        val result = mutableListOf<String>()
        array.forEach { item ->
            if (item.isJsonPrimitive) result += substitute(item.asString, placeholders)
            else if (item.isJsonObject) {
                val value = item.asJsonObject
                if (!rulesAllow(value.arrayOrNull("rules"), launchFeatures)) return@forEach
                val args = value.get("value")
                if (args != null && args.isJsonArray) args.asJsonArray.forEach { if (it.isJsonPrimitive) result += substitute(it.asString, placeholders) }
                else if (args != null && args.isJsonPrimitive) result += substitute(args.asString, placeholders)
            }
        }
        return result
    }

    private fun buildClasspath(metadata: JsonObject, clientJar: File): String {
        val files = mutableListOf<String>()
        metadata.array("libraries").forEach { element ->
            val library = element.asJsonObject
            if (!rulesAllow(library.arrayOrNull("rules"))) return@forEach
            val artifact = library.obj("downloads").obj("artifact")
            val path = artifact.string("path")
            if (path.isNotBlank()) files += File(gameRoot, "libraries/$path").absolutePath
            else {
                val coordinate = library.string("name").split("@", limit = 2).firstOrNull().orEmpty().split(":")
                if (coordinate.size >= 3) {
                    val classifier = coordinate.getOrNull(3)?.let { "-$it" }.orEmpty()
                    val ext = coordinate.getOrNull(4) ?: "jar"
                    val mavenPath = coordinate[0].replace('.', '/') + "/${coordinate[1]}/${coordinate[2]}/${coordinate[1]}-${coordinate[2]}$classifier.$ext"
                    files += File(gameRoot, "libraries/$mavenPath").absolutePath
                }
            }
        }
        files += clientJar.absolutePath
        return files.distinct().joinToString(File.pathSeparator)
    }

    private suspend fun getMinecraftIdentity(account: LauncherAccount): MinecraftIdentity {
        val clientId = microsoftClientId ?: error("Microsoft client ID не настроен")
        val refreshToken = refreshTokens[account.id] ?: tokenStore.read(account.id)
            ?: error("Нужно снова войти в Microsoft: refresh token недоступен в системном хранилище.")
        val response = postForm(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
            mapOf(
                "client_id" to clientId,
                "grant_type" to "refresh_token",
                "refresh_token" to refreshToken,
                "scope" to "XboxLive.signin offline_access",
            ),
        )
        val microsoftAccess = response.string("access_token").ifBlank { error("Microsoft не вернул access token") }
        val updatedRefresh = response.string("refresh_token").ifBlank { refreshToken }
        refreshTokens[account.id] = updatedRefresh
        runCatching { tokenStore.store(account.id, updatedRefresh) }
        val identity = exchangeMicrosoftForMinecraft(microsoftAccess)
        return identity.copy(account = account.copy(name = identity.account.name, minecraftId = identity.account.minecraftId))
    }

    private suspend fun beginDeviceLogin(clientId: String): DeviceCode = withContext(Dispatchers.IO) {
        val json = postForm(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
            mapOf("client_id" to clientId, "scope" to "XboxLive.signin offline_access"),
        )
        DeviceCode(
            userCode = json.string("user_code"),
            deviceCode = json.string("device_code"),
            verificationUri = json.string("verification_uri").ifBlank { MICROSOFT_DEVICE_URL },
            expiresIn = json.int("expires_in", 900),
            interval = json.int("interval", 5),
        ).also { if (it.userCode.isBlank() || it.deviceCode.isBlank()) error(json.string("error_description").ifBlank { "Пустой ответ device-code endpoint" }) }
    }

    private suspend fun pollDeviceLogin(device: DeviceCode, clientId: String): MicrosoftToken = withContext(Dispatchers.IO) {
        val until = System.currentTimeMillis() + device.expiresIn * 1000L
        var interval = device.interval
        while (System.currentTimeMillis() < until) {
            delay(interval * 1000L)
            val response = postForm(
                "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
                mapOf(
                    "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id" to clientId,
                    "device_code" to device.deviceCode,
                ),
                acceptOAuthErrors = true,
            )
            when (response.string("error")) {
                "" -> {
                    val access = response.string("access_token")
                    val refresh = response.string("refresh_token")
                    if (access.isNotBlank() && refresh.isNotBlank()) return@withContext MicrosoftToken(access, refresh)
                    error("В ответе Microsoft отсутствует токен")
                }
                "authorization_pending" -> Unit
                "slow_down" -> interval += 5
                "authorization_declined" -> error("Вход отклонён пользователем")
                "expired_token" -> error("Срок действия кода истёк. Запустите вход ещё раз.")
                else -> error(response.string("error_description").ifBlank { response.string("error") })
            }
        }
        error("Срок действия кода входа истёк")
    }

    private fun exchangeMicrosoftForMinecraft(microsoftAccess: String): MinecraftIdentity {
        val user = postJson(
            "https://user.auth.xboxlive.com/user/authenticate",
            jsonObject(
                "Properties" to jsonObject("AuthMethod" to "RPS", "SiteName" to "user.auth.xboxlive.com", "RpsTicket" to "d=$microsoftAccess"),
                "RelyingParty" to "http://auth.xboxlive.com",
                "TokenType" to "JWT",
            ),
        )
        val userToken = user.string("Token")
        val userHash = user.obj("DisplayClaims").array("xui").firstOrNull()?.asJsonObject?.string("uhs")
            ?: error("Xbox не вернул user hash")
        val xsts = postJson(
            "https://xsts.auth.xboxlive.com/xsts/authorize",
            jsonObject(
                "Properties" to jsonObject("SandboxId" to "RETAIL", "UserTokens" to listOf(userToken)),
                "RelyingParty" to "rp://api.minecraftservices.com/",
                "TokenType" to "JWT",
            ),
        )
        val xstsToken = xsts.string("Token")
        val minecraft = postJson(
            "https://api.minecraftservices.com/authentication/login_with_xbox",
            jsonObject("identityToken" to "XBL3.0 x=$userHash;$xstsToken"),
        )
        val access = minecraft.string("access_token").ifBlank { error("Minecraft Services не вернул токен") }
        val profile = getJson("https://api.minecraftservices.com/minecraft/profile", "Bearer $access")
        val name = profile.string("name").ifBlank { error("У этого Microsoft-аккаунта нет профиля Minecraft Java Edition") }
        val uuid = profile.string("id").ifBlank { error("Minecraft Services не вернул UUID профиля") }
        return MinecraftIdentity(LauncherAccount(UUID.randomUUID().toString(), name, AccountKind.MICROSOFT, uuid), access)
    }

    private fun ensureJava(major: Int): File {
        findSystemJava(major)?.let { return it }
        val os = when (System.getProperty("os.name").lowercase(Locale.ROOT)) {
            "mac os x", "macos" -> "mac"
            "windows" -> "windows"
            "linux" -> "linux"
            else -> error("Автозагрузка Java не поддерживает ОС ${System.getProperty("os.name")}")
        }
        val arch = when (System.getProperty("os.arch").lowercase(Locale.ROOT)) {
            "aarch64", "arm64" -> "aarch64"
            "x86", "i386", "i686" -> "x86"
            else -> "x64"
        }
        val installDir = File(root, "runtimes/temurin-$major-$os-$arch")
        findJavaIn(installDir)?.let { return it }
        installDir.mkdirs()
        val archive = File(installDir, if (os == "windows") "runtime.zip" else "runtime.tar.gz")
        val url = "https://api.adoptium.net/v3/binary/latest/$major/ga/$os/$arch/jdk/hotspot/normal/eclipse"
        setProgress(0.12f, "Загрузка Java $major для этой системы…")
        download(url, archive, null)
        setProgress(0.2f, "Распаковка Java $major…")
        if (os == "windows") extractZip(archive, installDir) else {
            val tar = if (os == "windows") "tar.exe" else "tar"
            val process = ProcessBuilder(tar, "-xzf", archive.absolutePath, "-C", installDir.absolutePath)
                .redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().readText()
            if (process.waitFor() != 0) error("Не удалось распаковать Java $major: ${output.takeLast(500)}")
        }
        archive.delete()
        return findJavaIn(installDir) ?: error("Java $major скачана, но исполняемый файл не найден")
    }

    private fun findSystemJava(requiredMajor: Int): File? {
        val command = if (System.getProperty("os.name").startsWith("Windows", true)) "where" else "which"
        val process = runCatching { ProcessBuilder(command, "java").redirectErrorStream(true).start() }.getOrNull() ?: return null
        val candidates = process.inputStream.bufferedReader().readLines().map(::File)
        process.waitFor()
        return candidates.firstOrNull { candidate ->
            if (!candidate.isFile) return@firstOrNull false
            val versionProcess = runCatching { ProcessBuilder(candidate.absolutePath, "-version").redirectErrorStream(true).start() }.getOrNull() ?: return@firstOrNull false
            val line = versionProcess.inputStream.bufferedReader().readText()
            versionProcess.waitFor()
            val major = Regex("version \\\"(?:1\\.)?(\\d+)").find(line)?.groupValues?.getOrNull(1)?.toIntOrNull()
            major != null && major >= requiredMajor
        }
    }

    private fun javaExecutablePath(): String = findSystemJava(8)?.absolutePath ?: error("Для запуска установщика Forge требуется Java 8+.")

    private fun findJavaIn(directory: File): File? {
        val name = if (System.getProperty("os.name").startsWith("Windows", true)) "java.exe" else "java"
        return directory.walkTopDown().maxDepth(7).firstOrNull { it.isFile && it.name == name && (it.parentFile?.name == "bin" || it.parentFile?.name == "Contents") }
            ?.also { if (!System.getProperty("os.name").startsWith("Windows", true)) it.setExecutable(true) }
    }

    private fun inferredJavaMajor(version: String): Int {
        val parts = version.split('.').mapNotNull { it.toIntOrNull() }
        return when {
            parts.firstOrNull() == 1 && parts.getOrNull(1)?.let { it <= 16 } == true -> 8
            parts.firstOrNull() == 1 && parts.getOrNull(1) == 17 -> 16
            parts.firstOrNull() == 1 && parts.getOrNull(1)?.let { it <= 20 } == true -> 17
            parts.firstOrNull() == 1 && parts.getOrNull(1) == 21 && parts.getOrNull(2)?.let { it < 5 } == true -> 17
            else -> 21
        }
    }

    private fun download(url: String, target: File, sha1: String?) {
        if (url.isBlank()) error("Пустой URL загрузки")
        target.parentFile?.mkdirs()
        if (target.isFile && target.length() > 0 && (!verifyFiles || sha1 == null || sha1.equals(sha1(target), true))) return
        val partial = File(target.parentFile, "${target.name}.part")
        val connection = openConnection(url)
        try {
            connection.connectTimeout = 20_000
            connection.readTimeout = 60_000
            val code = connection.responseCode
            if (code !in 200..299) error("Загрузка завершилась HTTP $code: $url")
            connection.inputStream.use { input -> FileOutputStream(partial).use { output -> input.copyTo(output) } }
            if (sha1 != null && !sha1.equals(sha1(partial), true)) {
                partial.delete()
                error("Контрольная сумма не совпала: ${target.name}")
            }
            if (target.exists() && !target.delete()) error("Не удалось заменить файл ${target.absolutePath}")
            if (!partial.renameTo(target)) error("Не удалось сохранить ${target.absolutePath}")
        } finally { connection.disconnect() }
    }

    private fun extractNatives(archive: File, destination: File) {
        ZipInputStream(BufferedInputStream(FileInputStream(archive))).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val name = entry.name.replace('\\', '/')
                if (entry.isDirectory || name.startsWith("META-INF/") || name.contains("../")) continue
                val output = File(destination, name)
                if (!output.canonicalPath.startsWith(destination.canonicalPath + File.separator)) continue
                output.parentFile?.mkdirs()
                FileOutputStream(output).use { zip.copyTo(it) }
            }
        }
    }

    private fun extractZip(archive: File, destination: File) {
        ZipInputStream(BufferedInputStream(FileInputStream(archive))).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val output = File(destination, entry.name)
                if (!output.canonicalPath.startsWith(destination.canonicalPath + File.separator)) continue
                if (entry.isDirectory) output.mkdirs() else {
                    output.parentFile?.mkdirs()
                    FileOutputStream(output).use { zip.copyTo(it) }
                }
            }
        }
    }

    private val launchFeatures = mapOf("has_custom_resolution" to true)

    private fun rulesAllow(rules: JsonArray?, features: Map<String, Boolean> = emptyMap()): Boolean {
        if (rules == null) return true
        var allowed = false
        for (ruleElement in rules) {
            val rule = ruleElement.asJsonObject
            val os = rule.obj("os").string("name")
            val current = currentMinecraftOs()
            val osMatches = os.isBlank() || os == current
            val arch = rule.obj("os").string("arch")
            val archMatches = arch.isBlank() || Regex(arch).containsMatchIn(System.getProperty("os.arch"))
            val featureMatches = rule.obj("features").entrySet().all { (name, expected) ->
                features[name] == expected.asBoolean
            }
            if (osMatches && archMatches && featureMatches) allowed = rule.string("action") == "allow"
        }
        return allowed
    }

    private fun currentMinecraftOs(): String = when {
        System.getProperty("os.name").startsWith("Windows", true) -> "windows"
        System.getProperty("os.name").startsWith("Mac", true) -> "osx"
        else -> "linux"
    }

    private fun mergeMetadata(base: JsonObject, child: JsonObject): JsonObject {
        val merged = base.deepCopy()
        child.entrySet().forEach { (key, value) -> merged.add(key, value.deepCopy()) }
        val libraries = JsonArray()
        val seen = mutableSetOf<String>()
        listOf(base.array("libraries"), child.array("libraries")).forEach { array ->
            array.forEach { library ->
                val name = library.asJsonObject.string("name")
                if (seen.add(name)) libraries.add(library.deepCopy())
            }
        }
        merged.add("libraries", libraries)
        val baseArgs = base.obj("arguments")
        val childArgs = child.obj("arguments")
        if (baseArgs.size() > 0 || childArgs.size() > 0) {
            val arguments = JsonObject()
            listOf("jvm", "game").forEach { key ->
                val array = JsonArray()
                baseArgs.arrayOrNull(key)?.forEach { array.add(it.deepCopy()) }
                childArgs.arrayOrNull(key)?.forEach { array.add(it.deepCopy()) }
                if (array.size() > 0) arguments.add(key, array)
            }
            merged.add("arguments", arguments)
        }
        return merged
    }

    private fun writeVerifiedMetadata(file: File, json: JsonObject, sha1: String?) {
        file.parentFile?.mkdirs()
        file.writeText(gson.toJson(json))
    }

    private fun getJsonToFile(url: String, target: File, expectedSha1: String?): JsonObject {
        download(url, target, expectedSha1)
        return runCatching { JsonParser.parseString(target.readText()).asJsonObject }
            .getOrElse { throw IllegalStateException("Некорректные метаданные Minecraft: ${it.message}") }
    }

    private fun postForm(url: String, values: Map<String, String>, acceptOAuthErrors: Boolean = false): JsonObject {
        val body = values.entries.joinToString("&") { "${formEncode(it.key)}=${formEncode(it.value)}" }
        return requestJson("POST", url, body, "application/x-www-form-urlencoded", acceptOAuthErrors = acceptOAuthErrors)
    }

    private fun postJson(url: String, body: JsonObject): JsonObject = requestJson("POST", url, gson.toJson(body), "application/json")

    private fun getJson(url: String, bearer: String? = null): JsonObject = requestJson("GET", url, bearer = bearer)

    private fun getJsonArray(url: String): JsonArray {
        val connection = openConnection(url)
        try {
            connection.setRequestProperty("User-Agent", httpUserAgent)
            connection.setRequestProperty("Accept", "application/json")
            val code = connection.responseCode
            if (code !in 200..299) error("HTTP $code при загрузке $url")
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            return JsonParser.parseString(body).asJsonArray
        } finally { connection.disconnect() }
    }

    private fun requestJson(
        method: String,
        url: String,
        body: String? = null,
        contentType: String? = null,
        bearer: String? = null,
        acceptOAuthErrors: Boolean = false,
    ): JsonObject {
        val connection = openConnection(url)
        try {
            connection.requestMethod = method
            connection.setRequestProperty("User-Agent", httpUserAgent)
            connection.setRequestProperty("Accept", "application/json")
            bearer?.let { connection.setRequestProperty("Authorization", it) }
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", contentType ?: "application/json")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val response = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299 && !acceptOAuthErrors) {
                val parsed = runCatching { JsonParser.parseString(response).asJsonObject }.getOrNull()
                val detail = parsed?.string("errorMessage")?.ifBlank { null }
                    ?: parsed?.string("error_description")?.ifBlank { null }
                    ?: parsed?.string("error")?.ifBlank { null }
                    ?: response.take(400)
                error("HTTP $code: $detail")
            }
            return JsonParser.parseString(response).asJsonObject
        } finally { connection.disconnect() }
    }

    private fun openConnection(url: String): HttpURLConnection = (URI(url).toURL().openConnection() as HttpURLConnection).apply {
        connectTimeout = 20_000
        readTimeout = 60_000
    }

    private fun jsonObject(vararg pairs: Pair<String, Any?>): JsonObject = JsonParser.parseString(gson.toJson(pairs.toMap())).asJsonObject
    private fun formEncode(value: String): String = java.net.URLEncoder.encode(value, Charsets.UTF_8)
    private fun substitute(argument: String, values: Map<String, String>): String = values.entries.fold(argument) { acc, item -> acc.replace(item.key, item.value) }

    private fun offlineUuid(name: String): String {
        val bytes = MessageDigest.getInstance("MD5").digest("OfflinePlayer:$name".toByteArray(Charsets.UTF_8))
        bytes[6] = (bytes[6].toInt() and 0x0f or 0x30).toByte()
        bytes[8] = (bytes[8].toInt() and 0x3f or 0x80).toByte()
        val hex = bytes.joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
    }

    private fun sha1(file: File): String {
        val digest = MessageDigest.getInstance("SHA-1")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun safeName(value: String): String = value.replace(Regex("[^A-Za-z0-9._-]"), "_").take(120).ifBlank { "default" }

    private suspend fun setBusy(value: Boolean, text: String) = withContext(Dispatchers.Main) {
        busy = value
        status = text
        if (value) { progress = 0f; lastError = null }
    }

    private fun setProgress(value: Float, text: String) {
        progress = value.coerceIn(0f, 1f)
        status = text
    }

    private fun restoreAccounts() {
        runCatching {
            if (accountsFile.isFile) {
                val saved = JsonParser.parseString(accountsFile.readText()).asJsonObject
                saved.array("accounts").forEach { item ->
                    val json = item.asJsonObject
                    val kind = runCatching { AccountKind.valueOf(json.string("kind")) }.getOrDefault(AccountKind.OFFLINE)
                    accounts.add(LauncherAccount(json.string("id"), json.string("name"), kind, json.string("minecraftId").ifBlank { null }))
                }
                selectedAccountId = saved.string("selected").takeIf { id -> accounts.any { it.id == id } }
                    ?: accounts.firstOrNull()?.id
            }
        }.onFailure { lastError = "Не удалось прочитать профили: ${it.message}" }
    }

    private fun saveAccounts() {
        runCatching {
            root.mkdirs()
            val objectValue = JsonObject()
            objectValue.add("accounts", JsonParser.parseString(gson.toJson(accounts.toList())).asJsonArray)
            objectValue.addProperty("selected", selectedAccountId.orEmpty())
            val temporary = File(accountsFile.parentFile, "accounts.json.part")
            temporary.writeText(gson.toJson(objectValue))
            if (accountsFile.exists()) accountsFile.delete()
            temporary.renameTo(accountsFile)
        }.onFailure { lastError = "Не удалось сохранить профили: ${it.message}" }
    }

    override fun close() { scope.cancel() }

    private data class MicrosoftToken(val accessToken: String, val refreshToken: String)

    private class SecureTokenStore(private val fallbackDirectory: File) {
        fun store(accountId: String, token: String) {
            when {
                isMac() -> runSecurity(listOf("add-generic-password", "-U", "-s", "app.kapylaun.ch.microsoft", "-a", accountId, "-w", token))
                isWindows() -> storeDpapi(accountId, token)
                else -> storeSecretService(accountId, token)
            }
        }

        fun read(accountId: String): String? = runCatching {
            when {
                isMac() -> runSecurity(listOf("find-generic-password", "-s", "app.kapylaun.ch.microsoft", "-a", accountId, "-w"))
                isWindows() -> readDpapi(accountId)
                else -> readSecretService(accountId)
            }.trim().takeIf { it.isNotBlank() }
        }.getOrNull()

        fun delete(accountId: String) {
            runCatching {
                when {
                    isMac() -> runSecurity(listOf("delete-generic-password", "-s", "app.kapylaun.ch.microsoft", "-a", accountId))
                    isWindows() -> File(fallbackDirectory, "$accountId.dpapi").delete()
                    else -> runSecretTool(listOf("clear", "--label=kapylauncher", "account", accountId))
                }
            }
        }

        private fun storeDpapi(id: String, token: String) {
            val encrypted = powershellForInput("\$s = ConvertTo-SecureString -String ([Console]::In.ReadToEnd()) -AsPlainText -Force; ConvertFrom-SecureString \$s")
                .runWithInput(token)
            fallbackDirectory.mkdirs()
            File(fallbackDirectory, "$id.dpapi").writeText(encrypted)
        }

        private fun readDpapi(id: String): String {
            val file = File(fallbackDirectory, "$id.dpapi")
            if (!file.isFile) return ""
            val command = "\$s = ConvertTo-SecureString -String '${file.readText().replace("'", "''")}' ; \$p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(\$s); try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR(\$p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(\$p) }"
            return powershell(command)
        }

        private fun storeSecretService(id: String, token: String) {
            runSecretTool(listOf("store", "--label=kapylauncher", "application", "kapylauncher", "account", id), token)
        }

        private fun readSecretService(id: String): String = runSecretTool(listOf("lookup", "application", "kapylauncher", "account", id))

        private fun runSecretTool(args: List<String>, stdin: String? = null): String = runCommand(listOf("secret-tool") + args, stdin)
        private fun runSecurity(args: List<String>): String = runCommand(listOf("/usr/bin/security") + args)
        private fun powershellForInput(script: String): TokenProcess = TokenProcess(listOf("powershell", "-NoProfile", "-NonInteractive", "-Command", script))
        private fun powershell(script: String): String = runCommand(listOf("powershell", "-NoProfile", "-NonInteractive", "-Command", script))

        private fun runCommand(args: List<String>, stdin: String? = null): String {
            val process = ProcessBuilder(args).redirectErrorStream(true).start()
            if (stdin != null) process.outputStream.bufferedWriter().use { it.write(stdin) } else process.outputStream.close()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            if (process.waitFor() != 0) error(output.ifBlank { "Системное хранилище учётных данных недоступно" })
            return output.trim()
        }

        private fun isMac() = System.getProperty("os.name").startsWith("Mac", true)
        private fun isWindows() = System.getProperty("os.name").startsWith("Windows", true)

        private data class TokenProcess(private val command: List<String>) {
            fun runWithInput(value: String): String {
                val process = ProcessBuilder(command).redirectErrorStream(true).start()
                process.outputStream.bufferedWriter().use { it.write(value) }
                val output = process.inputStream.bufferedReader().use { it.readText() }
                if (process.waitFor() != 0) error(output)
                return output.trim()
            }
        }
    }

    companion object {
        private const val MOJANG_MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        private const val FABRIC_GAME_VERSIONS = "https://meta.fabricmc.net/v2/versions/game"
        private const val FABRIC_LOADER_VERSIONS = "https://meta.fabricmc.net/v2/versions/loader"
        private const val FABRIC_PROFILE = "https://meta.fabricmc.net/v2/versions/loader"
        private const val FORGE_PROMOTIONS = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
        private const val FORGE_MAVEN = "https://maven.minecraftforge.net"
        private const val MICROSOFT_DEVICE_URL = "https://microsoft.com/devicelogin"
    }
}

private fun JsonObject.obj(name: String): JsonObject = get(name)?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject()
private fun JsonObject.array(name: String): JsonArray = get(name)?.takeIf { it.isJsonArray }?.asJsonArray ?: JsonArray()
private fun JsonObject.arrayOrNull(name: String): JsonArray? = get(name)?.takeIf { it.isJsonArray }?.asJsonArray
private fun JsonObject.string(name: String): String = get(name)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
private fun JsonObject.int(name: String, fallback: Int = 0): Int = get(name)?.takeIf { it.isJsonPrimitive }?.asInt ?: fallback
private fun JsonObject.bool(name: String): Boolean = get(name)?.takeIf { it.isJsonPrimitive }?.asBoolean ?: false
private fun JsonElement.asJsonObjectOrNull(): JsonObject? = takeIf { it.isJsonObject }?.asJsonObject

private fun jsonElementToMapValue(element: JsonElement): Any = when {
    element.isJsonObject -> element.asJsonObject.entrySet().associate { it.key to jsonElementToMapValue(it.value) }
    element.isJsonArray -> element.asJsonArray.map(::jsonElementToMapValue)
    element.isJsonPrimitive && element.asJsonPrimitive.isBoolean -> element.asBoolean
    element.isJsonPrimitive && element.asJsonPrimitive.isNumber -> element.asNumber
    element.isJsonPrimitive -> element.asString
    else -> ""
}

private fun sha1(file: Path): String = MessageDigest.getInstance("SHA-1").digest(Files.readAllBytes(file)).joinToString("") { "%02x".format(it) }
