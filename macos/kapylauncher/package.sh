#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
APP="$PROJECT_ROOT/macos/kapylauncher/build/kapylauncher.app"
RELEASE="$PROJECT_ROOT/dist/kapylauncher-macos-universal.zip"
DMG_RELEASE="$PROJECT_ROOT/dist/kapylauncher-macos-universal.dmg"
INSTALLER_BACKGROUND="$PROJECT_ROOT/macos/kapylauncher/installer/InstallBackground@2x.png"

"$PROJECT_ROOT/macos/kapylauncher/build.sh"
mkdir -p "$PROJECT_ROOT/dist"
rm -f "$RELEASE"
rm -f "$DMG_RELEASE"
TEMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
cleanup() {
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
ditto --norsrc "$APP" "$TEMP_DIR/kapylauncher.app"
xattr -cr "$TEMP_DIR/kapylauncher.app"
codesign --verify --deep --strict "$TEMP_DIR/kapylauncher.app"
(
    cd "$TEMP_DIR"
    /usr/bin/zip -qry -X "$RELEASE" "kapylauncher.app"
)
shasum -a 256 "$RELEASE" > "$RELEASE.sha256"

# A Finder-layout DMG: the image itself contains only the application,
# Applications shortcut and a background explaining the drag-to-install action.
DMG_STAGE="$TEMP_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto --norsrc "$APP" "$DMG_STAGE/kapylauncher.app"
xattr -cr "$DMG_STAGE/kapylauncher.app"
ln -s /Applications "$DMG_STAGE/Applications"
mkdir -p "$DMG_STAGE/.background"
cp "$INSTALLER_BACKGROUND" "$DMG_STAGE/.background/InstallBackground@2x.png"

DMG_RW="$TEMP_DIR/kapylauncher-rw.dmg"
hdiutil create -size 18m -fs HFS+ -volname "kapylauncher" -ov "$DMG_RW" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW")"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$NF ~ /^\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Unable to locate the mounted DMG volume" >&2
    exit 1
fi
ditto --norsrc "$DMG_STAGE" "$MOUNT_DIR"
VOLUME_NAME="$(diskutil info "$MOUNT_DIR" | awk -F': *' '/Volume Name/ {print $2; exit}')"
osascript - "$MOUNT_DIR" "$VOLUME_NAME" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set volumeName to item 2 of argv
    set backgroundFile to (POSIX file (mountPath & "/.background/InstallBackground@2x.png") as alias)
    tell application "Finder"
        tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 780, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 13
        set background picture of theViewOptions to backgroundFile
        set position of item "kapylauncher.app" of container window to {165, 205}
        set position of item "Applications" of container window to {495, 205}
        close
        open
        update without registering applications
        delay 4
        close
        delay 2
        end tell
    end tell
end run
APPLESCRIPT
sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_RELEASE" >/dev/null
shasum -a 256 "$DMG_RELEASE" > "$DMG_RELEASE.sha256"

echo "$RELEASE"
echo "$DMG_RELEASE"
