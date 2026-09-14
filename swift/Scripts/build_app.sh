#!/bin/bash
# Build Prowser as a macOS .app bundle.
#
# Default output: ~/tmp/prowser_swift.app
#
# Usage:
#   ./Scripts/build_app.sh
#   ./Scripts/build_app.sh -o ~/Desktop/Prowser.app
#   ./Scripts/build_app.sh --debug
#   ./Scripts/build_app.sh --dmg
#   ./Scripts/build_app.sh --dmg /tmp/Prowser.dmg
#   ./Scripts/build_app.sh --nerb          # embed -p /tmp/nerb (PROWSER_PROFILE)
#   ./Scripts/build_app.sh --reg           # default opener for jpg/jpeg/png/webp
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT="${HOME}/tmp/prowser_swift.app"
CONFIG=release
SKIP_BUILD=0
CREATE_DMG=0
DMG_OUTPUT="/tmp/Prowser-swift.dmg"
NERB_PROFILE=0
NERB_PROFILE_PATH="/tmp/nerb"
REGISTER_DEFAULTS=0

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local staging
    staging="$(mktemp -d "${TMPDIR:-/tmp}/prowser_dmg_staging.XXXXXX")"

    dmg_path="$(cd "$(dirname "$dmg_path")" && pwd)/$(basename "$dmg_path")"
    echo "Creating min-size DMG $dmg_path ..."
    # Skip resource forks / quarantine xattrs so they are not stored in the image.
    ditto --norsrc --noextattr --noqtn "$app_path" "$staging/swift-prowser.app"
    ln -s /Applications "$staging/Applications"
    find "$staging" -name '.DS_Store' -delete 2>/dev/null || true
    rm -f "$dmg_path"
    # ULMO (LZMA) is smaller than UDZO/UDBZ for this bundle.
    hdiutil create \
        -volname "swift-prowser" \
        -srcfolder "$staging" \
        -ov \
        -fs HFS+ \
        -format ULMO \
        "$dmg_path"
    rm -rf "$staging"
    echo "DMG: $dmg_path ($(du -h "$dmg_path" | awk '{print $1}'))"
    open "$dmg_path"
}

register_default_open() {
    local app_path="$1"
    echo "Registering $app_path as the default opener for jpg, jpeg, png, webp ..."
    PROWSER_REG_APP="$app_path" /usr/bin/swift - <<'EOF'
import AppKit
import Foundation
import UniformTypeIdentifiers

let appPath = ProcessInfo.processInfo.environment["PROWSER_REG_APP"] ?? ""
guard !appPath.isEmpty else {
    fputs("error: PROWSER_REG_APP is empty\n", stderr)
    exit(1)
}
let appURL = URL(fileURLWithPath: appPath)
let requested: [(String, UTType?)] = [
    ("jpg", .jpeg),
    ("jpeg", .jpeg),
    ("png", .png),
    ("webp", UTType(filenameExtension: "webp") ?? UTType("org.webmproject.webp")),
]

let sem = DispatchSemaphore(value: 0)
var failed = false
Task {
    var seen = Set<String>()
    for (ext, type) in requested {
        guard let type else {
            fputs("  \(ext): unknown UTI\n", stderr)
            failed = true
            continue
        }
        if seen.contains(type.identifier) {
            print("  \(ext): \(appURL.lastPathComponent) (\(type.identifier))")
            continue
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
            seen.insert(type.identifier)
            print("  \(ext): \(appURL.lastPathComponent) (\(type.identifier))")
        } catch {
            fputs("  \(ext): \(error.localizedDescription)\n", stderr)
            failed = true
        }
    }
    sem.signal()
}
while sem.wait(timeout: .now() + 0.05) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
if failed { exit(1) }
EOF
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -o, --output PATH       App bundle path (default: ~/tmp/prowser_swift.app)
  --debug                 Build debug configuration instead of release
  --skip-build            Package existing .build artifacts (no swift build)
  --dmg [PATH]            Also create a min-size LZMA DMG (default: /tmp/Prowser-swift.dmg)
  --reg                   Register this .app as the default opener for jpg, jpeg, png, webp
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
        --reg)
            REGISTER_DEFAULTS=1
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

cd "$SWIFT_ROOT"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "Building Prowser ($CONFIG)..."
    if [[ "$CONFIG" == "release" ]]; then
        swift build -c release -Xswiftc -Osize -Xlinker -dead_strip
    else
        swift build -c "$CONFIG"
    fi
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
if [[ "$CONFIG" == "release" ]]; then
    # Drop debug symbols and unused local symbols from the packaged binary.
    strip -rSTx "$APP_MACOS/Prowser"
fi
# SwiftPM Bundle.module looks for Prowser_Prowser.bundle at Bundle.main.bundleURL
# (the .app wrapper). Do not also copy it into Contents/Resources (duplicate weight).
ditto --norsrc --noextattr --noqtn "$RESOURCE_BUNDLE" "$OUTPUT/Prowser_Prowser.bundle"

cp "$INFO_PLIST_SRC" "$OUTPUT/Contents/Info.plist"
ICON_SRC="$SWIFT_ROOT/Prowser/Resources/Assets/Prowser.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_RESOURCES/Prowser.icns"
fi

PLIST="$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST" 2>/dev/null || true
if [[ "$NERB_PROFILE" -eq 1 ]]; then
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:PROWSER_PROFILE" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PROWSER_PROFILE string ${NERB_PROFILE_PATH}" "$PLIST"
fi

ENTITLEMENTS="$SWIFT_ROOT/Prowser/Resources/Prowser.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    echo "Signing with Photos library entitlement..."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_MACOS/Prowser" 2>/dev/null \
        || echo "warning: codesign failed (Photos privacy prompt may not appear for unsigned runs)" >&2
fi

# Register with Launch Services so Finder Open With sees this bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$OUTPUT" >/dev/null 2>&1 || true
fi

echo "Done: $OUTPUT"
echo "  app size:      $(du -sh "$OUTPUT" | awk '{print $1}')"
echo "  binary:        $APP_MACOS/Prowser ($(du -h "$APP_MACOS/Prowser" | awk '{print $1}'))"
if [[ "$NERB_PROFILE" -eq 1 ]]; then
    echo "  profile:       $NERB_PROFILE_PATH  (-p $NERB_PROFILE_PATH)"
fi
echo ""
echo "Launch:"
echo "  open \"$OUTPUT\""
echo "  open -na \"$OUTPUT\" --args ~/Downloads/"
echo "  open -a \"$OUTPUT\" ~/Pictures/example.jpg"

if [[ "$REGISTER_DEFAULTS" -eq 1 ]]; then
    register_default_open "$OUTPUT"
fi

if [[ "$CREATE_DMG" -eq 1 ]]; then
    create_dmg "$OUTPUT" "$DMG_OUTPUT"
fi
