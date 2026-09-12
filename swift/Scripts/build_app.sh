#!/bin/bash
# Build Prowser as a macOS .app bundle.
#
# Default output: ~/tmp/prowser_swift.app
#
# Usage:
#   ./Scripts/build_app.sh
#   ./Scripts/build_app.sh -o ~/Desktop/Prowser.app
#   ./Scripts/build_app.sh --debug
#   ./Scripts/build_app.sh --python-root /path/to/swiftie
#   ./Scripts/build_app.sh --dmg
#   ./Scripts/build_app.sh --dmg /tmp/Prowser.dmg
#   ./Scripts/build_app.sh --nerb          # embed -p /tmp/nerb (PROWSER_PROFILE)
#
# PROWSER_PYTHON_ROOT is set in Info.plist (LSEnvironment) so Python workers
# can find prowser.py and venv_image_browser/ (default: repo root next to swift/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_ROOT/.." && pwd)"

OUTPUT="${HOME}/tmp/prowser_swift.app"
PYTHON_ROOT="${PROWSER_PYTHON_ROOT:-$REPO_ROOT}"
CONFIG=release
SKIP_BUILD=0
CREATE_DMG=0
DMG_OUTPUT="/tmp/Prowser-swift.dmg"
NERB_PROFILE=0
NERB_PROFILE_PATH="/tmp/nerb"

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local staging
    staging="$(mktemp -d "${TMPDIR:-/tmp}/prowser_dmg_staging.XXXXXX")"

    dmg_path="$(cd "$(dirname "$dmg_path")" && pwd)/$(basename "$dmg_path")"
    echo "Creating DMG $dmg_path ..."
    ditto "$app_path" "$staging/swift-prowser.app"
    ln -s /Applications "$staging/Applications"
    rm -f "$dmg_path"
    hdiutil create -volname "swift-prowser" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
    rm -rf "$staging"
    echo "DMG: $dmg_path"
    open "$dmg_path"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -o, --output PATH       App bundle path (default: ~/tmp/prowser_swift.app)
  --python-root PATH      PROWSER_PYTHON_ROOT for worker subprocesses
                          (default: repo root containing prowser.py)
  --debug                 Build debug configuration instead of release
  --skip-build            Package existing .build artifacts (no swift build)
  --dmg [PATH]            Also create a drag-to-install DMG (default: /tmp/Prowser.dmg)
  --nerb                  Embed profile /tmp/nerb (same as -p /tmp/nerb at launch)
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        --python-root)
            PYTHON_ROOT="$2"
            shift 2
            ;;
        --debug)
            CONFIG=debug
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --dmg)
            CREATE_DMG=1
            if [[ $# -gt 1 && "$2" != -* ]]; then
                DMG_OUTPUT="$2"
                shift 2
            else
                shift
            fi
            ;;
        --nerb)
            NERB_PROFILE=1
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

OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
PYTHON_ROOT="$(cd "$PYTHON_ROOT" && pwd)"

if [[ ! -f "$PYTHON_ROOT/prowser.py" ]]; then
    echo "warning: $PYTHON_ROOT/prowser.py not found; Python workers may not start." >&2
fi

cd "$SWIFT_ROOT"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "Building Prowser ($CONFIG)..."
    swift build -c "$CONFIG"
else
    echo "Skipping build; packaging existing $CONFIG artifacts..."
fi

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BUILD_DIR/Prowser"
RESOURCE_BUNDLE="$BUILD_DIR/Prowser_Prowser.bundle"
INFO_PLIST_SRC="$SWIFT_ROOT/Prowser/Resources/Info.plist"

if [[ ! -f "$BINARY" ]]; then
    echo "error: binary not found at $BINARY" >&2
    exit 1
fi
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "error: resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi

APP_MACOS="$OUTPUT/Contents/MacOS"
APP_RESOURCES="$OUTPUT/Contents/Resources"

echo "Packaging $OUTPUT ..."
rm -rf "$OUTPUT"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

# CFBundleExecutable must be a Mach-O binary (shell scripts fail open with error -54).
cp "$BINARY" "$APP_MACOS/Prowser"
chmod +x "$APP_MACOS/Prowser"
# SwiftPM Bundle.module looks for Prowser_Prowser.bundle at Bundle.main.bundleURL
# (the .app wrapper). Contents/MacOS is ignored once the binary is inside an .app.
ditto "$RESOURCE_BUNDLE" "$OUTPUT/Prowser_Prowser.bundle"
ditto "$RESOURCE_BUNDLE" "$APP_RESOURCES/Prowser_Prowser.bundle"

cp "$INFO_PLIST_SRC" "$OUTPUT/Contents/Info.plist"

PLIST="$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment:PROWSER_PYTHON_ROOT" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:PROWSER_PYTHON_ROOT string ${PYTHON_ROOT}" "$PLIST"
if [[ "$NERB_PROFILE" -eq 1 ]]; then
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:PROWSER_PROFILE" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PROWSER_PROFILE string ${NERB_PROFILE_PATH}" "$PLIST"
fi

# Register with Launch Services so Finder Open With sees this bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$OUTPUT" >/dev/null 2>&1 || true
fi

echo "Done: $OUTPUT"
echo "  binary:        $APP_MACOS/Prowser"
echo "  python root:   $PYTHON_ROOT"
if [[ "$NERB_PROFILE" -eq 1 ]]; then
    echo "  profile:       $NERB_PROFILE_PATH  (-p $NERB_PROFILE_PATH)"
fi
echo ""
echo "Launch:"
echo "  open \"$OUTPUT\""
echo "  open -na \"$OUTPUT\" --args ~/Downloads/"
echo "  open -a \"$OUTPUT\" ~/Pictures/example.jpg"

if [[ "$CREATE_DMG" -eq 1 ]]; then
    create_dmg "$OUTPUT" "$DMG_OUTPUT"
fi
