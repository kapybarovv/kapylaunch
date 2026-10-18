import SwiftUI
import AppKit

private enum UtilityPanel: String, Identifiable {
    case info
    case folders
    case refresh
    case settings

    var id: String { rawValue }
}

@main
struct KapyLauncherApp: App {
    var body: some Scene {
        WindowGroup("kapylauncher") {
            LauncherPreview()
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 760)
    }
}

struct LauncherPreview: View {
    @StateObject private var engine = MinecraftEngine()
    @State private var newAccountName = ""
    @State private var delayedLaunch = false
    @State private var updateClient = false
    @State private var message: String?
    @State private var showsAccounts = false
    @State private var showsVersions = false
    @State private var activeUtilityPanel: UtilityPanel?
    @State private var showsSettingsWindow = false
    @State private var showSnapshots = false
    @State private var compactMode = false
    @State private var memory = 4
    @AppStorage("kapylauncher.didAcknowledgeWelcome") private var didAcknowledgeWelcome = false

    private var accountTitle: String {
        engine.selectedAccount?.username ?? "Добавить профиль"
    }

    private var versionTitle: String {
        engine.selectedVersionID.isEmpty ? "Загрузка версий…" : engine.selectedVersionID
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer(minLength: 72)
                launcherForm
                Spacer(minLength: 72)
            }
            .padding(.horizontal, 30)

