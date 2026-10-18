import AppKit
import CryptoKit
import Foundation
import Security

struct MinecraftVersion: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let url: URL
    let releaseTime: String
    var sha1: String? = nil
}

struct LauncherUpdate: Identifiable, Equatable {
    let id: String
    let releaseURL: URL
    let downloadURL: URL?
    let checksumURL: URL?
    let sha256: String?
    let notes: String

    var canInstall: Bool { downloadURL != nil && (sha256 != nil || checksumURL != nil) }
}

enum VersionLoader: String, CaseIterable, Identifiable {
    case all = "Все"
    case vanilla = "Vanilla"
    case fabric = "Fabric"
    case forge = "Forge"
    case neoForge = "NeoForge"
    case quilt = "Quilt"
    case optiFine = "OptiFine"

    var id: String { rawValue }
}

private struct VersionManifest: Codable {
    let latest: Latest
    let versions: [MinecraftVersion]

    struct Latest: Codable {
        let release: String
        let snapshot: String
    }
}

private struct ExtraVersionManifest: Codable {
    let versions: [MinecraftVersion]
}

enum AccountKind: String, Codable {
    case offline
    case microsoft
}

struct OfflineAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String
    var kind: AccountKind?
    var minecraftProfileID: String?

    init(username: String) {
        self.id = UUID()
        self.username = username
        self.kind = .offline
        self.minecraftProfileID = nil
    }

    init(username: String, minecraftProfileID: String) {
        self.id = UUID()
        self.username = username
        self.kind = .microsoft
        self.minecraftProfileID = minecraftProfileID
    }

    var accountKind: AccountKind { kind ?? .offline }
}

struct MicrosoftDeviceLogin: Equatable, Identifiable {
    var id: String { code }
    let code: String
    let verificationURL: URL
    let message: String
}

enum LauncherFailure: LocalizedError {
    case invalidMetadata
    case javaMissing(Int)
    case runtime(String)
    case versionMissing
    case launchFailed(String)
    case authentication(String)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "Mojang вернул некорректные метаданные версии."
        case .javaMissing(let majorVersion): "Java \(majorVersion) не найдена. Установите JDK \(majorVersion) или официальный Java runtime Minecraft."
        case .runtime(let reason): "Не удалось подготовить Java runtime Minecraft: \(reason)"
        case .versionMissing: "Выбранная версия отсутствует в манифесте Mojang."
        case .launchFailed(let reason): "Не удалось запустить Minecraft: \(reason)"
        case .authentication(let reason): "Ошибка входа Microsoft: \(reason)"
        }
    }
}

@MainActor
final class MinecraftEngine: ObservableObject {
    static let microsoftClientID = "93473d67-ba81-449c-8fb6-1a261ba5d41a"
    @Published private(set) var versions: [MinecraftVersion] = []
    @Published var accounts: [OfflineAccount] = []
    @Published var selectedAccountID: UUID?
    @Published var selectedVersionID = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshingVersions = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Загрузка версий…"
    @Published var lastError: String?
    @Published var showSnapshots = false
    @Published var loader: VersionLoader = .all
    @Published var installedOnly = false
    @Published private(set) var installedVersionIDs: Set<String> = []
    @Published var microsoftDeviceLogin: MicrosoftDeviceLogin?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var availableLauncherUpdate: LauncherUpdate?
    @Published private(set) var isUpdatingLauncher = false
    @Published private(set) var updateProgress = 0.0
    @Published private(set) var updateStatus = ""

    private var officialVersions: [MinecraftVersion] = []
    private var minecraftProcess: Process?

