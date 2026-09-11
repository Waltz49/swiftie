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
#
# The wrapper sets PROWSER_PYTHON_ROOT so Python workers can find prowser.py
# and venv_image_browser/ (default: repo root next to swift/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_ROOT/.." && pwd)"

OUTPUT="${HOME}/tmp/prowser_swift.app"
PYTHON_ROOT="${PROWSER_PYTHON_ROOT:-$REPO_ROOT}"
CONFIG=release
SKIP_BUILD=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -o, --output PATH       App bundle path (default: ~/tmp/prowser_swift.app)
  --python-root PATH      PROWSER_PYTHON_ROOT for worker subprocesses
                          (default: repo root containing prowser.py)
  --debug                 Build debug configuration instead of release
  --skip-build            Package existing .build artifacts (no swift build)
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

cp "$BINARY" "$APP_MACOS/Prowser.bin"
chmod +x "$APP_MACOS/Prowser.bin"
ditto "$RESOURCE_BUNDLE" "$APP_MACOS/Prowser_Prowser.bundle"

# Launcher sets PROWSER_PYTHON_ROOT for Finder/Dock launches (no shell env).
cat > "$APP_MACOS/Prowser" <<EOF
#!/bin/bash
export PROWSER_PYTHON_ROOT="${PYTHON_ROOT}"
exec "\$(dirname "\$0")/Prowser.bin" "\$@"
EOF
chmod +x "$APP_MACOS/Prowser"

cp "$INFO_PLIST_SRC" "$OUTPUT/Contents/Info.plist"

PLIST="$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment:PROWSER_PYTHON_ROOT" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:PROWSER_PYTHON_ROOT string ${PYTHON_ROOT}" "$PLIST"

echo "Done: $OUTPUT"
echo "  binary:        $APP_MACOS/Prowser.bin"
echo "  python root:   $PYTHON_ROOT"
echo ""
echo "Launch:"
echo "  open \"$OUTPUT\""
echo "  open -na \"$OUTPUT\" --args ~/Downloads/"