            if let message {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if engine.isBusy || engine.isRefreshingVersions || engine.isUpdatingLauncher {
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .transition(.opacity)
                loadingOverlay
            }
        }
        .animation(.snappy(duration: 0.32), value: message)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showsSettingsWindow) {
            LauncherSettingsWindow {
                showsSettingsWindow = false
                show("Настройки сохранены")
            }
        }
        .sheet(item: Binding(
            get: { engine.microsoftDeviceLogin },
            set: { login in
                if login == nil { engine.cancelMicrosoftSignIn() }
            }
        )) { login in
            MicrosoftLoginSheet(
                login: login,
                onContinue: engine.openMicrosoftSignInPage,
                onCancel: engine.cancelMicrosoftSignIn
            )
        }
        .sheet(isPresented: Binding(
            get: { !didAcknowledgeWelcome },
            set: { if !$0 { didAcknowledgeWelcome = true } }
        )) {
            WelcomeSheet {
                didAcknowledgeWelcome = true
            }
        }
        .task {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = icon
            }
            Task { await engine.checkForLauncherUpdates() }
            await engine.bootstrap()
        }
        .alert(
            "kapylauncher",
            isPresented: Binding(
                get: { engine.lastError != nil },
                set: { if !$0 { engine.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    private var background: some View {
        Group {
            if let url = Bundle.main.url(forResource: "plains4K", withExtension: "jpg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.12, blue: 0.19), Color(red: 0.02, green: 0.20, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(Color.black.opacity(0.16))
        .ignoresSafeArea()
    }

    private var launcherForm: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Button {
                        showsAccounts.toggle()
                    } label: {
                        menuLabel(
                            accountTitle,
                            symbol: engine.selectedAccount?.accountKind == .microsoft
                                ? "checkmark.seal.fill"
                                : "person.crop.square.fill"
                        )
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.interaction, Capsule())
                    .popover(isPresented: $showsAccounts, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Профили")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 10)

                            ForEach(engine.accounts) { account in
                                HStack(spacing: 4) {
                                    Button {
                                        engine.selectedAccountID = account.id
                                        showsAccounts = false
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: account.accountKind == .microsoft ? "checkmark.seal.fill" : "person.crop.square.fill")
                                                .foregroundStyle(account.accountKind == .microsoft ? .green : .secondary)
                                                .frame(width: 18)
                                            Text(account.username)
                                            Spacer()
                                            Text(account.accountKind == .microsoft ? "Лицензионный" : "Офлайн")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.leading, 10)
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(.interaction, Rectangle())

                                    Button(role: .destructive) {
                                        engine.removeAccount(account)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .semibold))
                                            .frame(width: 32, height: 34)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(.interaction, Rectangle())
                                    .help("Удалить профиль \(account.username)")
                                }
                            }

                            Divider()

                            HStack(spacing: 8) {
                                TextField("Новый ник", text: $newAccountName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { addOfflineAccount() }
                                Button {
                                    addOfflineAccount()
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.glass)
                            }

                            Divider()

                            Button {
                                showsAccounts = false
                                Task { await engine.signInWithMicrosoft() }
                            } label: {
                                Label(engine.isAuthenticating ? "Ожидание входа…" : "Войти через Microsoft", systemImage: "checkmark.seal.fill")
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .contentShape(.capsule)
                                    .glassEffect(
                                        .regular
                                            .tint(.blue)
                                            .interactive(),
                                        in: .capsule
                                    )
                            }
                            .buttonStyle(.plain)
                            .contentShape(.interaction, Capsule())
                            .disabled(engine.isAuthenticating)
                        }
                        .padding(10)
                        .frame(width: 320)
                    }

                    Button {
                        showsVersions.toggle()
                    } label: {
                        menuLabel(versionTitle, symbol: "shippingbox.fill")
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.interaction, Capsule())
                    .popover(isPresented: $showsVersions, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Загрузчик", selection: $engine.loader) {
                                ForEach(VersionLoader.allCases) { loader in
                                    Text(loader.rawValue).tag(loader)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 10)

                            Toggle("Снапшоты", isOn: $engine.showSnapshots)
                                .toggleStyle(.switch)
                                .padding(.horizontal, 10)

                            Toggle("Только установленные", isOn: $engine.installedOnly)
                                .toggleStyle(.switch)
                                .padding(.horizontal, 10)

                            Divider()

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(engine.visibleVersions.prefix(120))) { minecraftVersion in
                                        choiceButton(
                                            minecraftVersion.id,
                                            installed: engine.installedVersionIDs.contains(minecraftVersion.id)
                                        ) {
                                            engine.selectedVersionID = minecraftVersion.id
                                            showsVersions = false
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                        }
                        .padding(8)
                        .frame(width: 320)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Отложенный запуск", isOn: $delayedLaunch)
                    Toggle("Обновить клиент", isOn: $updateClient)
                }
                .font(.system(size: 15, weight: .medium))
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 3)
                .padding(.vertical, 16)

                if let update = engine.availableLauncherUpdate {
                    Button {
                        Task { await engine.installLauncherUpdate() }
                    } label: {
                        Label(
                            update.canInstall ? "Обновить до \(update.id)" : "Открыть релиз \(update.id)",
                            systemImage: update.canInstall ? "arrow.down.app.fill" : "arrow.up.right.square"
                        )
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .glassEffect(.regular.tint(.green).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.interaction, Capsule())
                    .disabled(engine.isBusy || engine.isUpdatingLauncher || engine.isRefreshingVersions)
                    .padding(.bottom, 8)
                }

                Button {
                    Task { await engine.installAndLaunch() }
                } label: {
                    Text(engine.isBusy ? engine.status : "Играть")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .glassEffect(
                            .regular
                                .tint(Color(red: 0.02, green: 0.48, blue: 1.0))
                                .interactive(),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
                .contentShape(.interaction, Capsule())
                .disabled(engine.isBusy || engine.isRefreshingVersions || engine.isUpdatingLauncher || engine.selectedVersionID.isEmpty)

                HStack(spacing: 8) {
                    utilityButton("info.circle.fill", "Информация", panel: .info)
                    utilityButton("folder.fill", "Папки", panel: .folders)
                    utilityButton("arrow.clockwise", "Обновить список", panel: .refresh)
                    utilityButton("line.3.horizontal", "Настройки", panel: .settings)
                }
                .padding(.top, 10)
            }
            .padding(22)
            .frame(width: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Панель запуска Minecraft")
    }

    private var loadingOverlay: some View {
        let isUpdate = engine.isUpdatingLauncher
        let isVersionRefresh = engine.isRefreshingVersions
        let title = isUpdate ? "Обновление kapylauncher" : (isVersionRefresh ? "Проверка версий Minecraft" : "Подготовка Minecraft")
        let detail = isUpdate ? engine.updateStatus : engine.status
        let currentProgress = isUpdate ? engine.updateProgress : engine.progress

        return VStack(spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.blue.opacity(0.22))
                    Image(systemName: isUpdate ? "arrow.down.app.fill" : (isVersionRefresh ? "arrow.clockwise" : "cube.fill"))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            RunningGlassProgressBar(progress: currentProgress)
                .frame(height: 8)

            HStack {
                Text("\(Int(currentProgress * 100)) %")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                Text(isVersionRefresh ? "Получаем актуальные метаданные" : "Не закрывайте лаунчер")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
        .animation(.spring(response: 0.36, dampingFraction: 1), value: engine.isBusy || engine.isRefreshingVersions || engine.isUpdatingLauncher)
    }

    private func menuLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 12)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(width: 396, alignment: .leading)
        .frame(minHeight: 42)
        .contentShape(.rect)
    }

    private func utilityButton(
        _ symbol: String,
        _ title: String,
        panel: UtilityPanel
    ) -> some View {
        Button {
            if panel == .settings {
                activeUtilityPanel = nil
                showsSettingsWindow = true
            } else {
                activeUtilityPanel = activeUtilityPanel == panel ? nil : panel
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.001))

                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(.interaction, Capsule())
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(.interaction, Capsule())
        .help(title)
        .popover(
            isPresented: Binding(
                get: { activeUtilityPanel == panel },
                set: { isPresented in
                    if !isPresented, activeUtilityPanel == panel {
                        activeUtilityPanel = nil
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            utilityPanelContent(panel)
        }
    }

    @ViewBuilder
    private func utilityPanelContent(_ panel: UtilityPanel) -> some View {
        switch panel {
        case .info:
            VStack(alignment: .leading, spacing: 12) {
                Label("kapylauncher", systemImage: "info.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · SwiftUI")
                    .foregroundStyle(.secondary)
                Text("Универсальная сборка для Apple Silicon и Intel")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(18)
            .frame(width: 300, alignment: .leading)

        case .folders:
            panelMenu(title: "Папки", symbol: "folder.fill") {
                panelAction("Папка игры", symbol: "cube.fill")
                panelAction("Сборки", symbol: "shippingbox.fill")
                panelAction("Журналы", symbol: "doc.text.fill")
            }

        case .refresh:
            panelMenu(title: "Обновить список", symbol: "arrow.clockwise") {
                Button {
                    activeUtilityPanel = nil
                    Task { await engine.bootstrap() }
                } label: {
                    Label("Обновить список Minecraft", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contentShape(.interaction, Rectangle())

                Button {
                    Task { await engine.checkForLauncherUpdates() }
                } label: {
                    Label("Проверить обновление лаунчера", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contentShape(.interaction, Rectangle())

                Text(engine.updateStatus.isEmpty ? "Список Minecraft проверяется при каждом запуске." : engine.updateStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                Toggle("Показывать снапшоты", isOn: $showSnapshots)
                    .toggleStyle(.switch)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
            }

        case .settings:
            VStack(alignment: .leading, spacing: 14) {
                Label("Настройки", systemImage: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))

                Toggle("Компактный режим", isOn: $compactMode)
                    .toggleStyle(.switch)

                HStack {
                    Text("Память")
                    Spacer()
                    Picker("Память", selection: $memory) {
                        Text("2 ГБ").tag(2)
                        Text("4 ГБ").tag(4)
                        Text("8 ГБ").tag(8)
                        Text("16 ГБ").tag(16)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private func panelMenu<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 10)
            content()
        }
        .padding(8)
        .frame(width: 280, alignment: .leading)
    }

    private func panelAction(_ title: String, symbol: String) -> some View {
        Button {
            activeUtilityPanel = nil
            show(title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contentShape(.interaction, Rectangle())
    }

    private func choiceButton(
        _ title: String,
        symbol: String? = nil,
        installed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 18)
                }
                Text(title)
                Spacer()
                if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Установлено")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contentShape(.interaction, Rectangle())
    }

    private func show(_ text: String) {
        withAnimation(.snappy(duration: 0.28)) {
            message = text
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    message = nil
                }
            }
        }
    }

    private func addOfflineAccount() {
        engine.addOfflineAccount(newAccountName)
        if engine.lastError == nil {
            newAccountName = ""
            showsAccounts = false
        }
    }
}

private struct RunningGlassProgressBar: View {
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let width = geometry.size.width
                let clampedProgress = min(max(progress, 0), 1)
                let segmentWidth = max(44, width * 0.22)
                let travel = max(0, width - segmentWidth)
                let phase = reduceMotion
                    ? 0.5
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.65) / 1.65

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.14))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.45), Color.blue.opacity(0.82)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * clampedProgress)

                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(0.28), location: 0.48),
                                    .init(color: .cyan.opacity(0.85), location: 0.5),
                                    .init(color: .white.opacity(0.18), location: 0.68),
                                    .init(color: .white.opacity(0), location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: segmentWidth)
                        .offset(x: travel * phase)
                        .blendMode(.screen)
                }
                .clipShape(Capsule())
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Загрузка")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) процентов")
    }
}

private struct MicrosoftLoginSheet: View {
    let login: MicrosoftDeviceLogin
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.blue)

            Text("Вход в Microsoft")
                .font(.system(size: 22, weight: .bold))

            Text("Скопируйте код — затем откроем страницу Microsoft.")
                .foregroundStyle(.secondary)

            Text(login.code)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)

            HStack(spacing: 10) {
                Button("Отменить", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.glass)

                Button {
                    NSApp.keyWindow?.miniaturize(nil)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18)
                }
                .buttonStyle(.glass)
                .help("Свернуть kapylauncher")

                Button("Скопировать и продолжить") {
                    onContinue()
                }
                .buttonStyle(.glassProminent)
            }

            ProgressView("Ожидание подтверждения…")
                .controlSize(.small)
        }
        .padding(28)
        .frame(width: 440)
    }
}

