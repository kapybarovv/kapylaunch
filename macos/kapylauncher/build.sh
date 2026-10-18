#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
SOURCE="$PROJECT_ROOT/preview/LiquidGlassNativePreview.swift"
ENGINE="$PROJECT_ROOT/macos/kapylauncher/MinecraftEngine.swift"
BUILD_ROOT="$PROJECT_ROOT/macos/kapylauncher/build"
APP="$BUILD_ROOT/kapylauncher.app"
EXECUTABLE="$APP/Contents/MacOS/kapylauncher"
ARM_EXECUTABLE="$BUILD_ROOT/kapylauncher.arm64"
INTEL_EXECUTABLE="$BUILD_ROOT/kapylauncher.x86_64"
TEMP_SOURCE="/tmp/kapylauncher-App.swift"
TEMP_ENGINE="/tmp/kapylauncher-MinecraftEngine.swift"
BACKGROUND="$PROJECT_ROOT/launcher/src/main/resources/net/legacylauncher/ui/images/dark/plains4K.jpg"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$PROJECT_ROOT/macos/kapylauncher/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_ROOT/macos/kapylauncher/AppIcon-1024.png" "$APP/Contents/Resources/AppIcon.png"
cp "$BACKGROUND" "$APP/Contents/Resources/plains4K.jpg"
cp "$SOURCE" "$TEMP_SOURCE"
cp "$ENGINE" "$TEMP_ENGINE"

build_architecture() {
    local architecture="$1"
    local output="$2"

    CLANG_MODULE_CACHE_PATH="/tmp/kapylauncher-swift-module-cache-$architecture" \
        xcrun swiftc \
        -parse-as-library \
        -target "$architecture-apple-macosx26.0" \
        -framework SwiftUI \
        -framework AppKit \
        "$TEMP_ENGINE" \
        "$TEMP_SOURCE" \
        -o "$output"
}

build_architecture arm64 "$ARM_EXECUTABLE"
build_architecture x86_64 "$INTEL_EXECUTABLE"
lipo -create "$ARM_EXECUTABLE" "$INTEL_EXECUTABLE" -output "$EXECUTABLE"
rm -f "$ARM_EXECUTABLE" "$INTEL_EXECUTABLE"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
xattr -cr "$APP"
file "$EXECUTABLE"
lipo -archs "$EXECUTABLE"
echo "$APP"
