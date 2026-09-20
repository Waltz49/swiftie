#!/bin/bash
# Setup Swift Prowser for development / building from source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Setting up Swift Prowser ..."
echo "================================================"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: macOS is required." >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "error: Xcode Command Line Tools are required (xcode-select --install)." >&2
    exit 1
fi

if ! command -v swift >/dev/null; then
    echo "error: swift not found on PATH." >&2
    exit 1
fi

echo "Swift: $(swift --version | head -1)"

HAS_CMAKE=0
HAS_GIT=0
command -v cmake >/dev/null && HAS_CMAKE=1
command -v git >/dev/null && HAS_GIT=1

if [[ "$HAS_CMAKE" -eq 0 || "$HAS_GIT" -eq 0 ]]; then
    echo "warning: cmake and git are needed to build native dlib (face recognition)."
    echo "  Install with: brew install cmake"
    echo "  Or use Scripts/build_app.sh --skip-dlib for a stub face build."
fi

echo "Resolving Swift package dependencies ..."
swift package resolve

DLIB_LIB="Vendor/dlib-install/lib/libdlib.a"
if [[ ! -f "$DLIB_LIB" ]]; then
    if [[ "$HAS_CMAKE" -eq 1 ]] && [[ "$HAS_GIT" -eq 1 ]]; then
        echo "Building native dlib ..."
        ./Scripts/build_dlib_macos.sh
    else
        echo "Native dlib not installed ($DLIB_LIB missing)."
        echo "  Install cmake and git, then re-run ./setup.sh or ./Scripts/run.sh"
        echo "  Or: ./Scripts/build_dlib_macos.sh"
    fi
fi

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  ./run.sh [folder]                      # debug build + launch"
echo "  ./Scripts/build_app.sh                 # release .app bundle"
echo "  See README.md and KEYBOARD.md"
echo "================================================"
