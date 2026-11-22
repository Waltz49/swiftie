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
#   ./Scripts/build_app.sh --dmg /tmp/prowser-swift-<version>.dmg
#     (--dmg bumps patch version, regenerates prowser.php, builds DMG; needs Finder + SetFile)
#   ./Scripts/build_app.sh --dmg --version 0.9.100
#     (--version sets x.y.zzz in Info.plist instead of bumping the patch)
#   ./Scripts/build_app.sh --dmg --upload
#     (also scp DMG as prowser-swift-X.Y.Z.dmg + prowser-swift-latest.dmg and prowser.php)
#   ./Scripts/build_app.sh --nerb          # embed -p /tmp/nerb (PROWSER_PROFILE)
#   ./Scripts/build_app.sh --reg           # default opener for jpg/jpeg/png/webp
#   ./Scripts/build_app.sh --skip-dlib     # skip Vendor/dlib-install (face stub only)
#   ./Scripts/build_app.sh --bench         # also build Tools/FaceDetectBench CLI
#   ./Scripts/build_app.sh -v              # verbose swift build
#   ./Scripts/build_app.sh -vv             # extra-verbose swift build
#
# Builds ProwserDlibBridgeCore + Swift app via `swift build --product Prowser`. When
# Vendor/dlib-install/lib/libdlib.a is missing, runs build_dlib_macos.sh first
# (requires git + cmake). Face .dat models are still downloaded on first use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST_SRC="$SWIFT_ROOT/Prowser/Resources/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_SRC")"

OUTPUT="${HOME}/tmp/prowser_swift.app"
CONFIG=release
SKIP_BUILD=0
BUILD_BENCH=0
SKIP_DLIB=0
CREATE_DMG=0
DMG_OUTPUT_USER_SET=0
DMG_OUTPUT="/tmp/prowser-swift-${APP_VERSION}.dmg"
UPLOAD_SWIFT=0
NERB_PROFILE=0
NERB_PROFILE_PATH="/tmp/nerb"
REGISTER_DEFAULTS=0
FDA_WALKTHROUGH=0
INSTALL_APP_PATH=""
SWIFT_BUILD_VERBOSE=""
SET_VERSION=""

