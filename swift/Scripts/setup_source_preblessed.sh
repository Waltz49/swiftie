#!/bin/bash
# One-time setup for Scripts/source_preblessed (DMG source folder template).
#
# Preserves custom folder icon (Icon + com.apple.FinderInfo) if already assigned.
# Configures Finder .DS_Store: icon view, background.png, 640x480 window.
#
# Usage:
#   1. mkdir -p Scripts/source_preblessed and assign a custom icon in Finder if desired.
#   2. Run: ./Scripts/setup_source_preblessed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FOLDER="${SOURCE_FOLDER:-$SCRIPT_DIR/source_preblessed}"
BG_IMAGE="$SCRIPT_DIR/DmgAssets/background.png"

if [[ ! -d "$SOURCE_FOLDER" ]]; then
    mkdir -p "$SOURCE_FOLDER"
    if [[ -f "$SCRIPT_DIR/DmgAssets/source_folder.heic" ]]; then
        echo "Applying folder icon from DmgAssets/source_folder.heic ..."
        /usr/bin/swift "$SCRIPT_DIR/apply_source_folder_icon.swift" "$SOURCE_FOLDER" \
            "$SCRIPT_DIR/DmgAssets/source_folder.heic"
    fi
fi

if [[ ! -f "$BG_IMAGE" ]]; then
    echo "error: background.png not found: $BG_IMAGE" >&2
    exit 1
fi

cp "$BG_IMAGE" "$SOURCE_FOLDER/background.png"

osascript <<EOF
set sourcePath to POSIX file "$SOURCE_FOLDER"

tell application "Finder"
    tell folder sourcePath
        open
        delay 1

        set sourceWindow to container window
        set current view of sourceWindow to icon view
        set toolbar visible of sourceWindow to false
        set statusbar visible of sourceWindow to false
        set bounds of sourceWindow to {100, 100, 740, 580}

        set viewOptions to the icon view options of sourceWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 64
        set background picture of viewOptions to file "background.png"

        close sourceWindow
        update without registering applications
    end tell
end tell
EOF

if [[ -f "$SOURCE_FOLDER/.DS_Store" ]]; then
    echo "Configured: $SOURCE_FOLDER (.DS_Store written)"
else
    echo "warning: AppleScript ran but .DS_Store was not created."
    echo "  Layout is still applied when create_styled_dmg.sh runs."
fi
