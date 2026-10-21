#!/bin/bash
# Create a styled installer DMG (requires a built .app).
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — build a styled Swift Prowser installer DMG from an existing .app bundle.

Wraps Scripts/create_styled_dmg.sh (background, icon layout, optional source folder).
Requires a built application bundle on disk.

Usage: $(basename "$0")

Environment:
  APP_PATH    Path to .app (default: /Applications/swift-prowser.app)
  DMG_PATH    Output .dmg path (default: ~/Desktop/swift-prowser-<version>.dmg)

Options:
  -h, --help    Show this help

Example:
  ./Scripts/build_app.sh --install /Applications/swift-prowser.app
  $(basename "$0")
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
esac

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
