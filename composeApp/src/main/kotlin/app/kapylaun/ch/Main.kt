package app.kapylaun.ch

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.window.WindowDraggableArea
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowScope
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

private val TextPrimary = Color(0xFFF3F7F9)
private val TextSecondary = Color(0xFFC0D0D7)
private val GlassBlue = Color(0xFF58D8EB)
private val PlayBlue = Color(0xFF087FF5)
private val DeepNavy = Color(0xFF071D28)

fun main() = application {
    val windowState = rememberWindowState(width = 1000.dp, height = 720.dp)
    Window(
        onCloseRequest = ::exitApplication,
        title = "kapylauncher",
        state = windowState,
        undecorated = true,
        transparent = true,
        resizable = true,
    ) {
        MaterialTheme(
            colorScheme = darkColorScheme(
                primary = GlassBlue,
                onPrimary = Color.White,
                surface = DeepNavy,
                onSurface = TextPrimary,
                background = DeepNavy,
                onBackground = TextPrimary,
            ),
        ) {
            LauncherWindow(windowState, onClose = ::exitApplication)
        }
    }
}

private data class LauncherNotice(val title: String, val body: String)

@Composable
private fun WindowScope.LauncherWindow(windowState: WindowState, onClose: () -> Unit) {
    val backend = remember { LauncherBackend() }
    DisposableEffect(backend) { onDispose { backend.close() } }
    LaunchedEffect(backend) { backend.initialize() }

    var accountMenu by remember { mutableStateOf(false) }
    var versionMenu by remember { mutableStateOf(false) }
    var actionMenu by remember { mutableStateOf(false) }
    var showOfflineDialog by remember { mutableStateOf(false) }
    var offlineName by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<LauncherNotice?>(null) }

    LaunchedEffect(backend.lastError) {
        backend.lastError?.let { notice = LauncherNotice("kapylauncher", it) }
    }

    val currentAccount = backend.selectedAccount
    val currentProfile = backend.profiles.firstOrNull { it.id == backend.selectedProfileId }

    Box(Modifier.fillMaxSize().clip(RoundedCornerShape(28.dp))) {
        LiquidBackdrop(Modifier.fillMaxSize())

        Column(Modifier.fillMaxSize()) {
            WindowChrome(windowState = windowState, onClose = onClose)
            BoxWithConstraints(
                Modifier.weight(1f).fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                val horizontalInset = if (maxWidth < 440.dp) 18.dp else 0.dp
                GlassPanel(
                    Modifier.widthIn(max = 430.dp)
                        .fillMaxWidth()
                        .padding(horizontal = horizontalInset),
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 17.dp),
                        verticalArrangement = Arrangement.spacedBy(9.dp),
                    ) {
                        Box(Modifier.fillMaxWidth()) {
                            SelectorPill(
                                value = currentAccount?.label ?: "Добавить аккаунт",
                                icon = if (currentAccount?.kind == AccountKind.MICROSOFT) {
                                    SelectorIcon.LicensedAccount
                                } else {
                                    SelectorIcon.OfflineAccount
                                },
                                expanded = accountMenu,
                                onClick = { accountMenu = true },
                            )
                            DropdownMenu(expanded = accountMenu, onDismissRequest = { accountMenu = false }) {
                                backend.accounts.forEach { item ->
                                    DropdownMenuItem(
                                        text = { Text("${if (item.kind == AccountKind.MICROSOFT) "✓  " else "　"}${item.label}") },
                                        onClick = { backend.selectAccount(item); accountMenu = false },
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text("Добавить офлайн-профиль…") },
                                    onClick = { accountMenu = false; offlineName = ""; showOfflineDialog = true },
                                )
                                DropdownMenuItem(
                                    text = { Text("Войти через Microsoft…") },
                                    onClick = { accountMenu = false; backend.signInWithMicrosoft() },
                                )
                                if (currentAccount != null) DropdownMenuItem(
                                    text = { Text("Удалить выбранный аккаунт") },
                                    onClick = { backend.removeAccount(currentAccount); accountMenu = false },
                                )
                            }
                        }

                        Box(Modifier.fillMaxWidth()) {
                            SelectorPill(
                                value = currentProfile?.label ?: if (backend.busy) backend.status else "Загружаю версии…",
                                icon = SelectorIcon.Version,
                                expanded = versionMenu,
                                onClick = { versionMenu = true },
                            )
                            DropdownMenu(expanded = versionMenu, onDismissRequest = { versionMenu = false }) {
                                backend.visibleProfiles.take(160).forEach { item ->
                                    val isInstalled = backend.isInstalled(item)
                                    DropdownMenuItem(
                                        text = { Text("${if (isInstalled) "✓  " else "　"}${item.label}") },
                                        onClick = { backend.selectProfile(item); versionMenu = false },
                                    )
                                }
                                DropdownMenuItem(text = { Text("Обновить список версий") }, onClick = { versionMenu = false; backend.refreshProfiles() })
                            }
                        }

                        Spacer(Modifier.height(1.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            CheckRow("Отложенный запуск", backend.delayedLaunch) { backend.delayedLaunch = it }
                            CheckRow("Проверять файлы перед запуском", backend.verifyFiles) { backend.verifyFiles = it }
                            CheckRow("Только установленные версии", backend.installedOnly) { backend.installedOnly = it }
                        }

                        Spacer(Modifier.height(1.dp))
                        PlayButton(
                            label = if (backend.busy) "Подготовка…" else if (currentProfile?.let(backend::isInstalled) == true) "Играть" else "Установить и играть",
                            onClick = { backend.launch() },
                        )

                        if (backend.busy) {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(backend.status, color = TextSecondary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                LinearProgressIndicator(
                                    progress = { backend.progress },
                                    modifier = Modifier.fillMaxWidth().height(3.dp).clip(CircleShape),
                                    color = GlassBlue,
                                    trackColor = Color.White.copy(alpha = 0.10f),
                                )
                            }
                        }

                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(7.dp),
                        ) {
                            ActionButton(ActionIcon.Info, "О программе", Modifier.weight(1f)) {
                                notice = LauncherNotice("kapylauncher", "Kotlin desktop launcher. Версии Mojang, Fabric и Forge загружаются из их официальных источников.")
                            }
                            ActionButton(ActionIcon.Folder, "Папка игры", Modifier.weight(1f)) {
                                backend.openGameFolder()
                            }
                            ActionButton(ActionIcon.Refresh, "Проверить версии", Modifier.weight(1f)) {
                                backend.refreshProfiles()
                            }
                            Box(Modifier.weight(1f)) {
                                ActionButton(ActionIcon.Menu, "Меню", Modifier.fillMaxWidth()) { actionMenu = true }
                                DropdownMenu(expanded = actionMenu, onDismissRequest = { actionMenu = false }) {
                                    DropdownMenuItem(
                                        text = { Text("Настройки") },
                                        onClick = {
                                            actionMenu = false
                                            notice = LauncherNotice("Настройки", "Minecraft хранится в ~/.kapylauncher; для каждой версии и загрузчика создаётся отдельная папка. Java подходящей версии загружается автоматически.")
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("О программе") },
                                        onClick = {
                                            actionMenu = false
                                            notice = LauncherNotice("kapylauncher", "Kotlin desktop launcher. Версии Mojang, Fabric и Forge загружаются из их официальных источников.")
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Добавить офлайн-профиль…") },
                                        onClick = { actionMenu = false; offlineName = ""; showOfflineDialog = true },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Войти через Microsoft…") },
                                        onClick = { actionMenu = false; backend.signInWithMicrosoft() },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        notice?.let { current -> GlassNotice(current) { notice = null } }
        if (showOfflineDialog) {
            OfflineAccountDialog(
                name = offlineName,
                onNameChange = { offlineName = it },
                onCancel = { showOfflineDialog = false },
                onAdd = {
                    backend.addOfflineAccount(offlineName)
                    showOfflineDialog = false
                },
            )
        }
        backend.deviceCode?.let { code ->
            MicrosoftDeviceDialog(
                code = code,
                message = backend.deviceMessage.orEmpty(),
                busy = backend.busy || backend.awaitingMicrosoft,
                onCopyAndOpen = backend::openMicrosoftPageAfterCopy,
                onCancel = backend::cancelMicrosoftLogin,
            )
        }
    }
}

@Composable
private fun WindowScope.WindowChrome(windowState: WindowState, onClose: () -> Unit) {
    WindowDraggableArea(
        Modifier.fillMaxWidth().height(38.dp).background(Color(0xA9071922)),
    ) {
        Row(
            Modifier.fillMaxSize().padding(start = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            WindowDot(Color(0xFFFF625C), onClick = onClose)
            Spacer(Modifier.width(7.dp))
            WindowDot(Color(0xFFFFC247), onClick = { windowState.isMinimized = true })
            Spacer(Modifier.width(7.dp))
            WindowDot(Color(0xFF32C85A), onClick = {
                windowState.placement = if (windowState.placement == WindowPlacement.Maximized) {
                    WindowPlacement.Floating
                } else {
                    WindowPlacement.Maximized
                }
            })
        }
    }
}

@Composable
private fun WindowDot(color: Color, onClick: () -> Unit) {
    Box(
        Modifier.size(12.dp).clip(CircleShape).background(color).clickable(onClick = onClick),
    )
}

@Composable
private fun LiquidBackdrop(modifier: Modifier = Modifier) {
    Box(modifier) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(
                Brush.verticalGradient(
                    0f to Color(0xFF296484),
                    0.46f to Color(0xFF40808F),
                    0.70f to Color(0xFF1A5247),
                    1f to Color(0xFF0B3124),
                ),
            )

            for ((xRatio, yRatio, scale) in listOf(Triple(0.16f, 0.20f, 1f), Triple(0.78f, 0.29f, 0.72f))) {
                val cloudX = size.width * xRatio
                val cloudY = size.height * yRatio
                val unit = size.width * 0.018f * scale
                val cloud = Path().apply {
                    moveTo(cloudX, cloudY + unit)
                    lineTo(cloudX + unit, cloudY + unit)
                    lineTo(cloudX + unit, cloudY)
                    lineTo(cloudX + unit * 2, cloudY)
                    lineTo(cloudX + unit * 2, cloudY + unit * 0.5f)
                    lineTo(cloudX + unit * 3, cloudY + unit * 0.5f)
                    lineTo(cloudX + unit * 3, cloudY + unit * 1.5f)
                    lineTo(cloudX, cloudY + unit * 1.5f)
                    close()
                }
                drawPath(cloud, Color.White.copy(alpha = 0.13f))
            }

            val farHill = Path().apply {
                moveTo(0f, size.height * 0.66f)
                cubicTo(size.width * 0.15f, size.height * 0.54f, size.width * 0.29f, size.height * 0.67f, size.width * 0.42f, size.height * 0.61f)
                cubicTo(size.width * 0.63f, size.height * 0.52f, size.width * 0.79f, size.height * 0.70f, size.width, size.height * 0.57f)
                lineTo(size.width, size.height)
                lineTo(0f, size.height)
                close()
            }
            drawPath(farHill, Brush.verticalGradient(listOf(Color(0xFF1C6154), Color(0xFF0D3D33)), startY = size.height * 0.57f, endY = size.height))

            // Crisp, restrained tree silhouettes define the horizon. No blur
            // filter is applied to the landscape.
            for (i in 0 until 38) {
                val x = size.width * i / 37f
                val baseY = size.height * (0.71f + (i % 3) * 0.009f)
                val treeHeight = size.height * (0.035f + (i % 5) * 0.006f)
                val treeWidth = treeHeight * 0.62f
                val tone = if (i % 3 == 0) Color(0xFF123B35) else Color(0xFF175044)
                val pine = Path().apply {
                    moveTo(x, baseY - treeHeight)
                    lineTo(x - treeWidth * 0.30f, baseY - treeHeight * 0.50f)
                    lineTo(x - treeWidth * 0.12f, baseY - treeHeight * 0.50f)
                    lineTo(x - treeWidth * 0.48f, baseY - treeHeight * 0.13f)
                    lineTo(x - treeWidth * 0.10f, baseY - treeHeight * 0.13f)
                    lineTo(x - treeWidth * 0.10f, baseY)
                    lineTo(x + treeWidth * 0.10f, baseY)
                    lineTo(x + treeWidth * 0.10f, baseY - treeHeight * 0.13f)
                    lineTo(x + treeWidth * 0.48f, baseY - treeHeight * 0.13f)
                    lineTo(x + treeWidth * 0.12f, baseY - treeHeight * 0.50f)
                    lineTo(x + treeWidth * 0.30f, baseY - treeHeight * 0.50f)
                    close()
                }
                drawPath(pine, tone.copy(alpha = 0.74f))
            }

            val nearHill = Path().apply {
                moveTo(0f, size.height * 0.80f)
                cubicTo(size.width * 0.18f, size.height * 0.68f, size.width * 0.34f, size.height * 0.87f, size.width * 0.52f, size.height * 0.76f)
                cubicTo(size.width * 0.73f, size.height * 0.66f, size.width * 0.87f, size.height * 0.82f, size.width, size.height * 0.73f)
                lineTo(size.width, size.height)
                lineTo(0f, size.height)
                close()
            }
            drawPath(nearHill, Brush.verticalGradient(listOf(Color(0xDD14563F), Color(0xFF082F22)), startY = size.height * 0.72f, endY = size.height))

            // Small, sharp grass patches keep the scene readable at every
            // scale without adding a blur, glow, or photographic bokeh layer.
            for (i in 0 until 34) {
                val x = (i * 83f + 21f) % size.width
                val y = size.height * (0.81f + ((i * 7) % 17) / 100f)
                val patchWidth = (4 + (i % 4) * 2).dp.toPx()
                val patchHeight = (1.5f + (i % 3) * 0.6f).dp.toPx()
                val patchColor = if (i % 2 == 0) Color(0xFF347A56) else Color(0xFF28654E)
                drawRect(patchColor.copy(alpha = 0.48f), Offset(x, y), Size(patchWidth, patchHeight))
            }
            drawRect(Brush.verticalGradient(listOf(Color.Transparent, Color(0x3000141B))), size = size)
        }
    }
}

@Composable
private fun GlassPanel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(31.dp)
    Box(
        modifier
            .shadow(24.dp, shape, ambientColor = Color(0xAA001018), spotColor = Color(0xAA001018))
            .clip(shape)
            .background(
                Brush.linearGradient(
                    listOf(Color(0xEF062631), Color(0xE90A2935), Color(0xEA06242D)),
                ),
            )
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    listOf(Color(0x885BDDEF), Color(0x6672CEDB), Color(0x443CD8E5)),
                ),
                shape = shape,
            ),
    ) {
        Canvas(Modifier.fillMaxWidth().height(32.dp)) {
            drawLine(
                Color.White.copy(alpha = 0.12f),
                Offset(size.width * 0.12f, 1.dp.toPx()),
                Offset(size.width * 0.76f, 1.dp.toPx()),
                strokeWidth = 1.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
        content()
    }
}

private enum class SelectorIcon { OfflineAccount, LicensedAccount, Version }

@Composable
private fun SelectorPill(value: String, icon: SelectorIcon, expanded: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier.fillMaxWidth()
            .height(38.dp)
            .clip(shape)
            .background(
                Brush.linearGradient(
                    listOf(Color(0x3AFFFFFF), Color(0x28D9F5FF), Color(0x1EFFFFFF)),
                ),
            )
            .border(1.dp, Color.White.copy(alpha = 0.095f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SelectorGlyph(icon)
        Spacer(Modifier.width(9.dp))
        Text(
            value,
            Modifier.weight(1f),
            color = TextPrimary,
            fontWeight = FontWeight.Medium,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        ChevronGlyph(expanded)
    }
}

@Composable
private fun SelectorGlyph(icon: SelectorIcon) {
    Canvas(Modifier.size(16.dp)) {
        val cx = size.width / 2
        val cy = size.height / 2
        when (icon) {
            SelectorIcon.Version -> {
                val top = Path().apply {
                    moveTo(cx, size.height * 0.08f)
                    lineTo(size.width * 0.92f, size.height * 0.30f)
                    lineTo(cx, size.height * 0.52f)
                    lineTo(size.width * 0.08f, size.height * 0.30f)
                    close()
                }
                val left = Path().apply {
                    moveTo(size.width * 0.08f, size.height * 0.30f)
                    lineTo(cx, size.height * 0.52f)
                    lineTo(cx, size.height * 0.94f)
                    lineTo(size.width * 0.08f, size.height * 0.72f)
                    close()
                }
                val right = Path().apply {
                    moveTo(size.width * 0.92f, size.height * 0.30f)
                    lineTo(cx, size.height * 0.52f)
                    lineTo(cx, size.height * 0.94f)
                    lineTo(size.width * 0.92f, size.height * 0.72f)
                    close()
                }
                drawPath(top, Color.White)
                drawPath(left, Color.White.copy(alpha = 0.85f))
                drawPath(right, Color.White.copy(alpha = 0.68f))
                drawLine(Color(0xFF254454), Offset(cx, size.height * 0.52f), Offset(cx, size.height * 0.94f), 0.8.dp.toPx())
                drawLine(Color(0xFF254454), Offset(size.width * 0.08f, size.height * 0.30f), Offset(cx, size.height * 0.52f), 0.8.dp.toPx())
                drawLine(Color(0xFF254454), Offset(size.width * 0.92f, size.height * 0.30f), Offset(cx, size.height * 0.52f), 0.8.dp.toPx())
            }
            SelectorIcon.OfflineAccount, SelectorIcon.LicensedAccount -> {
                drawCircle(Color.White, radius = size.minDimension * 0.47f, center = Offset(cx, cy))
                if (icon == SelectorIcon.OfflineAccount) {
                    drawCircle(DeepNavy, radius = size.minDimension * 0.13f, center = Offset(cx, size.height * 0.36f))
                    val shoulders = Path().apply {
                        moveTo(size.width * 0.22f, size.height * 0.76f)
                        quadraticTo(size.width * 0.25f, size.height * 0.53f, cx, size.height * 0.53f)
                        quadraticTo(size.width * 0.75f, size.height * 0.53f, size.width * 0.78f, size.height * 0.76f)
                        close()
                    }
                    drawPath(shoulders, DeepNavy)
                } else {
                    val badge = Path().apply {
                        moveTo(cx, size.height * 0.23f)
                        lineTo(size.width * 0.74f, size.height * 0.35f)
                        lineTo(size.width * 0.71f, size.height * 0.59f)
                        lineTo(cx, size.height * 0.77f)
                        lineTo(size.width * 0.29f, size.height * 0.59f)
                        lineTo(size.width * 0.26f, size.height * 0.35f)
                        close()
                    }
                    drawPath(badge, DeepNavy)
                    val tick = Path().apply {
                        moveTo(size.width * 0.38f, size.height * 0.48f)
                        lineTo(size.width * 0.47f, size.height * 0.57f)
                        lineTo(size.width * 0.64f, size.height * 0.38f)
                    }
                    drawPath(tick, Color.White, style = Stroke(1.15.dp.toPx(), cap = StrokeCap.Round))
                }
            }
        }
    }
}

@Composable
private fun ChevronGlyph(expanded: Boolean) {
    Canvas(Modifier.size(width = 14.dp, height = 16.dp)) {
        val x = size.width * 0.5f
        val halfWidth = 2.4.dp.toPx()
        val halfHeight = 1.8.dp.toPx()
        val stroke = 1.55.dp.toPx()
        if (expanded) {
            drawLine(TextSecondary, Offset(x - halfWidth, size.height * 0.59f), Offset(x, size.height * 0.41f), stroke, StrokeCap.Round)
            drawLine(TextSecondary, Offset(x, size.height * 0.41f), Offset(x + halfWidth, size.height * 0.59f), stroke, StrokeCap.Round)
        } else {
            drawLine(TextSecondary, Offset(x - halfWidth, size.height * 0.34f), Offset(x, size.height * 0.34f + halfHeight), stroke, StrokeCap.Round)
            drawLine(TextSecondary, Offset(x, size.height * 0.34f + halfHeight), Offset(x + halfWidth, size.height * 0.34f), stroke, StrokeCap.Round)
            drawLine(TextSecondary, Offset(x - halfWidth, size.height * 0.66f), Offset(x, size.height * 0.66f - halfHeight), stroke, StrokeCap.Round)
            drawLine(TextSecondary, Offset(x, size.height * 0.66f - halfHeight), Offset(x + halfWidth, size.height * 0.66f), stroke, StrokeCap.Round)
        }
    }
}

@Composable
private fun CheckRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .height(23.dp)
            .clip(RoundedCornerShape(6.dp))
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CheckGlyph(checked)
        Spacer(Modifier.width(7.dp))
        Text(label, color = TextPrimary, fontWeight = FontWeight.Medium, fontSize = 13.sp)
    }
}

@Composable
private fun CheckGlyph(checked: Boolean) {
    val shape = RoundedCornerShape(4.dp)
    Box(
        Modifier.size(14.dp)
            .clip(shape)
            .background(if (checked) GlassBlue else Color(0xFF173846))
            .border(1.dp, Color.White.copy(alpha = if (checked) 0.55f else 0.15f), shape),
        contentAlignment = Alignment.Center,
    ) {
        if (checked) Canvas(Modifier.fillMaxSize().padding(3.dp)) {
            drawLine(Color(0xFF06303A), Offset(0f, size.height * 0.48f), Offset(size.width * 0.38f, size.height * 0.82f), 1.5.dp.toPx(), StrokeCap.Round)
            drawLine(Color(0xFF06303A), Offset(size.width * 0.35f, size.height * 0.8f), Offset(size.width, size.height * 0.12f), 1.5.dp.toPx(), StrokeCap.Round)
        }
    }
}

@Composable
private fun PlayButton(label: String, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        Modifier.fillMaxWidth()
            .height(44.dp)
            .scale(if (pressed) 0.985f else 1f)
            .shadow(10.dp, CircleShape, ambientColor = PlayBlue.copy(alpha = 0.42f), spotColor = PlayBlue.copy(alpha = 0.26f))
            .clip(CircleShape)
            .background(PlayBlue)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    }
}

private enum class ActionIcon { Info, Folder, Refresh, Menu }

@Composable
private fun ActionButton(icon: ActionIcon, description: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        modifier.height(38.dp)
            .scale(if (pressed) 0.97f else 1f)
            .clip(shape)
            .background(Color(0xB6112931))
            .border(1.dp, Color.White.copy(alpha = 0.045f), shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(20.dp)) {
            val w = size.width
            val h = size.height
            val stroke = 2.dp.toPx()
            when (icon) {
                ActionIcon.Info -> {
                    drawCircle(TextPrimary, radius = w * 0.45f)
                    drawCircle(DeepNavy, radius = stroke * 0.52f, center = Offset(w * 0.5f, h * 0.31f))
                    drawRoundRect(DeepNavy, Offset(w * 0.5f - stroke * 0.48f, h * 0.45f), Size(stroke * 0.96f, h * 0.30f), CornerRadius(stroke * 0.45f))
                }
                ActionIcon.Folder -> {
                    val path = Path().apply {
                        moveTo(w * 0.10f, h * 0.30f)
                        lineTo(w * 0.43f, h * 0.30f)
                        lineTo(w * 0.54f, h * 0.42f)
                        lineTo(w * 0.90f, h * 0.42f)
                        lineTo(w * 0.90f, h * 0.79f)
                        quadraticTo(w * 0.90f, h * 0.88f, w * 0.80f, h * 0.88f)
                        lineTo(w * 0.16f, h * 0.88f)
                        quadraticTo(w * 0.08f, h * 0.88f, w * 0.08f, h * 0.79f)
                        lineTo(w * 0.08f, h * 0.34f)
                        quadraticTo(w * 0.08f, h * 0.30f, w * 0.10f, h * 0.30f)
                        close()
                    }
                    drawPath(path, TextPrimary)
                    drawLine(Color(0xFF29434B), Offset(w * 0.14f, h * 0.60f), Offset(w * 0.86f, h * 0.60f), 0.8.dp.toPx(), StrokeCap.Round)
                }
                ActionIcon.Refresh -> {
                    drawArc(TextPrimary, 45f, 285f, false, Offset(w * 0.16f, h * 0.16f), Size(w * 0.68f, h * 0.68f), style = Stroke(stroke, cap = StrokeCap.Round))
                    val arrow = Path().apply {
                        moveTo(w * 0.72f, h * 0.08f)
                        lineTo(w * 0.91f, h * 0.13f)
                        lineTo(w * 0.82f, h * 0.31f)
                    }
                    drawPath(arrow, TextPrimary, style = Stroke(stroke, cap = StrokeCap.Round))
                }
                ActionIcon.Menu -> {
                    for (line in 0..2) {
                        val y = h * (0.28f + line * 0.22f)
                        drawLine(TextPrimary, Offset(w * 0.18f, y), Offset(w * 0.82f, y), stroke, StrokeCap.Round)
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassNotice(notice: LauncherNotice, onDismiss: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color(0x77020C12)).clickable(onClick = onDismiss),
        contentAlignment = Alignment.Center,
    ) {
        GlassPanel(Modifier.widthIn(max = 390.dp).fillMaxWidth().padding(horizontal = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(22.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(notice.title, color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(notice.body, color = TextSecondary, fontSize = 13.sp, lineHeight = 18.sp)
                Box(
                    Modifier.fillMaxWidth().height(38.dp).clip(CircleShape).background(PlayBlue).clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("ОК", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
private fun OfflineAccountDialog(
    name: String,
    onNameChange: (String) -> Unit,
    onCancel: () -> Unit,
    onAdd: () -> Unit,
) {
    Box(
        Modifier.fillMaxSize().background(Color(0x99020C12)).clickable(onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        GlassPanel(
            Modifier.widthIn(max = 380.dp).fillMaxWidth().padding(horizontal = 22.dp).clickable {},
        ) {
            Column(
                Modifier.fillMaxWidth().padding(22.dp),
                verticalArrangement = Arrangement.spacedBy(13.dp),
            ) {
                Text("Офлайн-профиль", color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text("Имя игрока: латинские буквы, цифры и _.", color = TextSecondary, fontSize = 12.sp)
                BasicTextField(
                    value = name,
                    onValueChange = onNameChange,
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 14.sp),
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                        .background(Color.White.copy(alpha = 0.08f)).padding(horizontal = 14.dp, vertical = 12.dp),
                    decorationBox = { inner ->
                        Box {
                            if (name.isBlank()) Text("Например, kapybarovv", color = TextSecondary.copy(alpha = 0.7f), fontSize = 14.sp)
                            inner()
                        }
                    },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillAction("Отмена", Modifier.weight(1f), false, onCancel)
                    PillAction("Добавить", Modifier.weight(1f), true, onAdd)
                }
            }
        }
    }
}

@Composable
private fun MicrosoftDeviceDialog(
    code: String,
    message: String,
    busy: Boolean,
    onCopyAndOpen: () -> Unit,
    onCancel: () -> Unit,
) {
    Box(
        Modifier.fillMaxSize().background(Color(0x99020C12)).clickable(onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        GlassPanel(
            Modifier.widthIn(max = 400.dp).fillMaxWidth().padding(horizontal = 22.dp).clickable {},
        ) {
            Column(
                Modifier.fillMaxWidth().padding(22.dp),
                verticalArrangement = Arrangement.spacedBy(13.dp),
            ) {
                Text("Вход через Microsoft", color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text("Сначала скопируйте код, затем откройте страницу Microsoft.", color = TextSecondary, fontSize = 13.sp, lineHeight = 18.sp)
                Box(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp))
                        .background(Color.White.copy(alpha = 0.08f)).padding(vertical = 15.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(code, color = TextPrimary, fontWeight = FontWeight.Bold, fontSize = 25.sp, letterSpacing = 2.sp)
                }
                Text(message, color = TextSecondary, fontSize = 12.sp)
                if (busy) {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().height(3.dp).clip(CircleShape),
                        color = GlassBlue,
                        trackColor = Color.White.copy(alpha = 0.10f),
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillAction("Закрыть", Modifier.weight(1f), false, onCancel)
                    PillAction("Скопировать и открыть", Modifier.weight(1.5f), true, onCopyAndOpen)
                }
            }
        }
    }
}

@Composable
private fun PillAction(label: String, modifier: Modifier, primary: Boolean, onClick: () -> Unit) {
    Box(
        modifier.height(38.dp).clip(CircleShape)
            .background(if (primary) PlayBlue else Color.White.copy(alpha = 0.10f))
            .border(1.dp, Color.White.copy(alpha = if (primary) 0.18f else 0.08f), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, maxLines = 1)
    }
}
