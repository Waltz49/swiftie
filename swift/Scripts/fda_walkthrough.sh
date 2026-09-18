#!/bin/bash
# Full Disk Access helper for swift-prowser (ad-hoc / dev builds).
#
# macOS does not allow granting FDA from a script, installer, or AppleScript UI
# automation in any supported way. This script automates what is possible:
#   - optional TCC reset for com.prowser.Prowser (drops stale FDA after rebuild)
#   - copy the .app path to the clipboard
#   - open System Settings → Privacy & Security → Full Disk Access
#   - show a short AppleScript dialog with the exact steps
#
# Usage:
#   ./Scripts/fda_walkthrough.sh
#   ./Scripts/fda_walkthrough.sh --app ~/tmp/prowser_swift.app
#   ./Scripts/fda_walkthrough.sh --app /Applications/swift-prowser.app --reset
#   ./Scripts/fda_walkthrough.sh --check --app ~/tmp/prowser_swift.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_ID="com.prowser.Prowser"
APP_PATH="${HOME}/tmp/prowser_swift.app"
DO_RESET=0
DO_CHECK=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --app PATH    .app bundle to grant FDA (default: ~/tmp/prowser_swift.app)
  --reset       Run: tccutil reset SystemPolicyAllFiles $BUNDLE_ID
                (clears old FDA for this bundle id; you must re-add the app)
  --check       Best-effort check via TCC.db (needs FDA on this shell; optional)
  -h, --help    Show this help

After each ad-hoc rebuild, codesign identity changes — re-run this script and
toggle FDA for the same fixed .app path (prefer /Applications/swift-prowser.app).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_PATH="$2"
            shift 2
            ;;
        --reset)
            DO_RESET=1
            shift
            ;;
        --check)
            DO_CHECK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found: $APP_PATH" >&2
    echo "Build first: $SWIFT_ROOT/Scripts/build_app.sh" >&2
    exit 1
fi

if [[ "$DO_CHECK" -eq 1 ]]; then
    TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
    if [[ ! -r "$TCC_DB" ]]; then
        echo "check: cannot read TCC.db (grant FDA to Terminal first, or ignore --check)"
        exit 2
    fi
    # auth_value 2 = allowed for SystemPolicyAllFiles in many macOS versions
    count="$(/usr/bin/sqlite3 "$TCC_DB" \
        "SELECT COUNT(*) FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='$BUNDLE_ID' AND auth_value IN (2, 4);" \
        2>/dev/null || echo "0")"
    if [[ "${count:-0}" -gt 0 ]]; then
        echo "check: FDA appears granted for bundle id $BUNDLE_ID (verify path in Settings)"
        exit 0
    fi
    echo "check: no FDA row found for $BUNDLE_ID — run without --check to open Settings"
    exit 1
fi

if [[ "$DO_RESET" -eq 1 ]]; then
    echo "Resetting FDA TCC entry for $BUNDLE_ID ..."
    if tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" 2>/dev/null; then
        echo "  tccutil reset: OK (remove any duplicate rows in Settings manually)"
    else
        echo "  tccutil reset: failed or no prior entry (continuing)"
    fi
fi

echo "App:        $APP_PATH"
echo "Bundle ID:  $BUNDLE_ID"
if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    echo "codesign:   OK"
else
    echo "codesign:   warning — verify failed; FDA may not stick"
fi
echo ""
echo "Designated requirement (for PPPC / MDM only):"
codesign -dr - "$APP_PATH" 2>/dev/null | sed 's/^/  /' || true

printf '%s' "$APP_PATH" | pbcopy
echo ""
echo "Copied app path to clipboard."

open_fda_settings() {
    if open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" 2>/dev/null; then
        return 0
    fi
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}

open_fda_settings

/usr/bin/osascript <<EOF
display dialog "Full Disk Access for swift-prowser

1. In Full Disk Access, remove old Prowser / swift-prowser entries.
2. Click + and press Cmd+Shift+G.
3. Paste (Cmd+V) — path is already on the clipboard:
   $APP_PATH
4. Select the .app, Open, turn ON, authenticate.

macOS cannot add FDA automatically; this is required after ad-hoc rebuilds." buttons {"OK"} default button "OK" with title "swift-prowser FDA"
EOF

echo ""
echo "Done. Quit and relaunch swift-prowser from this .app path after granting."
