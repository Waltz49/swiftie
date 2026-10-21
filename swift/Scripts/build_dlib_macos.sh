#!/bin/bash
# Build a trimmed static dlib for ProwserDlibBridge (maintainer / CI).
#
# Output: swift/Vendor/dlib-install/{include,lib/libdlib.a}
#
# Usage:
#   ./swift/Scripts/build_dlib_macos.sh
#   ./swift/Scripts/build_dlib_macos.sh --clean
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR="$SWIFT_ROOT/Vendor"
BUILD="$VENDOR/dlib-build"
INSTALL="$VENDOR/dlib-install"
DLIB_VERSION="19.24.6"
DLIB_SRC="$VENDOR/dlib-src"

usage() {
  cat <<EOF
$(basename "$0") — build a trimmed static dlib for ProwserDlibBridge (maintainer / CI).

Output: swift/Vendor/dlib-install/{include,lib/libdlib.a}
Fetches dlib v${DLIB_VERSION} under Vendor/dlib-src when needed.

Usage: $(basename "$0") [options]

Options:
  --clean       Remove Vendor/dlib-build, dlib-install, and dlib-src before building
  -h, --help    Show this help
EOF
}

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$BUILD" "$INSTALL" "$DLIB_SRC"
fi

mkdir -p "$VENDOR"

if [[ ! -d "$DLIB_SRC" ]]; then
  echo "Fetching dlib $DLIB_VERSION ..."
  git clone --depth 1 --branch "v$DLIB_VERSION" https://github.com/davisking/dlib.git "$DLIB_SRC"
fi

cmake -S "$DLIB_SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DBUILD_SHARED_LIBS=OFF \
  -DDLIB_USE_CUDA=OFF \
  -DDLIB_USE_BLAS=ON \
  -DDLIB_USE_LAPACK=ON \
  -DDLIB_LINK_WITH_SQLITE3=OFF \
  -DDLIB_JPEG_SUPPORT=OFF \
  -DDLIB_PNG_SUPPORT=OFF \
  -DDLIB_GIF_SUPPORT=OFF \
  -DDLIB_NO_GUI_SUPPORT=ON

cmake --build "$BUILD" --target install -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "Installed dlib to $INSTALL"
echo "Run: cd swift && swift build -c release"
