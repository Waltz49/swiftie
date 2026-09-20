#!/bin/bash
# Create a styled installer DMG (requires a built .app).
#
# Default app: /Applications/swift-prowser.app
# Override: APP_PATH=/path/to/App.app ./build_dmg.sh
# Output: ~/Desktop/swift-prowser-<version>.dmg (override with DMG_PATH)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${APP_PATH:-/Applications/swift-prowser.app}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    echo "  Run: ./Scripts/build_app.sh --install /Applications/swift-prowser.app" >&2
    exit 1
fi

PLIST="$APP_PATH/Contents/Info.plist"
VERSION="0.0"
if [[ -f "$PLIST" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "0.0")"
fi

DMG_PATH="${DMG_PATH:-$HOME/Desktop/swift-prowser-${VERSION}.dmg}"

exec "$SCRIPT_DIR/Scripts/create_styled_dmg.sh" "$APP_PATH" "$DMG_PATH"
