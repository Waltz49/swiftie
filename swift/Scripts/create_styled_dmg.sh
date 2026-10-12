#!/bin/bash
# Styled macOS DMG (background, icon layout, source folder) — Swift Prowser installer.
#
# Usage: ./create_styled_dmg.sh <path/to/App.app> <output.dmg>
#
# Requires: hdiutil, SetFile (Xcode CLT), Finder (AppleScript layout).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VOLUME_NAME_OVERRIDE="${VOLUME_NAME:-}"
DMG_ASSETS_DIR="${DMG_ASSETS_DIR:-$SCRIPT_DIR/DmgAssets}"
SOURCE_PREBLESSED="${SOURCE_PREBLESSED:-$SCRIPT_DIR/source_preblessed}"
VOL_ICON_ICNS="${VOL_ICON_ICNS:-$SWIFT_ROOT/Prowser/Resources/Assets/Prowser.icns}"
BG_IMAGE="$DMG_ASSETS_DIR/background.png"
SOURCE_ICON_HEIC="$DMG_ASSETS_DIR/source_folder.heic"

APP_PATH="${1:-}"
DMG_PATH="${2:-}"

usage() {
    echo "Usage: $0 <App.app> <output.dmg>" >&2
    exit 1
}

[[ -n "$APP_PATH" && -n "$DMG_PATH" ]] || usage

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
APP_NAME="$(basename "$APP_PATH")"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found: $APP_PATH" >&2
    exit 1
fi
APP_PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo "0.0")"
VOLUME_NAME="${VOLUME_NAME_OVERRIDE:-swift-prowser-${APP_VERSION}}"
if [[ ! -f "$BG_IMAGE" ]]; then
    echo "error: background image not found: $BG_IMAGE" >&2
    exit 1
fi
if [[ ! -f "$VOL_ICON_ICNS" ]]; then
    echo "error: volume icon not found: $VOL_ICON_ICNS" >&2
    exit 1
fi

for cmd in hdiutil SetFile osascript; do
    if ! command -v "$cmd" >/dev/null; then
        echo "error: '$cmd' is required (install Xcode Command Line Tools)." >&2
        exit 1
    fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/prowser_dmg_work.XXXXXX")"
TEMP_DMG="${TMPDIR:-/tmp}/prowser_dmg_rw_$$.dmg"

cleanup() {
    if mount | grep -q "/Volumes/$VOLUME_NAME"; then
        hdiutil detach -force "/Volumes/$VOLUME_NAME" 2>/dev/null || true
    fi
    rm -f "$TEMP_DMG"
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

rm -f "$DMG_PATH"
if mount | grep -q "/Volumes/$VOLUME_NAME"; then
    hdiutil detach -force "/Volumes/$VOLUME_NAME" || true
    sleep 1
fi

mkdir -p "$WORKDIR/.background"

echo "Staging DMG contents ..."
ditto --norsrc --noextattr --noqtn "$APP_PATH" "$WORKDIR/$APP_NAME"
ln -s /Applications "$WORKDIR/Applications"

SOURCE_STAGING="$WORKDIR/source"
if [[ -d "$SOURCE_PREBLESSED" ]]; then
    cp -R "$SOURCE_PREBLESSED" "$SOURCE_STAGING"
else
    mkdir -p "$SOURCE_STAGING"
    if [[ -f "$SOURCE_ICON_HEIC" ]]; then
        echo "Applying source folder icon from source_folder.heic ..."
        /usr/bin/swift "$SCRIPT_DIR/apply_source_folder_icon.swift" "$SOURCE_STAGING" "$SOURCE_ICON_HEIC"
    fi
fi

echo "Refreshing source tree (copy_swift_project_files.sh) ..."
"$SCRIPT_DIR/copy_swift_project_files.sh" -f "$SOURCE_STAGING"

# Re-apply folder icon after rsync if we did not copy a pre-blessed template.
if [[ ! -d "$SOURCE_PREBLESSED" ]] && [[ -f "$SOURCE_ICON_HEIC" ]]; then
    /usr/bin/swift "$SCRIPT_DIR/apply_source_folder_icon.swift" "$SOURCE_STAGING" "$SOURCE_ICON_HEIC" || true
fi

cp "$BG_IMAGE" "$WORKDIR/.background/background.png"
cp "$VOL_ICON_ICNS" "$WORKDIR/.VolumeIcon.icns"
SetFile -a V "$WORKDIR/.background"
SetFile -a V "$WORKDIR/.VolumeIcon.icns"

find "$WORKDIR" -name '.DS_Store' -delete 2>/dev/null || true

echo "Creating read-write disk image ..."
hdiutil create -ov \
    -volname "$VOLUME_NAME" \
    -srcfolder "$WORKDIR" \
    -fs HFS+ \
    -format UDRW \
    "$TEMP_DMG"

DEVICE="$(hdiutil attach -readwrite -owners on -noverify -noautoopen "$TEMP_DMG" \
    | awk '/^\/dev\/disk[0-9]+/ {print $1; exit}')"
MOUNT="/Volumes/$VOLUME_NAME"
sleep 2

cp "$VOL_ICON_ICNS" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
SetFile -a V "$MOUNT/.VolumeIcon.icns"

echo "Applying Finder layout (requires Finder) ..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1

        set containerWindow to container window
        set current view of containerWindow to icon view

        set toolbar visible of containerWindow to false
        set statusbar visible of containerWindow to false
        set bounds of containerWindow to {100, 100, 740, 580}

        set viewOptions to the icon view options of containerWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        set background picture of viewOptions to file ".background:background.png"

        set position of item "$APP_NAME" to {200, 150}
        set position of item "Applications" to {400, 150}
        if exists item "source" then
            set position of item "source" to {200, 310}
        end if

        update without registering applications
        delay 2
        close containerWindow

        if exists folder "source" then
            tell folder "source"
                open
                delay 1

                set sourceWindow to container window
                set current view of sourceWindow to icon view
                set toolbar visible of sourceWindow to false
                set statusbar visible of sourceWindow to false
                set bounds of sourceWindow to {100, 100, 740, 580}

                set sourceViewOptions to the icon view options of sourceWindow
                set arrangement of sourceViewOptions to not arranged
                set icon size of sourceViewOptions to 64
                set background picture of sourceViewOptions to file "background.png"

                close sourceWindow
            end tell
            update without registering applications
            delay 1
        end if
    end tell
end tell
EOF

sync
sleep 2

hdiutil detach "$DEVICE"

echo "Compressing to ULMO ..."
hdiutil convert "$TEMP_DMG" -format ULMO -o "$DMG_PATH"
rm -f "$TEMP_DMG"
trap - EXIT
rm -rf "$WORKDIR"

echo "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"