    private let session: URLSession
    private let fileManager = FileManager.default
    private let accountsKey = "kapylauncher.offlineAccounts"
    private let selectedAccountKey = "kapylauncher.selectedAccount"
    private var activeAuthenticationID: UUID?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
        restoreAccounts()
    }

    var visibleVersions: [MinecraftVersion] {
        versions.filter { version in
            let snapshotAllowed = showSnapshots || version.type == "release" || version.type == "modified"
            guard snapshotAllowed else { return false }
            guard !installedOnly || installedVersionIDs.contains(version.id) else { return false }
            switch loader {
            case .all: return true
            case .vanilla: return version.type != "modified"
            case .fabric: return version.id.lowercased().hasPrefix("fabric ")
            case .forge: return version.id.lowercased().hasPrefix("forge ")
            case .neoForge: return version.id.lowercased().hasPrefix("neoforge ")
            case .quilt: return version.id.lowercased().hasPrefix("quilt ")
            case .optiFine: return version.id.lowercased().hasPrefix("optifine ")
            }
        }
    }

    var selectedAccount: OfflineAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    func bootstrap() async {
        guard !isRefreshingVersions else { return }
        isRefreshingVersions = true
        progress = 0
        defer { isRefreshingVersions = false }
        do {
            status = "Получение списка версий…"
            async let officialRequest = session.data(from: URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!)
            async let extraRequest = session.data(from: URL(string: "https://repo.llaun.ch/versions/versions.json")!)
            let (officialResult, extraResult) = try await (officialRequest, extraRequest)
            try Self.validate(officialResult.1)
            try Self.validate(extraResult.1)
            let manifest = try JSONDecoder().decode(VersionManifest.self, from: officialResult.0)
            let extra = try JSONDecoder().decode(ExtraVersionManifest.self, from: extraResult.0)
            officialVersions = manifest.versions
            let secureExtra = extra.versions.map { version in
                var components = URLComponents(url: version.url, resolvingAgainstBaseURL: false)
                if components?.scheme == "http" { components?.scheme = "https" }
                return MinecraftVersion(
                    id: version.id,
                    type: version.type,
                    url: components?.url ?? version.url,
                    releaseTime: version.releaseTime,
                    sha1: version.sha1
                )
            }
            versions = secureExtra + manifest.versions
            refreshInstalledVersions()
            if selectedVersionID.isEmpty || !versions.contains(where: { $0.id == selectedVersionID }) {
                selectedVersionID = manifest.latest.release
            }
            progress = 1
            status = "Готово"
        } catch {
            lastError = error.localizedDescription
            status = "Не удалось загрузить версии"
        }
    }

    func checkForLauncherUpdates() async {
        updateStatus = "Проверка обновлений…"
        do {
            let endpoint = URL(string: "https://api.github.com/repos/kapybarovv/kapylaunch/releases/latest")!
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("kapylauncher macOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let releaseURLString = release["html_url"] as? String,
                  let releaseURL = URL(string: releaseURLString),
                  let assets = release["assets"] as? [[String: Any]] else {
                throw LauncherFailure.runtime("GitHub вернул некорректные данные релиза")
            }

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            guard Self.compareVersions(tag, currentVersion) == .orderedDescending else {
                availableLauncherUpdate = nil
                updateStatus = "Установлена последняя версия (\(currentVersion))"
                return
            }

            let archiveName = "kapylauncher-macos-universal.zip"
            let archive = assets.first { $0["name"] as? String == archiveName }
            let downloadURL = (archive?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let digestValue = archive?["digest"] as? String
            let digest = digestValue.flatMap { value -> String? in
                guard value.hasPrefix("sha256:") else { return nil }
                return String(value.dropFirst("sha256:".count)).lowercased()
            }
            let checksumAsset = assets.first { $0["name"] as? String == "\(archiveName).sha256" }
            let checksumURL = (checksumAsset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let releaseNotes = release["body"] as? String ?? ""
            availableLauncherUpdate = LauncherUpdate(
                id: tag,
                releaseURL: releaseURL,
                downloadURL: downloadURL,
                checksumURL: checksumURL,
                sha256: digest,
                notes: String(releaseNotes.prefix(1_000))
            )
            updateStatus = "Доступно обновление \(tag)"
        } catch {
            updateStatus = "Проверка не удалась: \(error.localizedDescription)"
        }
    }

    func installLauncherUpdate() async {
        guard let update = availableLauncherUpdate,
              update.canInstall,
              let downloadURL = update.downloadURL else {
            if let releaseURL = availableLauncherUpdate?.releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
            return
        }

        let runningApp = Bundle.main.bundleURL.standardizedFileURL
        guard runningApp.pathExtension == "app",
              !runningApp.path.contains("/AppTranslocation/"),
              !runningApp.path.hasPrefix("/Volumes/") else {
            updateStatus = "Переместите kapylauncher в папку Applications, затем повторите обновление."
            return
        }

        isUpdatingLauncher = true
        updateProgress = 0.04
        updateStatus = "Скачивание обновления…"
        let workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "kapylauncher-update-\(UUID().uuidString)", directoryHint: .isDirectory)

        do {
            guard update.sha256 != nil || update.checksumURL != nil else {
                throw LauncherFailure.runtime("у релиза нет контрольной суммы для проверки")
            }
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let archiveURL = workDirectory.appending(path: "kapylauncher-update.zip")
            let (temporaryArchive, response) = try await session.download(from: downloadURL)
            try Self.validate(response)
            try FileManager.default.moveItem(at: temporaryArchive, to: archiveURL)
            updateProgress = 0.48

            let expectedHash: String
            if let sha256 = update.sha256 {
                expectedHash = sha256
            } else if let checksumURL = update.checksumURL {
                let (checksumData, checksumResponse) = try await session.data(from: checksumURL)
                try Self.validate(checksumResponse)
                let checksumText = String(data: checksumData, encoding: .utf8) ?? ""
                guard let firstToken = checksumText.split(whereSeparator: \.isWhitespace).first,
                      firstToken.count == 64,
                      firstToken.allSatisfy(\.isHexDigit) else {
                    throw LauncherFailure.runtime("контрольная сумма релиза некорректна")
                }
                expectedHash = String(firstToken).lowercased()
            } else {
                throw LauncherFailure.runtime("отсутствует контрольная сумма релиза")
            }

            guard try Self.sha256(at: archiveURL) == expectedHash else {
                throw LauncherFailure.runtime("контрольная сумма архива обновления не совпала")
            }
            updateProgress = 0.68
            updateStatus = "Проверка приложения…"

            let extractedDirectory = workDirectory.appending(path: "extracted", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
            try Self.runTool("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path])
            let newApp = extractedDirectory.appending(path: "kapylauncher.app", directoryHint: .isDirectory)
            guard let newBundle = Bundle(url: newApp),
                  newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw LauncherFailure.runtime("архив не содержит ожидаемое приложение kapylauncher")
            }
            try Self.runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", newApp.path])
            updateProgress = 0.88

            let helperURL = workDirectory.appending(path: "apply-update.sh")
            try Self.updateHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [
                helperURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                newApp.path,
                runningApp.path,
                workDirectory.path
            ]
            try helper.run()
            updateStatus = "Обновление подготовлено. Перезапускаю лаунчер…"
            updateProgress = 1
            isUpdatingLauncher = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            isUpdatingLauncher = false
            updateProgress = 0
            updateStatus = "Не удалось обновить: \(error.localizedDescription)"
        }
    }

    private static func compareVersions(_ candidate: String, _ current: String) -> ComparisonResult {
        func numbers(_ version: String) -> [Int] {
            version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let candidateParts = numbers(candidate)
        let currentParts = numbers(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart ? .orderedDescending : .orderedAscending
            }
        }
        return .orderedSame
    }

    private static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LauncherFailure.runtime(message.isEmpty ? "команда \(URL(fileURLWithPath: executable).lastPathComponent) завершилась с ошибкой" : message)
        }
    }

    private static let updateHelperScript = """
    #!/bin/bash
    set -euo pipefail
    old_pid="$1"
    staged_app="$2"
    target_app="$3"
    work_dir="$4"
    parent_dir="$(/usr/bin/dirname "$target_app")"
    backup_app="$parent_dir/.kapylauncher-previous-$$.app"
    while /bin/kill -0 "$old_pid" 2>/dev/null; do /bin/sleep 0.25; done
    if [ -w "$parent_dir" ]; then
      /bin/mv "$target_app" "$backup_app"
      if ! /usr/bin/ditto "$staged_app" "$target_app"; then
        /bin/mv "$backup_app" "$target_app"
        exit 1
      fi
    else
      /usr/bin/osascript - "$staged_app" "$target_app" "$backup_app" <<'APPLESCRIPT'
    on run argv
      set stagedApp to item 1 of argv
      set targetApp to item 2 of argv
      set backupApp to item 3 of argv
      set commandText to "/bin/mv " & quoted form of targetApp & " " & quoted form of backupApp & "; if ! /usr/bin/ditto " & quoted form of stagedApp & " " & quoted form of targetApp & "; then /bin/mv " & quoted form of backupApp & " " & quoted form of targetApp & "; exit 1; end if"
      do shell script commandText with administrator privileges
    end run
    APPLESCRIPT
    fi
    /usr/bin/open "$target_app"
    /bin/sleep 10
    /bin/rm -rf "$backup_app" "$work_dir"
    """

    func addOfflineAccount(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_]{3,16}$", options: .regularExpression) != nil else {
            lastError = "Имя должно содержать 3–16 латинских букв, цифр или символов подчёркивания."
            return
        }
        if let existing = accounts.first(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            selectedAccountID = existing.id
        } else {
            let account = OfflineAccount(username: name)
            accounts.append(account)
            selectedAccountID = account.id
        }
        saveAccounts()
    }

    func signInWithMicrosoft() async {
        guard !isAuthenticating else { return }
        let clientID = Self.microsoftClientID
        let attemptID = UUID()
        activeAuthenticationID = attemptID
        isAuthenticating = true
        lastError = nil
        defer {
            if activeAuthenticationID == attemptID {
                activeAuthenticationID = nil
                isAuthenticating = false
                microsoftDeviceLogin = nil
            }
        }
        do {
            let device = try await requestDeviceCode(clientID: clientID)
            try ensureAuthenticationIsActive(attemptID)
            microsoftDeviceLogin = MicrosoftDeviceLogin(
                code: device.userCode,
                verificationURL: device.verificationURL,
                message: device.message
            )
            let microsoft = try await pollMicrosoftToken(device: device, clientID: clientID, attemptID: attemptID)
            try ensureAuthenticationIsActive(attemptID)
            let minecraft = try await exchangeForMinecraftToken(microsoft.accessToken)
            try ensureAuthenticationIsActive(attemptID)
            let profile = try await fetchMinecraftProfile(token: minecraft.accessToken)
            try ensureAuthenticationIsActive(attemptID)
            let account = OfflineAccount(username: profile.name, minecraftProfileID: profile.id)
            accounts.removeAll { $0.minecraftProfileID == profile.id }
            accounts.append(account)
            selectedAccountID = account.id
            try saveSecret(minecraft.accessToken, accountID: account.id, suffix: "minecraft")
            if let refreshToken = microsoft.refreshToken {
                try saveSecret(refreshToken, accountID: account.id, suffix: "refresh")
            }
            saveAccounts()
            status = "Вход выполнен: \(profile.name)"
        } catch is CancellationError {
            // Пользователь просто закрыл окно входа.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openMicrosoftSignInPage() {
        guard let login = microsoftDeviceLogin else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login.code, forType: .string)
        NSWorkspace.shared.open(login.verificationURL)
    }

    func cancelMicrosoftSignIn() {
        activeAuthenticationID = nil
        microsoftDeviceLogin = nil
        isAuthenticating = false
        status = "Вход в Microsoft отменён"
    }

    func removeAccount(_ account: OfflineAccount) {
        accounts.removeAll { $0.id == account.id }
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
        }
        saveAccounts()
        deleteSecrets(accountID: account.id)
    }

    func installAndLaunch() async {
        guard let account = selectedAccount else {
            lastError = "Сначала добавьте офлайн-профиль."
            return
        }
        guard let version = versions.first(where: { $0.id == selectedVersionID }) else {
            lastError = LauncherFailure.versionMissing.localizedDescription
            return
        }

        isBusy = true
        progress = 0
        lastError = nil
        defer { isBusy = false }

        do {
            let accessToken = try await minecraftAccessToken(for: account)
            let installation = try await install(version)
            refreshInstalledVersions()
            status = "Запуск Minecraft…"
            progress = 1
            try launch(installation: installation, account: account, accessToken: accessToken)
            status = "Minecraft запущен"
        } catch {
            lastError = error.localizedDescription
            status = "Ошибка запуска"
        }
    }

    private struct Installation {
        let metadata: [String: Any]
        let root: URL
        let javaExecutable: URL
        let versionDirectory: URL
        let clientJar: URL
        let libraries: [URL]
        let nativesDirectory: URL
        let assetsDirectory: URL
        let gameDirectory: URL
    }

    private func install(_ version: MinecraftVersion) async throws -> Installation {
        let root = try launcherRoot()
        let versionDirectory = root.appending(path: "versions/\(version.id)", directoryHint: .isDirectory)
        let clientJar = versionDirectory.appending(path: "\(version.id).jar")
        let metadataFile = versionDirectory.appending(path: "\(version.id).json")
        let librariesRoot = root.appending(path: "libraries", directoryHint: .isDirectory)
        let assetsDirectory = root.appending(path: "assets", directoryHint: .isDirectory)
        let nativesDirectory = versionDirectory.appending(path: "natives", directoryHint: .isDirectory)
        let gameDirectory = root.appending(path: "game/\(safeDirectoryName(version.id))", directoryHint: .isDirectory)

        try makeDirectories([versionDirectory, librariesRoot, assetsDirectory, nativesDirectory, gameDirectory])
        status = "Метаданные \(version.id)…"
        let metadata = try await resolvedMetadata(for: version, savingTo: metadataFile)
        let javaExecutable = try await installMojangRuntime(metadata: metadata, root: root)

        guard let downloads = metadata["downloads"] as? [String: Any],
              let client = downloads["client"] as? [String: Any],
              let clientURLString = client["url"] as? String,
              let clientURL = URL(string: clientURLString) else {
            throw LauncherFailure.invalidMetadata
        }

        status = "Клиент Minecraft…"
        _ = try await download(clientURL, to: clientJar, sha1: client["sha1"] as? String)
        progress = 0.30

        try? fileManager.removeItem(at: nativesDirectory)
        try fileManager.createDirectory(at: nativesDirectory, withIntermediateDirectories: true)

        let libraries = try await installLibraries(
            metadata: metadata,
            root: librariesRoot,
            nativesDirectory: nativesDirectory,
            modified: version.type == "modified"
        )
        progress = 0.60

        try await installAssets(metadata: metadata, assetsDirectory: assetsDirectory)
        progress = 0.98

        return Installation(
            metadata: metadata,
            root: root,
            javaExecutable: javaExecutable,
            versionDirectory: versionDirectory,
            clientJar: clientJar,
            libraries: libraries,
            nativesDirectory: nativesDirectory,
            assetsDirectory: assetsDirectory,
            gameDirectory: gameDirectory
        )
    }

    private func installLibraries(
        metadata: [String: Any],
        root: URL,
        nativesDirectory: URL,
        modified: Bool
    ) async throws -> [URL] {
        guard let definitions = metadata["libraries"] as? [[String: Any]] else { return [] }
        var classpath: [URL] = []
        var nativeArchives: [URL] = []
        var jobs: [([URL], URL, Bool, String?)] = []

        for definition in definitions where ruleAllows(definition["rules"] as? [[String: Any]]) {
            let downloads = definition["downloads"] as? [String: Any] ?? [:]
            if let artifact = downloads["artifact"] as? [String: Any],
               let path = artifact["path"] as? String,
               let urlString = artifact["url"] as? String,
               let url = URL(string: urlString) {
                let destination = root.appending(path: path)
                jobs.append(([url], destination, false, artifact["sha1"] as? String))
                classpath.append(destination)
            } else if let name = definition["name"] as? String,
                      let path = mavenPath(for: name) {
                let destination = root.appending(path: path)
                var sources: [URL] = []
                if let base = definition["url"] as? String {
                    let baseURL = base.hasPrefix("/")
                        ? URL(string: "https://repo.llaun.ch\(base)")
                        : URL(string: base)
                    if let baseURL {
                        sources.append(baseURL.appending(path: path))
                    }
                }
                if modified, let baseURL = URL(string: "https://repo.llaun.ch/libraries/") {
                    sources.append(baseURL.appending(path: path))
                }
                if let baseURL = URL(string: "https://libraries.minecraft.net/") {
                    sources.append(baseURL.appending(path: path))
                }
                jobs.append((sources, destination, false, nil))
                classpath.append(destination)
            }

            if let classifiers = downloads["classifiers"] as? [String: Any],
               let native = nativeArtifact(from: classifiers),
               let path = native["path"] as? String,
               let urlString = native["url"] as? String,
               let url = URL(string: urlString) {
                let destination = root.appending(path: path)
                jobs.append(([url], destination, true, native["sha1"] as? String))
                nativeArchives.append(destination)
            }
        }

        for (index, job) in jobs.enumerated() {
            status = "Библиотеки \(index + 1) из \(jobs.count)…"
            _ = try await downloadFirst(job.0, to: job.1, sha1: job.3)
            progress = 0.30 + (Double(index + 1) / Double(max(jobs.count, 1))) * 0.30
        }

        for archive in nativeArchives {
            try extractNativeArchive(archive, to: nativesDirectory)
        }
        return classpath
    }

    private func resolvedMetadata(for version: MinecraftVersion, savingTo destination: URL) async throws -> [String: Any] {
        let refreshModifiedMetadata = version.type == "modified" || version.sha1 == nil
        let childData = try await download(
            version.url,
            to: destination,
            sha1: version.sha1,
            alwaysRefresh: refreshModifiedMetadata
        )
        guard let child = try JSONSerialization.jsonObject(with: childData) as? [String: Any] else {
            throw LauncherFailure.invalidMetadata
        }
        guard let inheritedID = child["inheritsFrom"] as? String else { return child }
        guard let baseVersion = officialVersions.first(where: { $0.id == inheritedID }) else {
            throw LauncherFailure.versionMissing
        }
        let root = try launcherRoot()
        let baseFile = root.appending(path: "versions/\(inheritedID)/\(inheritedID).json")
        let baseData = try await download(baseVersion.url, to: baseFile, sha1: baseVersion.sha1)
        guard let base = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            throw LauncherFailure.invalidMetadata
        }
        let merged = mergeMetadata(base: base, child: child)
        return merged
    }

    private func mergeMetadata(base: [String: Any], child: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in child { merged[key] = value }
        let baseLibraries = base["libraries"] as? [[String: Any]] ?? []
        let childLibraries = child["libraries"] as? [[String: Any]] ?? []
        merged["libraries"] = deduplicatedLibraries(baseLibraries + childLibraries)

        let baseArguments = base["arguments"] as? [String: Any] ?? [:]
        let childArguments = child["arguments"] as? [String: Any] ?? [:]
        merged["arguments"] = [
            "jvm": mergedArguments(baseArguments["jvm"] as? [Any] ?? [], childArguments["jvm"] as? [Any] ?? []),
            "game": mergedArguments(baseArguments["game"] as? [Any] ?? [], childArguments["game"] as? [Any] ?? [])
        ]
        return merged
    }

    private func mergedArguments(_ parent: [Any], _ child: [Any]) -> [Any] {
        guard child.count >= parent.count else { return parent + child }
        let childPrefix = Array(child.prefix(parent.count))
        let parentSignatures = parent.map(argumentSignature)
        let childSignatures = childPrefix.map(argumentSignature)
        return parentSignatures == childSignatures ? child : parent + child
    }

    private func argumentSignature(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return String(describing: value)
        }
        return data.base64EncodedString()
    }

    private func deduplicatedLibraries(_ libraries: [[String: Any]]) -> [[String: Any]] {
        var order: [String] = []
        var values: [String: [String: Any]] = [:]
        for library in libraries {
            guard let name = library["name"] as? String else { continue }
            let parts = name.split(separator: ":")
            let key = parts.prefix(2).joined(separator: ":") + (parts.count > 3 ? ":\(parts[3])" : "")
            if values[key] == nil { order.append(key) }
            values[key] = library
        }
        return order.compactMap { values[$0] }
    }

    private func mavenPath(for coordinate: String) -> String? {
        let extensionSplit = coordinate.split(separator: "@", maxSplits: 1).map(String.init)
        let fileExtension = extensionSplit.count == 2 ? extensionSplit[1] : "jar"
        let parts = extensionSplit[0].split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let classifier = parts.count >= 4 ? "-\(parts[3])" : ""
        return "\(parts[0].replacingOccurrences(of: ".", with: "/"))/\(parts[1])/\(parts[2])/\(parts[1])-\(parts[2])\(classifier).\(fileExtension)"
    }

    private func installAssets(metadata: [String: Any], assetsDirectory: URL) async throws {
        guard let index = metadata["assetIndex"] as? [String: Any],
              let indexID = index["id"] as? String,
              let urlString = index["url"] as? String,
              let indexURL = URL(string: urlString) else { return }

        let indexFile = assetsDirectory.appending(path: "indexes/\(indexID).json")
        let indexData = try await download(indexURL, to: indexFile, sha1: index["sha1"] as? String)
        guard let json = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let objects = json["objects"] as? [String: [String: Any]] else { return }

        let entries = Array(objects.values)
        for (index, object) in entries.enumerated() {
            guard let hash = object["hash"] as? String, hash.count >= 2 else { continue }
            let prefix = String(hash.prefix(2))
            let url = URL(string: "https://resources.download.minecraft.net/\(prefix)/\(hash)")!
            let destination = assetsDirectory.appending(path: "objects/\(prefix)/\(hash)")
            _ = try await download(url, to: destination, sha1: hash)
            if index.isMultiple(of: 25) {
                status = "Ресурсы \(index + 1) из \(entries.count)…"
                progress = 0.60 + (Double(index + 1) / Double(max(entries.count, 1))) * 0.38
            }
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresIn: Int
        let interval: Int
        let message: String

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURL = "verification_uri"
            case expiresIn = "expires_in"
            case interval
            case message
        }
    }

    private struct MicrosoftTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private struct XboxTokenResponse: Decodable {
        let Token: String
        let DisplayClaims: XboxClaims
    }

    private struct XboxClaims: Decodable {
        let xui: [XboxUser]
    }

    private struct XboxUser: Decodable {
        let uhs: String
    }

    private struct MinecraftTokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct MinecraftProfile: Decodable {
        let id: String
        let name: String
    }

    private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(["client_id": clientID, "scope": "XboxLive.signin offline_access"])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func minecraftAccessToken(for account: OfflineAccount) async throws -> String {
        guard account.accountKind == .microsoft else { return "0" }
        guard let refreshToken = try loadSecret(accountID: account.id, suffix: "refresh"),
              !Self.microsoftClientID.isEmpty else {
            guard let cached = try loadSecret(accountID: account.id, suffix: "minecraft") else {
                throw LauncherFailure.authentication("войдите в Microsoft повторно")
            }
            return cached
        }

        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": Self.microsoftClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "XboxLive.signin offline_access"
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let microsoft = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)
        let minecraft = try await exchangeForMinecraftToken(microsoft.accessToken)
        try saveSecret(minecraft.accessToken, accountID: account.id, suffix: "minecraft")
        if let rotated = microsoft.refreshToken {
            try saveSecret(rotated, accountID: account.id, suffix: "refresh")
        }
        return minecraft.accessToken
    }

    private func pollMicrosoftToken(
        device: DeviceCodeResponse,
        clientID: String,
        attemptID: UUID
    ) async throws -> MicrosoftTokenResponse {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(device.interval, 5)
        while Date() < deadline {
            try ensureAuthenticationIsActive(attemptID)
            try await Task.sleep(for: .seconds(interval))
            try ensureAuthenticationIsActive(attemptID)
            var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formData([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": device.deviceCode
            ])
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)
            }
            let oauth = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            switch oauth?.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "authorization_declined": throw LauncherFailure.authentication("вход отменён пользователем")
            case "expired_token": throw LauncherFailure.authentication("код входа истёк")
            default: throw LauncherFailure.authentication(oauth?.errorDescription ?? oauth?.error ?? "неизвестный ответ OAuth")
            }
        }
        throw LauncherFailure.authentication("код входа истёк")
    }

    private func ensureAuthenticationIsActive(_ attemptID: UUID) throws {
        guard activeAuthenticationID == attemptID else { throw CancellationError() }
    }

    private func exchangeForMinecraftToken(_ microsoftAccessToken: String) async throws -> MinecraftTokenResponse {
        let xbox: XboxTokenResponse = try await postJSON(
            url: "https://user.auth.xboxlive.com/user/authenticate",
            body: [
                "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=\(microsoftAccessToken)"],
                "RelyingParty": "http://auth.xboxlive.com",
                "TokenType": "JWT"
            ],
            headers: ["x-xbl-contract-version": "1"]
        )
        let xsts: XboxTokenResponse = try await postJSON(
            url: "https://xsts.auth.xboxlive.com/xsts/authorize",
            body: [
                "Properties": ["SandboxId": "RETAIL", "UserTokens": [xbox.Token]],
                "RelyingParty": "rp://api.minecraftservices.com/",
                "TokenType": "JWT"
            ],
            headers: ["x-xbl-contract-version": "1"]
        )
        guard let uhs = xsts.DisplayClaims.xui.first?.uhs else {
            throw LauncherFailure.authentication("Xbox не вернул идентификатор пользователя")
        }
        return try await postJSON(
            url: "https://api.minecraftservices.com/authentication/login_with_xbox",
            body: ["identityToken": "XBL3.0 x=\(uhs);\(xsts.Token)"],
            headers: [:]
        )
    }

    private func fetchMinecraftProfile(token: String) async throws -> MinecraftProfile {
        var request = URLRequest(url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LauncherFailure.authentication("на аккаунте не найден приобретённый Minecraft: Java Edition")
        }
        return try JSONDecoder().decode(MinecraftProfile.self, from: data)
    }

    private func postJSON<T: Decodable>(url: String, body: [String: Any], headers: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw LauncherFailure.authentication(details)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private func launch(installation: Installation, account: OfflineAccount, accessToken: String) throws {
        let metadata = installation.metadata
        let java = installation.javaExecutable
        guard let mainClass = metadata["mainClass"] as? String else { throw LauncherFailure.invalidMetadata }
        let versionID = metadata["id"] as? String ?? selectedVersionID
        let assetsIndex = (metadata["assetIndex"] as? [String: Any])?["id"] as? String ?? "legacy"
        let classpath = (installation.libraries + [installation.clientJar])
            .map(\.path)
            .joined(separator: ":")
        let uuid = account.minecraftProfileID.map(formattedUUID) ?? offlineUUID(for: account.username)

        let replacements: [String: String] = [
            "${auth_player_name}": account.username,
            "${version_name}": versionID,
            "${game_directory}": installation.gameDirectory.path,
            "${assets_root}": installation.assetsDirectory.path,
            "${assets_index_name}": assetsIndex,
            "${auth_uuid}": uuid,
            "${auth_xuid}": "0",
            "${clientid}": account.accountKind == .microsoft ? Self.microsoftClientID : "",
            "${auth_access_token}": accessToken,
            "${auth_session}": accessToken,
            "${user_type}": account.accountKind == .microsoft ? "msa" : "legacy",
            "${version_type}": metadata["type"] as? String ?? "release",
            "${natives_directory}": installation.nativesDirectory.path,
            "${launcher_name}": "kapylauncher",
            "${launcher_version}": "1.0",
            "${classpath}": classpath,
            "${classpath_separator}": ":",
            "${library_directory}": installation.root.appending(path: "libraries").path,
            "${user_properties}": "{}",
            "${resolution_width}": "925",
            "${resolution_height}": "530"
        ]

        var arguments = ["-Xmx4G", "-Djava.library.path=\(installation.nativesDirectory.path)"]
        if let argumentGroups = metadata["arguments"] as? [String: Any] {
            arguments += resolvedArguments(argumentGroups["jvm"] as? [Any] ?? [], replacements: replacements)
            arguments.append(mainClass)
            arguments += resolvedArguments(argumentGroups["game"] as? [Any] ?? [], replacements: replacements)
        } else {
            arguments += ["-cp", classpath, mainClass]
            if let legacy = metadata["minecraftArguments"] as? String {
                arguments += splitCommandLine(resolve(legacy, replacements: replacements))
            }
        }

        if !arguments.contains("-cp") && !arguments.contains("-classpath") {
            let classIndex = arguments.firstIndex(of: mainClass) ?? arguments.endIndex
            arguments.insert(contentsOf: ["-cp", classpath], at: classIndex)
        }

        let unsafeMemoryFlag = "--sun-misc-unsafe-memory-access=allow"
        if arguments.contains(unsafeMemoryFlag), !javaAccepts(unsafeMemoryFlag, java: java) {
            arguments.removeAll { $0 == unsafeMemoryFlag }
        }

        try fileManager.createDirectory(at: installation.gameDirectory, withIntermediateDirectories: true)
        let process = Process()
        let standardError = Pipe()
        process.executableURL = java
        process.arguments = arguments
        process.currentDirectoryURL = installation.gameDirectory
        process.standardError = standardError
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            minecraftProcess = process
            process.terminationHandler = { [weak self] exitedProcess in
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                let details = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let exitStatus = exitedProcess.terminationStatus

                guard exitStatus != 0 else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.minecraftProcess = nil
                    self.status = "Ошибка запуска"
                    let conciseDetails = details?.isEmpty == false
                        ? String(details!.prefix(1_500))
                        : "Java завершилась с кодом \(exitStatus)."
                    self.lastError = LauncherFailure.launchFailed(conciseDetails).localizedDescription
                }
            }
        } catch {
            throw LauncherFailure.launchFailed(error.localizedDescription)
        }
    }

    private func resolvedArguments(_ definitions: [Any], replacements: [String: String]) -> [String] {
        var result: [String] = []
        for definition in definitions {
            if let value = definition as? String {
                result.append(resolve(value, replacements: replacements))
            } else if let object = definition as? [String: Any],
                      ruleAllows(object["rules"] as? [[String: Any]]) {
                if let value = object["value"] as? String {
                    result.append(resolve(value, replacements: replacements))
                } else if let values = object["value"] as? [String] {
                    result += values.map { resolve($0, replacements: replacements) }
                }
            }
        }
        return result
    }

    private func javaAccepts(_ option: String, java: URL) -> Bool {
        let probe = Process()
        probe.executableURL = java
        probe.arguments = [option, "-version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func ruleAllows(_ rules: [[String: Any]]?) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules {
            if let os = rule["os"] as? [String: Any] {
                if let name = os["name"] as? String, name != "osx" { continue }
                if let architecture = os["arch"] as? String,
                   architecture.range(of: currentArchitecture, options: .regularExpression) == nil { continue }
                if let version = os["version"] as? String,
                   version.range(of: ProcessInfo.processInfo.operatingSystemVersionString, options: .regularExpression) == nil { continue }
            }
            if let features = rule["features"] as? [String: Bool],
               features.values.contains(true) {
                continue
            }
            allowed = (rule["action"] as? String) == "allow"
        }
        return allowed
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }

    private func nativeArtifact(from classifiers: [String: Any]) -> [String: Any]? {
        #if arch(arm64)
        let preferred = ["natives-macos-arm64", "natives-osx-arm64", "natives-macos", "natives-osx"]
        #else
        let preferred = ["natives-macos", "natives-osx"]
        #endif
        for key in preferred {
            if let artifact = classifiers[key] as? [String: Any] { return artifact }
        }
        return nil
    }

    private func download(
        _ source: URL,
        to destination: URL,
        sha1 expectedSHA1: String? = nil,
        alwaysRefresh: Bool = false
    ) async throws -> Data {
        if !alwaysRefresh, fileManager.fileExists(atPath: destination.path) {
            if let expectedSHA1 {
                if let cachedSHA1 = try? runtimeSHA1(at: destination),
                   cachedSHA1.caseInsensitiveCompare(expectedSHA1) == .orderedSame,
                   let data = try? Data(contentsOf: destination), !data.isEmpty {
                    return data
                }
                try? fileManager.removeItem(at: destination)
            } else if let data = try? Data(contentsOf: destination), !data.isEmpty {
                return data
            }
        }
        let (temporary, response) = try await session.download(from: source)
        try Self.validate(response)
        if let expectedSHA1,
           try runtimeSHA1(at: temporary).caseInsensitiveCompare(expectedSHA1) != .orderedSame {
            throw LauncherFailure.runtime("не совпала контрольная сумма скачанного файла \(destination.lastPathComponent)")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        return try Data(contentsOf: destination)
    }

    private func downloadFirst(_ sources: [URL], to destination: URL, sha1: String? = nil) async throws -> Data {
        var latestError: Error = LauncherFailure.invalidMetadata
        for source in sources {
            do { return try await download(source, to: destination, sha1: sha1) }
            catch { latestError = error }
        }
        throw latestError
    }

    nonisolated private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LauncherFailure.invalidMetadata
        }
    }

    private func extractNativeArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw LauncherFailure.launchFailed("не удалось распаковать native-библиотеки")
        }
        let metaInf = destination.appending(path: "META-INF")
        try? fileManager.removeItem(at: metaInf)
    }

    private func installMojangRuntime(metadata: [String: Any], root: URL) async throws -> URL {
        let javaVersion = metadata["javaVersion"] as? [String: Any]
        let majorVersion = javaVersion?["majorVersion"] as? Int ?? 21
        guard let component = javaVersion?["component"] as? String, !component.isEmpty else {
            throw LauncherFailure.javaMissing(majorVersion)
        }

        #if arch(arm64)
        let platform = "mac-os-arm64"
        #else
        let platform = "mac-os"
        #endif
        let runtimeRoot = root.appending(path: "runtime/\(component)/\(platform)", directoryHint: .isDirectory)
        let java = runtimeRoot.appending(path: "jre.bundle/Contents/Home/bin/java")
        status = "Java \(majorVersion): получаем манифест…"
        let indexURL = URL(string: "https://piston-meta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json")!
        let indexData = try await runtimeData(from: indexURL)
        guard let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let platformRuntimes = index[platform] as? [String: Any],
              let available = platformRuntimes[component] as? [[String: Any]],
              let selected = available.first,
              let manifest = selected["manifest"] as? [String: Any],
              let manifestURLString = manifest["url"] as? String,
              let manifestURL = URL(string: manifestURLString),
              let manifestSHA1 = manifest["sha1"] as? String else {
            throw LauncherFailure.runtime("Mojang не предоставил \(component) для \(platform).")
        }

        let manifestData = try await runtimeData(from: manifestURL, expectedSHA1: manifestSHA1)
        guard let manifestObject = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let definitions = manifestObject["files"] as? [String: [String: Any]] else {
            throw LauncherFailure.runtime("некорректный манифест Java от Mojang")
        }

        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let fileDefinitions = definitions
            .filter { $0.value["type"] as? String == "file" }
            .sorted { $0.key < $1.key }

        for (index, definition) in fileDefinitions.enumerated() {
            let path = definition.key
            let specification = definition.value
            guard let downloads = specification["downloads"] as? [String: Any],
                  let raw = downloads["raw"] as? [String: Any],
                  let urlString = raw["url"] as? String,
                  let url = URL(string: urlString),
                  let checksum = raw["sha1"] as? String else {
                throw LauncherFailure.runtime("в манифесте Java отсутствует файл \(path)")
            }
            let destination = try runtimeDestination(path, root: runtimeRoot)
            status = "Java \(majorVersion): \(index + 1) из \(fileDefinitions.count)…"
            progress = 0.02 + Double(index) / Double(max(fileDefinitions.count, 1)) * 0.20
            try await downloadRuntimeFile(from: url, to: destination, sha1: checksum)
            if specification["executable"] as? Bool == true {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }

        for (path, specification) in definitions where specification["type"] as? String == "link" {
            guard let target = specification["target"] as? String else { continue }
            let destination = try runtimeDestination(path, root: runtimeRoot)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        }

        guard fileManager.isExecutableFile(atPath: java.path) else {
            throw LauncherFailure.runtime("Java была скачана не полностью")
        }
        progress = 0.22
        return java
    }

    private func runtimeDestination(_ relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativePath.hasPrefix("/"), !components.contains("..") else {
            throw LauncherFailure.runtime("небезопасный путь в манифесте Java")
        }
        return root.appending(path: relativePath)
    }

    private func runtimeData(from url: URL, expectedSHA1: String? = nil) async throws -> Data {
        let (temporary, response) = try await session.download(from: url)
        try Self.validate(response)
        if let expectedSHA1,
           try runtimeSHA1(at: temporary).caseInsensitiveCompare(expectedSHA1) != .orderedSame {
            throw LauncherFailure.runtime("не совпала контрольная сумма манифеста Java")
        }
        return try Data(contentsOf: temporary)
    }

    private func downloadRuntimeFile(from url: URL, to destination: URL, sha1: String) async throws {
        if fileManager.fileExists(atPath: destination.path),
           try runtimeSHA1(at: destination).caseInsensitiveCompare(sha1) == .orderedSame {
            return
        }

        let (temporary, response) = try await session.download(from: url)
        try Self.validate(response)
        guard try runtimeSHA1(at: temporary).caseInsensitiveCompare(sha1) == .orderedSame else {
            throw LauncherFailure.runtime("не совпала контрольная сумма файла Java")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func runtimeSHA1(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func launcherRoot() throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "kapylauncher", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func refreshInstalledVersions() {
        guard let root = try? launcherRoot() else { return }
        let versionsRoot = root.appending(path: "versions", directoryHint: .isDirectory)
        let directories = (try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        installedVersionIDs = Set(directories.compactMap { directory in
            let id = directory.lastPathComponent
            let jar = directory.appending(path: "\(id).jar")
            return fileManager.fileExists(atPath: jar.path) ? id : nil
        })
    }

    private func safeDirectoryName(_ versionID: String) -> String {
        versionID.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func makeDirectories(_ urls: [URL]) throws {
        for url in urls { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    private func resolve(_ value: String, replacements: [String: String]) -> String {
        replacements.reduce(value) { result, replacement in
            result.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func splitCommandLine(_ input: String) -> [String] {
        input.split(separator: " ").map(String.init)
    }

    private func offlineUUID(for username: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(username)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    private func formattedUUID(_ raw: String) -> String {
        let hex = raw.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return raw }
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    private func secretAccount(accountID: UUID, suffix: String) -> String {
        "\(accountID.uuidString).\(suffix)"
    }

    private func saveSecret(_ value: String, accountID: UUID, suffix: String) throws {
        let account = secretAccount(accountID: accountID, suffix: suffix)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.kapybarovv.kapylauncher",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LauncherFailure.authentication("Keychain: \(status)") }
    }

    private func loadSecret(accountID: UUID, suffix: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.kapybarovv.kapylauncher",
            kSecAttrAccount as String: secretAccount(accountID: accountID, suffix: suffix),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LauncherFailure.authentication("Keychain: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteSecrets(accountID: UUID) {
        for suffix in ["minecraft", "refresh"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.kapybarovv.kapylauncher",
                kSecAttrAccount as String: secretAccount(accountID: accountID, suffix: suffix)
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private func restoreAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([OfflineAccount].self, from: data) {
            accounts = decoded
        }
        if accounts.isEmpty { accounts = [OfflineAccount(username: NSUserName())] }
        if let rawID = UserDefaults.standard.string(forKey: selectedAccountKey), let id = UUID(uuidString: rawID) {
            selectedAccountID = id
        }
        if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accounts.first?.id
        }
    }

    private func saveAccounts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        UserDefaults.standard.set(selectedAccountID?.uuidString, forKey: selectedAccountKey)
    }
}