set_short_version() {
    local plist="$1"
    local new_ver="$2"
    if [[ ! "$new_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: version must be x.y.zzz (three numeric segments): $new_ver" >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_ver" "$plist"
    echo "$new_ver"
}

bump_short_version_patch() {
    local plist="$1"
    local ver prefix patch new_ver
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "error: cannot bump CFBundleShortVersionString: $ver" >&2
        exit 1
    fi
    patch="${ver##*.}"
    prefix="${ver%.*}"
    if [[ "$prefix" == "$ver" ]]; then
        prefix="0"
    fi
    patch=$((10#$patch + 1))
    new_ver="${prefix}.${patch}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_ver" "$plist"
    echo "$new_ver"
}

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    echo "Creating styled installer DMG ..."
    "$SCRIPT_DIR/create_styled_dmg.sh" "$app_path" "$dmg_path"
    open "$dmg_path"
}

upload_swift_release() {
    local dmg_path="$1"
    local version="$2"
    local remote="${PROWSER_SWIFT_UPLOAD_REMOTE:-pi@rpi:/var/www/waltzremote}"
    local php_path="$SWIFT_ROOT/../prowser.php"

    if ! command -v scp >/dev/null; then
        echo "error: scp is required for --upload" >&2
        exit 1
    fi
    if [[ ! -f "$dmg_path" ]]; then
        echo "error: DMG not found: $dmg_path" >&2
        exit 1
    fi
    if [[ ! -f "$php_path" ]]; then
        echo "error: prowser.php not found: $php_path" >&2
        exit 1
    fi

    echo "Uploading release $version to $remote ..."
    scp "$dmg_path" "${remote}/prowser-swift-${version}.dmg"
    scp "$dmg_path" "${remote}/prowser-swift-latest.dmg"
    scp "$php_path" "${remote}/prowser.php"
    echo "  prowser-swift-${version}.dmg"
    echo "  prowser-swift-latest.dmg"
    echo "  prowser.php"
}

# SPM copies Prowser/Resources symlinks as-is; relative targets break inside a .app on another Mac.
materialize_resource_bundle_symlinks() {
    local bundle="$1"
    local req="$bundle/requirements-imagegen.txt"
    local ig="$bundle/ImageGenPython"

    if [[ -L "$req" ]] || [[ ! -f "$req" ]]; then
        rm -f "$req"
        cp "$SWIFT_ROOT/requirements-imagegen.txt" "$req"
    fi
    if [[ -L "$ig" ]] || [[ ! -d "$ig/imagegen_plugins" ]]; then
        rm -rf "$ig"
        ditto "$SWIFT_ROOT/ImageGenPython" "$ig"
    fi
    rm -rf "$bundle/Prowser_Prowser.bundle.packaging_verify_hidden"
}

# Swift bundles PNG/SVG UI icons from Prowser/Resources/Assets (SPM .process), not repo-root assets/.
sync_repo_ui_assets() {
    local repo_assets
    repo_assets="$(cd "$SWIFT_ROOT/.." && pwd)/assets"
    local dest="$SWIFT_ROOT/Prowser/Resources/Assets"
    if [[ ! -d "$repo_assets" ]]; then
        echo "warning: repo UI assets not found at $repo_assets; skipping sync" >&2
        return 0
    fi
    mkdir -p "$dest"
    local ext copied=0
    for ext in png webp svg icns; do
        local f
        shopt -s nullglob
        for f in "$repo_assets"/*."$ext"; do
            cp -f "$f" "$dest/"
            copied=$((copied + 1))
        done
        shopt -u nullglob
    done
    if [[ "$copied" -gt 0 ]]; then
        echo "Synced $copied UI asset file(s) from $repo_assets → Prowser/Resources/Assets"
    fi
}

verify_portable_resource_bundle() {
    local app_path="$1"
    local embedded="$app_path/Contents/Resources/Prowser_Prowser.bundle"
    local main_resources="$app_path/Contents/Resources"

    if [[ ! -d "$embedded" ]]; then
        echo "error: missing embedded resource bundle: $embedded" >&2
        exit 1
    fi

    local rel
    local -a required_files=(
        requirements-imagegen.txt
        image_recognition_models.json
        dlib_face_models.json
        waltzremote_search_models.cer
        ImageGenPluginCatalogSnapshot.json
        applescript_pixelmator_export.applescript
        Prowser.icns
        copy.png
        pfilter.png
        fit.png
    )
    for rel in "${required_files[@]}"; do
        if [[ ! -r "$embedded/$rel" ]]; then
            echo "error: missing readable $rel in $embedded" >&2
            exit 1
        fi
    done
    if [[ ! -d "$embedded/ImageGenPython/imagegen_plugins" ]]; then
        echo "error: missing ImageGenPython tree in $embedded" >&2
        exit 1
    fi
    if [[ ! -r "$main_resources/Prowser.icns" ]]; then
        echo "error: missing Dock/Finder icon at $main_resources/Prowser.icns" >&2
        exit 1
    fi

    if [[ -r "$embedded/Assets/lorablob" ]]; then
        echo "Bundled lorablob: $embedded/Assets/lorablob"
    else
        echo "warning: lorablob not in bundle (Tools → Debug → Import Lora Defaults will be unavailable)" >&2
    fi

    /usr/bin/swift -e 'import Foundation
let embeddedPath = CommandLine.arguments[1]
guard let embedded = Bundle(path: embeddedPath) else {
    fputs("error: Bundle(path:) failed for resource bundle\n", stderr)
    exit(1)
}
let checks: [(String, String?)] = [
    ("image_recognition_models", "json"),
    ("dlib_face_models", "json"),
    ("waltzremote_search_models", "cer"),
    ("ImageGenPluginCatalogSnapshot", "json"),
    ("applescript_pixelmator_export", "applescript"),
    ("requirements-imagegen", "txt"),
    ("copy", "png"),
    ("Prowser", "icns"),
]
for (name, ext) in checks {
    guard let url = embedded.url(forResource: name, withExtension: ext),
          FileManager.default.isReadableFile(atPath: url.path) else {
        fputs("error: Bundle lookup failed for \(name).\(ext ?? "")\n", stderr)
        exit(1)
    }
}
let ig = embedded.resourceURL!.appendingPathComponent("ImageGenPython/imagegen_plugins")
guard FileManager.default.fileExists(atPath: ig.path) else {
    fputs("error: ImageGenPython/imagegen_plugins missing\n", stderr)
    exit(1)
}
' "$embedded"
}

# Ensures launch does not depend on the local .build copy (SPM compile-time fallback).
verify_launch_without_build_fallback() {
    local app_path="$1"
    local build_bundle="$2"
    local hidden=""

    if [[ ! -d "$build_bundle" ]]; then
        return 0
    fi
    hidden="${build_bundle}.packaging_verify_hidden"
    rm -rf "$hidden"
    mv "$build_bundle" "$hidden"

    local binary="$app_path/Contents/MacOS/Prowser"
    # Isolated profile so a running daily Prowser instance does not steal the lock and exit immediately.
    local smoke_profile="${TMPDIR:-/tmp}/prowser_packaging_verify_$$"
    mkdir -p "$smoke_profile"
    PROWSER_PROFILE="$smoke_profile" "$binary" -p "$smoke_profile" >/dev/null 2>&1 &
    local pid=$!
    local ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            ok=0
            break
        fi
        ok=1
        sleep 0.2
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$smoke_profile"
    mv "$hidden" "$build_bundle"

    if [[ "$ok" -ne 1 ]]; then
        echo "error: app exited immediately without .build resource bundle fallback" >&2
        echo "  (check Console for resource_bundle_accessor fatalError)" >&2
        exit 1
    fi
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
$(basename "$0") — build Swift Prowser as a macOS .app bundle.

Compiles via \`swift build --product Prowser\`, packages Mach-O + resources into a bundle,
and optionally creates a DMG, registers file types, or runs FDA setup.

Used by: command line (developer/maintainer). Invokes adapt_prowser_php_for_swift.py,
create_styled_dmg.sh, build_dlib_macos.sh, and fda_walkthrough.sh when requested.

Usage: $(basename "$0") [options]

Options:
  -o, --output PATH       App bundle path (default: ~/tmp/prowser_swift.app)
  --debug                 Build debug configuration instead of release
  --skip-build            Package existing .build artifacts (no swift build)
  --bench                 Also build FaceDetectBench CLI (not packaged in .app)
  --skip-dlib             Do not build Vendor/dlib-install (face recognition stub only)
  --dmg [PATH]            Create installer DMG (bumps patch version, regenerates prowser.php; default DMG: /tmp/prowser-swift-<version>.dmg)
  --version X.Y.ZZZ       Set CFBundleShortVersionString (x.y.zzz); with --dmg, skips auto patch bump
  --upload                Implies --dmg; scp DMG (versioned + latest) and prowser.php (PROWSER_SWIFT_UPLOAD_REMOTE)
  --reg                   Register this .app as the default opener for jpg, jpeg, png, webp
  --fda                   After build: reset TCC + open FDA Settings (no clipboard/dialog)
  --install PATH          Copy signed .app to PATH (e.g. /Applications/swift-prowser.app) for a stable FDA target
  --nerb                  Embed profile /tmp/nerb (same as -p /tmp/nerb at launch)
  -v, -vv                 Pass verbosity through to \`swift build\`
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
        --bench)
            BUILD_BENCH=1
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
                DMG_OUTPUT_USER_SET=1
                shift 2
            else
                shift
            fi
            ;;
        --upload)
            UPLOAD_SWIFT=1
            CREATE_DMG=1
            shift
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
        --version)
            if [[ $# -lt 2 ]]; then
                echo "error: --version requires a value" >&2
                exit 1
            fi
            SET_VERSION="$2"
            shift 2
            ;;
        -vv)
            SWIFT_BUILD_VERBOSE=-vv
            shift
            ;;
        -v)
            SWIFT_BUILD_VERBOSE=-v
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

if [[ -n "$SET_VERSION" ]]; then
    APP_VERSION="$(set_short_version "$INFO_PLIST_SRC" "$SET_VERSION")"
    echo "Set version: $APP_VERSION"
fi

if [[ "$CREATE_DMG" -eq 1 ]]; then
    if [[ -z "$SET_VERSION" ]]; then
        APP_VERSION="$(bump_short_version_patch "$INFO_PLIST_SRC")"
        echo "Release version: $APP_VERSION"
    fi
    if [[ "$DMG_OUTPUT_USER_SET" -eq 0 ]]; then
        DMG_OUTPUT="/tmp/prowser-swift-${APP_VERSION}.dmg"
    fi
    python3 "$SCRIPT_DIR/adapt_prowser_php_for_swift.py"
fi

OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

cd "$SWIFT_ROOT"
sync_repo_ui_assets
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    ensure_native_dlib
    echo "Building Prowser ($CONFIG)..."
    if [[ "$CONFIG" == "release" ]]; then
        # Optional SWIFT_BUILD_VERBOSE (-v / -vv); unquoted so empty string omits the flag.
        swift build $SWIFT_BUILD_VERBOSE -c release --product Prowser -Xswiftc -Osize -Xlinker -dead_strip
    else
        swift build $SWIFT_BUILD_VERBOSE -c "$CONFIG" --product Prowser
    fi
    if [[ "$BUILD_BENCH" -eq 1 ]]; then
        echo "Building FaceDetectBench ($CONFIG)..."
        if [[ "$CONFIG" == "release" ]]; then
            swift build $SWIFT_BUILD_VERBOSE -c release --product FaceDetectBench -Xswiftc -Osize -Xlinker -dead_strip
        else
            swift build $SWIFT_BUILD_VERBOSE -c "$CONFIG" --product FaceDetectBench
        fi
    fi
else
    echo "Skipping build; packaging existing $CONFIG artifacts..."
    echo "warning: UI asset sync ran, but SPM only re-embeds Resources/Assets on rebuild (omit --skip-build)" >&2
fi

BUILD_DIR="$(swift build $SWIFT_BUILD_VERBOSE -c "$CONFIG" --product Prowser --show-bin-path)"
BINARY="$BUILD_DIR/Prowser"
RESOURCE_BUNDLE="$BUILD_DIR/Prowser_Prowser.bundle"

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
# Packaged apps load this via ProwserResourceBundle (Contents/Resources), not SPM's .build fallback.
ditto --norsrc --noextattr --noqtn "$RESOURCE_BUNDLE" "$APP_RESOURCES/Prowser_Prowser.bundle"
materialize_resource_bundle_symlinks "$APP_RESOURCES/Prowser_Prowser.bundle"

cp "$INFO_PLIST_SRC" "$OUTPUT/Contents/Info.plist"
ICON_SRC="$SWIFT_ROOT/Prowser/Resources/Assets/Prowser.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_RESOURCES/Prowser.icns"
else
    echo "error: missing app icon at $ICON_SRC" >&2
    exit 1
fi
verify_portable_resource_bundle "$OUTPUT"

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
verify_launch_without_build_fallback "$OUTPUT" "$RESOURCE_BUNDLE"
echo "  portable check:  resource bundle loads without local .build fallback"

if [[ -n "$INSTALL_APP_PATH" ]]; then
    INSTALL_APP_PATH="$(cd "$(dirname "$INSTALL_APP_PATH")" && pwd)/$(basename "$INSTALL_APP_PATH")"
    echo "Installing to $INSTALL_APP_PATH ..."
    rm -rf "$INSTALL_APP_PATH"
    ditto --norsrc --noextattr --noqtn "$OUTPUT" "$INSTALL_APP_PATH"
    sign_app_bundle "$INSTALL_APP_PATH" "$ENTITLEMENTS"
    verify_portable_resource_bundle "$INSTALL_APP_PATH"
    verify_launch_without_build_fallback "$INSTALL_APP_PATH" "$RESOURCE_BUNDLE"
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
    "$SWIFT_ROOT/Scripts/fda_walkthrough.sh" --app "$OUTPUT" --reset --open-only
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
    if [[ "$UPLOAD_SWIFT" -eq 1 ]]; then
        upload_swift_release "$DMG_OUTPUT" "$APP_VERSION"
    fi
fi
