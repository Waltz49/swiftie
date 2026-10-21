#!/bin/bash
# Copy a minimal Swift Prowser source tree for the DMG "source" folder.
#
# Usage: ./copy_swift_project_files.sh [-f] <target_directory>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_ROOT/.." && pwd)"
DMG_ASSETS="$SCRIPT_DIR/DmgAssets"

FORCE=0
TARGET_DIR=""

print_help() {
    cat <<EOF
Usage: $0 [-f] <target_directory>
Copies sources needed to build and run Prowser (minimal tree for DMG source/).

Options:
  -h, --help    Show this help
  -f            Update an existing target directory (removes stale files from older copies)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -f)
            FORCE=1
            shift
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -n "$TARGET_DIR" ]]; then
                echo "error: multiple target directories" >&2
                exit 1
            fi
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    print_help >&2
    exit 1
fi

TARGET_DIR="$(cd "$(dirname "$TARGET_DIR")" && pwd)/$(basename "$TARGET_DIR")"

if [[ -e "$TARGET_DIR" ]] && [[ "$(ls -A "$TARGET_DIR" 2>/dev/null | wc -l | tr -d ' ')" != "0" ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
        echo "error: target is not empty: $TARGET_DIR (use -f to merge/update)" >&2
        exit 1
    fi
fi

mkdir -p "$TARGET_DIR"

copy_file() {
    local src="$1"
    local dest="$2"
    if [[ ! -f "$src" ]]; then
        echo "error: missing source file: $src" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
}

copy_tree() {
    local src="$1"
    local dest="$2"
    if [[ ! -d "$src" ]]; then
        echo "error: missing source directory: $src" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    rsync -a --delete \
        --exclude '.DS_Store' \
        "$src/" "$dest/"
}

prune_stale_paths() {
    local t="$1"
    rm -rf \
        "$t/ProwserTests" \
        "$t/ModelArtifacts" \
        "$t/Scripts/DmgAssets" \
        "$t/Scripts/source_preblessed"
    rm -f \
        "$t/PARITY.md" \
        "$t/SWIFT-PYTHON.md" \
        "$t/MANUAL_SMOKE.md" \
        "$t/build_dmg.sh" \
        "$t/nohup.out"
    local sh
    for sh in "$t/Scripts"/*; do
        [[ -e "$sh" ]] || continue
        case "$(basename "$sh")" in
            run.sh|build_app.sh|build_dlib_macos.sh) ;;
            *) rm -f "$sh" ;;
        esac
    done
}

echo "Copying minimal Swift project into $TARGET_DIR ..."

if [[ "$FORCE" -eq 1 ]]; then
    prune_stale_paths "$TARGET_DIR"
fi

copy_file "$SWIFT_ROOT/Package.swift" "$TARGET_DIR/Package.swift"
copy_file "$SWIFT_ROOT/Package.resolved" "$TARGET_DIR/Package.resolved"
copy_file "$SWIFT_ROOT/setup.sh" "$TARGET_DIR/setup.sh"
copy_file "$SWIFT_ROOT/run.sh" "$TARGET_DIR/run.sh"
copy_file "$SWIFT_ROOT/README.md" "$TARGET_DIR/README.md"
copy_file "$SWIFT_ROOT/KEYBOARD.md" "$TARGET_DIR/KEYBOARD.md"
copy_file "$REPO_ROOT/LICENSE" "$TARGET_DIR/LICENSE"

copy_tree "$SWIFT_ROOT/Prowser" "$TARGET_DIR/Prowser"
copy_tree "$SWIFT_ROOT/ProwserDlibBridge" "$TARGET_DIR/ProwserDlibBridge"
copy_tree "$SWIFT_ROOT/ProwserDlibBridgeCore" "$TARGET_DIR/ProwserDlibBridgeCore"
# Symlinks under Prowser/Resources point at these package-root paths.
copy_file "$SWIFT_ROOT/requirements-imagegen.txt" "$TARGET_DIR/requirements-imagegen.txt"
copy_tree "$SWIFT_ROOT/ImageGenPython" "$TARGET_DIR/ImageGenPython"

mkdir -p "$TARGET_DIR/Scripts" "$TARGET_DIR/Vendor"
for script in run.sh build_app.sh build_dlib_macos.sh; do
    copy_file "$SWIFT_ROOT/Scripts/$script" "$TARGET_DIR/Scripts/$script"
    chmod +x "$TARGET_DIR/Scripts/$script"
done

# Preserve dlib install if the user already built in a copied source tree.
if [[ ! -d "$TARGET_DIR/Vendor/dlib-install" ]]; then
    mkdir -p "$TARGET_DIR/Vendor"
fi

if [[ -f "$DMG_ASSETS/background.png" ]]; then
    cp "$DMG_ASSETS/background.png" "$TARGET_DIR/background.png"
fi

chmod +x "$TARGET_DIR/setup.sh" "$TARGET_DIR/run.sh"

REQUIRED=(
    Package.swift
    Package.resolved
    README.md
    KEYBOARD.md
    LICENSE
    Scripts/build_app.sh
    Scripts/run.sh
    Scripts/build_dlib_macos.sh
    setup.sh
    run.sh
    Prowser/App/ProwserApp.swift
    requirements-imagegen.txt
    ImageGenPython/imagegen_plugins/__init__.py
)

missing=0
for path in "${REQUIRED[@]}"; do
    if [[ ! -e "$TARGET_DIR/$path" ]]; then
        echo "error: missing after copy: $path" >&2
        missing=1
    fi
done

if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

echo "Copy complete: $TARGET_DIR"