private struct WelcomeSheet: View {
    let continueAction: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.11, blue: 0.16),
                    Color(red: 0.03, green: 0.24, blue: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .frame(width: 52, height: 52)
                        .glassEffect(.regular, in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Добро пожаловать в kapylauncher")
                            .font(.system(size: 22, weight: .bold))
                        Text("Независимый лаунчер для Minecraft на macOS")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("О проекте")
                    .font(.system(size: 16, weight: .semibold))

                Text("kapylauncher создан с уважением к простому и понятному подходу Legacy Launcher. Это независимый неофициальный проект: он не связан с Legacy Launcher, Mojang Studios или Microsoft.")
                    .fixedSize(horizontal: false, vertical: true)

                Text("Используйте только приобретённую копию Minecraft и собственный аккаунт Microsoft. Мы не поддерживаем распространение пиратских копий, обход лицензий или использование чужих учётных данных.")
                    .fixedSize(horizontal: false, vertical: true)

                Label("Версии игры и загрузчики устанавливаются из официальных и открытых репозиториев.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Продолжить") {
                        continueAction()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                }
            }
            .padding(28)
            .frame(width: 560)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case minecraft = "Minecraft"
    case launcher = "Лаунчер"
    case about = "О программе"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .minecraft: "cube.fill"
        case .launcher: "switch.2"
        case .about: "info.circle.fill"
        }
    }
}

