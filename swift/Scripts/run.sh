#!/bin/bash
# Run the Swift Prowser app (development).
#
# Default: launch via `open` so macOS treats Prowser as the foreground GUI app
# (keyboard focus works; do NOT background with `&` from the terminal).
#
# For debug logging to the terminal, use:
#   ./Scripts/run.sh --foreground ~/Downloads/
#   ./Scripts/run.sh --foreground --debug ~/Downloads/
#
# Builds Vendor/dlib-install automatically when missing (same as build_app.sh).
# Use --skip-dlib to compile without native face encoding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$SWIFT_ROOT/.build/debug/Prowser"

ensure_native_dlib() {
    local lib="$SWIFT_ROOT/Vendor/dlib-install/lib/libdlib.a"
    if [[ -f "$lib" ]]; then
        return 0
    fi
    if [[ "$SKIP_DLIB" -eq 1 ]]; then
        echo "Skipping dlib build (--skip-dlib); face encoding stub until Vendor/dlib-install exists."
        return 0
    fi
    for cmd in cmake git; do
        if ! command -v "$cmd" >/dev/null; then
            echo "error: '$cmd' is required to build dlib (face recognition)." >&2
            echo "  Install cmake (e.g. brew install cmake), or use --skip-dlib." >&2
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

cd "$SWIFT_ROOT"

ARGS=()
FOREGROUND=0
SKIP_DLIB=0
for arg in "$@"; do
    case "$arg" in
        --foreground)
            FOREGROUND=1
            ;;
        --skip-dlib)
            SKIP_DLIB=1
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

ensure_native_dlib
swift build -c debug

if [[ "$FOREGROUND" -eq 1 ]]; then
    if [[ ${#ARGS[@]} -gt 0 ]]; then
        exec "$BINARY" "${ARGS[@]}"
    else
        exec "$BINARY"
    fi
fi

# Launch as a proper GUI process; activates and receives keyboard focus.
# (With `set -u`, empty "${ARGS[@]}" is unbound on macOS bash 3.2.)
if [[ ${#ARGS[@]} -gt 0 ]]; then
    open -na "$BINARY" --args "${ARGS[@]}"
else
    open -na "$BINARY"
fi
