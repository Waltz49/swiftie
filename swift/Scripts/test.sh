#!/bin/bash
# Build and run all Prowser unit tests (no Xcode GUI required).
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — build and run Prowser Swift package tests via \`swift test\`.

macOS and Xcode Command Line Tools are required. Additional arguments are passed to
\`swift test\` (e.g. --filter ProwserTests/SomeTest).

Usage: $(basename "$0") [swift test options...]

Options:
  -h, --help    Show this help (script usage; not \`swift test --help\`)
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SWIFT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: macOS is required." >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "error: Xcode Command Line Tools are required (xcode-select --install)." >&2
    exit 1
fi

exec swift test "$@"