private struct LauncherSettingsWindow: View {
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsDestination = .minecraft

    @State private var gameFolder = "~/Library/Application Support/minecraft"
    @State private var separateFolders = "Не использовать отдельные папки"
    @State private var gameWidth = "925"
    @State private var gameHeight = "530"
    @State private var fullscreen = false
    @State private var downloadFromServer = true
    @State private var modifications = true
    @State private var snapshots = true
    @State private var experimental = true
    @State private var oldReleases = false
    @State private var installedOnly = false
    @State private var javaRuntime = "Рекомендуемая"
    @State private var memory = 4.0
    @State private var automaticMemory = true
    @State private var addServers = false

    @State private var launcherWidth = "700"
    @State private var launcherHeight = "600"
    @State private var loginPosition = "По центру"
    @State private var launcherTheme = "Системная"
    @State private var backgroundFile = ""
    @State private var eventLog = "Только ошибки"
    @State private var showFullCommand = false
    @State private var launchBehavior = "Скрывать лаунчер"
    @State private var crashAnalysis = true
    @State private var notifyReleases = true
    @State private var notifySnapshots = false
    @State private var notifyMods = true
    @State private var betaLauncher = false
    @State private var language = "Русский"

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .tag(destination)
                    .padding(.vertical, 4)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                Label("kapylauncher 1.0", systemImage: "cube.transparent.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        } detail: {
            VStack(spacing: 0) {
                settingsContent

                Divider()

                HStack(spacing: 10) {
                    Button("Сбросить") {
                        resetCurrentPage()
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button("Отмена") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)

                    Button("Сохранить") {
                        onSave()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.12, blue: 0.17),
                        Color(red: 0.03, green: 0.20, blue: 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
        }
        .frame(width: 900, height: 660)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.rawValue)
                        .font(.system(size: 28, weight: .bold))
                    Text(pageSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                switch selection {
                case .minecraft:
                    minecraftSettings
                case .launcher:
                    launcherSettings
                case .about:
                    aboutSettings
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var pageSubtitle: String {
        switch selection {
        case .minecraft: "Запуск игры, версии, Java и выделение памяти"
        case .launcher: "Поведение приложения, оформление и уведомления"
        case .about: "Сведения о сборке и лицензии"
        }
    }

    private var minecraftSettings: some View {
        VStack(spacing: 16) {
            settingsCard("Файлы игры", symbol: "folder.fill") {
                settingRow("Папка игры") {
                    HStack(spacing: 8) {
                        TextField("Путь", text: $gameFolder)
                        Button("Выбрать…") { }
                    }
                }

                settingRow("Разделение сборок") {
                    Picker("Разделение сборок", selection: $separateFolders) {
                        Text("Не использовать отдельные папки").tag("Не использовать отдельные папки")
                        Text("Отдельная папка для каждой сборки").tag("Отдельная папка для каждой сборки")
                    }
                    .labelsHidden()
                }
            }

            settingsCard("Окно Minecraft", symbol: "rectangle.inset.filled") {
                settingRow("Размер") {
                    HStack(spacing: 8) {
                        TextField("Ширина", text: $gameWidth)
                            .frame(width: 100)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Высота", text: $gameHeight)
                            .frame(width: 100)
                        Spacer()
                        Toggle("Полный экран", isOn: $fullscreen)
                    }
                }
            }

            settingsCard("Версии", symbol: "square.stack.3d.up.fill") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Toggle("Загружать с сервера", isOn: $downloadFromServer)
                    Toggle("Модификации", isOn: $modifications)
                    Toggle("Снапшоты", isOn: $snapshots)
                    Toggle("Экспериментальные", isOn: $experimental)
                    Toggle("Старые релизы", isOn: $oldReleases)
                    Toggle("Только установленные", isOn: $installedOnly)
                }
                .toggleStyle(.checkbox)
            }

            settingsCard("Java и память", symbol: "memorychip.fill") {
                settingRow("Java / JRE") {
                    HStack(spacing: 8) {
                        Picker("Java / JRE", selection: $javaRuntime) {
                            Text("Рекомендуемая").tag("Рекомендуемая")
                            Text("Системная").tag("Системная")
                            Text("Выбрать вручную…").tag("Выбрать вручную…")
                        }
                        .labelsHidden()
                        Button("Настроить…") { }
                    }
                }

                settingRow("Память") {
                    HStack(spacing: 12) {
                        Slider(value: $memory, in: 1...16, step: 1)
                        Text("\(Int(memory)) ГБ")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        Toggle("Авто", isOn: $automaticMemory)
                    }
                }

                Toggle("Автоматически добавлять серверы из сборок", isOn: $addServers)
            }
        }
    }

    private var launcherSettings: some View {
        VStack(spacing: 16) {
            settingsCard("Окно лаунчера", symbol: "macwindow") {
                settingRow("Размер") {
                    HStack(spacing: 8) {
                        TextField("Ширина", text: $launcherWidth).frame(width: 100)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Высота", text: $launcherHeight).frame(width: 100)
                        Spacer()
                    }
                }
                settingRow("Форма входа") {
                    Picker("Форма входа", selection: $loginPosition) {
                        Text("По центру").tag("По центру")
                        Text("Слева").tag("Слева")
                        Text("Справа").tag("Справа")
                    }.labelsHidden()
                }
            }

            settingsCard("Оформление", symbol: "paintbrush.fill") {
                settingRow("Тема") {
                    Picker("Тема", selection: $launcherTheme) {
                        Text("Системная").tag("Системная")
                        Text("Тёмная").tag("Тёмная")
                        Text("Светлая").tag("Светлая")
                    }.labelsHidden()
                }
                settingRow("Свой фон") {
                    HStack(spacing: 8) {
                        TextField("JPG, PNG или видео", text: $backgroundFile)
                        Button("Выбрать…") { }
                    }
                }
            }

            settingsCard("Запуск и диагностика", symbol: "wrench.and.screwdriver.fill") {
                settingRow("Журнал событий") {
                    Picker("Журнал событий", selection: $eventLog) {
                        Text("Отключён").tag("Отключён")
                        Text("Только ошибки").tag("Только ошибки")
                        Text("Подробный").tag("Подробный")
                    }.labelsHidden()
                }
                settingRow("При запуске игры") {
                    Picker("При запуске игры", selection: $launchBehavior) {
                        Text("Скрывать лаунчер").tag("Скрывать лаунчер")
                        Text("Закрывать лаунчер").tag("Закрывать лаунчер")
                        Text("Оставлять открытым").tag("Оставлять открытым")
                    }.labelsHidden()
                }
                Toggle("Показывать полную команду запуска", isOn: $showFullCommand)
                Toggle("Анализировать ошибки и аварийные завершения", isOn: $crashAnalysis)
            }

            settingsCard("Обновления", symbol: "bell.badge.fill") {
                HStack(spacing: 18) {
                    Toggle("Релизы", isOn: $notifyReleases)
                    Toggle("Снапшоты", isOn: $notifySnapshots)
                    Toggle("Модификации", isOn: $notifyMods)
                }
                .toggleStyle(.checkbox)
                Toggle("Использовать бета-версию лаунчера", isOn: $betaLauncher)
                settingRow("Язык") {
                    Picker("Язык", selection: $language) {
                        Text("Русский").tag("Русский")
                        Text("English").tag("English")
                        Text("Deutsch").tag("Deutsch")
                    }.labelsHidden()
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 16) {
            settingsCard("kapylauncher", symbol: "cube.transparent.fill") {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(.cyan)
                        .frame(width: 72, height: 72)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("kapylauncher 1.0")
                            .font(.system(size: 20, weight: .bold))
                        Text("SwiftUI · Apple Silicon")
                            .foregroundStyle(.secondary)
                        Text("Минималистичный лаунчер Minecraft без рекламных блоков и удалённых промо-лент.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            settingsCard("Сборка", symbol: "hammer.fill") {
                aboutRow("Архитектура", value: "arm64")
                aboutRow("Платформа", value: "macOS 26+")
                aboutRow("Интерфейс", value: "SwiftUI · Liquid Glass")
                aboutRow("Канал", value: "Локальная разработка")
            }

            settingsCard("Примечание", symbol: "shield.lefthalf.filled") {
                Text("Нативный macOS-клиент на SwiftUI. Параметры запуска и игровые данные хранятся локально на этом Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func aboutRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func resetCurrentPage() {
        switch selection {
        case .minecraft:
            gameWidth = "925"
            gameHeight = "530"
            fullscreen = false
            memory = 4
            automaticMemory = true
        case .launcher:
            launcherWidth = "700"
            launcherHeight = "600"
            launcherTheme = "Системная"
            crashAnalysis = true
            betaLauncher = false
        case .about:
            break
        }
    }
}
