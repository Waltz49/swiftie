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
#   ./Scripts/build_app.sh --skip-dlib     # skip Vendor/dlib-install (face stub only)
#
# Builds ProwserDlibBridgeCore + Swift app via `swift build`. When
# Vendor/dlib-install/lib/libdlib.a is missing, runs build_dlib_macos.sh first
# (requires git + cmake). Face .dat models are still downloaded on first use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT="${HOME}/tmp/prowser_swift.app"
CONFIG=release
SKIP_BUILD=0
SKIP_DLIB=0
CREATE_DMG=0
DMG_OUTPUT="/tmp/Prowser-swift.dmg"
NERB_PROFILE=0
NERB_PROFILE_PATH="/tmp/nerb"
REGISTER_DEFAULTS=0
FDA_WALKTHROUGH=0
INSTALL_APP_PATH=""

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

ensure_native_dlib() {
    local lib="$SWIFT_ROOT/Vendor/dlib-install/lib/libdlib.a"
    if [[ -f "$lib" ]]; then
        echo "Native dlib: $lib"
        return 0
    fi
    if [[ "$SKIP_DLIB" -eq 1 ]]; then
        echo "Skipping dlib build (--skip-dlib); ProwserDlibBridgeCore will compile without face encoding until Vendor/dlib-install exists."
        return 0
    fi
    for cmd in cmake git; do
        if ! command -v "$cmd" >/dev/null; then
            echo "error: '$cmd' is required to build dlib (face recognition)." >&2
            echo "  Install Xcode Command Line Tools and cmake (e.g. brew install cmake), or use --skip-dlib." >&2
            exit 1
        fi
    done
    echo "Building native dlib (Vendor/dlib-install missing)..."
    "$SCRIPT_DIR/build_dlib_macos.sh"
    if [[ ! -f "$lib" ]]; then
        echo "error: dlib install failed; expected $lib" >&2
        exit 1
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -o, --output PATH       App bundle path (default: ~/tmp/prowser_swift.app)
  --debug                 Build debug configuration instead of release
  --skip-build            Package existing .build artifacts (no swift build)
  --skip-dlib             Do not build Vendor/dlib-install (face recognition stub only)
  --dmg [PATH]            Also create a min-size LZMA DMG (default: /tmp/Prowser-swift.dmg)
  --reg                   Register this .app as the default opener for jpg, jpeg, png, webp
  --fda                   After build: reset optional TCC + open FDA Settings (see fda_walkthrough.sh)
  --install PATH          Copy signed .app to PATH (e.g. /Applications/swift-prowser.app) for a stable FDA target
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
        --skip-dlib)
            SKIP_DLIB=1
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
        --fda)
            FDA_WALKTHROUGH=1
            shift
            ;;
        --install)
            INSTALL_APP_PATH="$2"
            shift 2
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
    ensure_native_dlib
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
# SwiftPM Bundle.module resolves Prowser_Prowser.bundle under Contents/Resources when packaged.
# Do not place it at the .app root (breaks codesign sealing / Full Disk Access identity).
ditto --norsrc --noextattr --noqtn "$RESOURCE_BUNDLE" "$APP_RESOURCES/Prowser_Prowser.bundle"

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

sign_app_bundle() {
    local app_path="$1"
    local entitlements="$2"
    local binary="$app_path/Contents/MacOS/Prowser"
    # Ad-hoc signing; use a stable Developer ID identity here for daily installs if you have one.
    local -a sign=(codesign --force --sign - --timestamp=none)

    if [[ ! -f "$entitlements" ]]; then
        echo "warning: entitlements not found at $entitlements; skipping codesign" >&2
        return 0
    fi
    if [[ ! -f "$binary" ]]; then
        echo "error: app binary not found at $binary" >&2
        return 1
    fi

    echo "Code signing app bundle (ad-hoc, Photos entitlement on executable)..."
    "${sign[@]}" --entitlements "$entitlements" "$binary" \
        || { echo "error: codesign failed for $binary" >&2; return 1; }
    # Seal the .app so TCC (e.g. Full Disk Access) associates with the bundle, not a lone binary.
    "${sign[@]}" "$app_path" \
        || { echo "error: codesign failed for $app_path" >&2; return 1; }
    if codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
        echo "  codesign verify: OK"
    else
        echo "warning: codesign --verify reported issues for $app_path" >&2
    fi
}

ENTITLEMENTS="$SWIFT_ROOT/Prowser/Resources/Prowser.entitlements"
sign_app_bundle "$OUTPUT" "$ENTITLEMENTS"

if [[ -n "$INSTALL_APP_PATH" ]]; then
    INSTALL_APP_PATH="$(cd "$(dirname "$INSTALL_APP_PATH")" && pwd)/$(basename "$INSTALL_APP_PATH")"
    echo "Installing to $INSTALL_APP_PATH ..."
    rm -rf "$INSTALL_APP_PATH"
    ditto --norsrc --noextattr --noqtn "$OUTPUT" "$INSTALL_APP_PATH"
    sign_app_bundle "$INSTALL_APP_PATH" "$ENTITLEMENTS"
    OUTPUT="$INSTALL_APP_PATH"
fi

# Register with Launch Services so Finder Open With sees this bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$OUTPUT" >/dev/null 2>&1 || true
fi

echo "Done: $OUTPUT"
echo "  app size:      $(du -sh "$OUTPUT" | awk '{print $1}')"
echo "  binary:        $APP_MACOS/Prowser ($(du -h "$APP_MACOS/Prowser" | awk '{print $1}'))"
if [[ -f "$SWIFT_ROOT/Vendor/dlib-install/lib/libdlib.a" ]]; then
    echo "  face library:  dlib linked (models still download on first use)"
else
    echo "  face library:  stub only (rebuild without --skip-dlib for native face encoding)"
fi
if [[ "$NERB_PROFILE" -eq 1 ]]; then
    echo "  profile:       $NERB_PROFILE_PATH  (-p $NERB_PROFILE_PATH)"
fi
echo ""
echo "Privacy:"
echo "  Full Disk Access is manual: System Settings → Privacy & Security → Full Disk Access → +"
echo "  Choose this .app (listed as swift-prowser). Re-add after rebuild if access stops working."
echo "  Helper:  $SWIFT_ROOT/Scripts/fda_walkthrough.sh --app \"$OUTPUT\" --reset"
echo "  Or:      $SWIFT_ROOT/Scripts/build_app.sh --fda [--install /Applications/swift-prowser.app]"
echo ""

if [[ "$FDA_WALKTHROUGH" -eq 1 ]]; then
    "$SWIFT_ROOT/Scripts/fda_walkthrough.sh" --app "$OUTPUT" --reset
fi
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
