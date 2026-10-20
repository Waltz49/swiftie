#!/bin/bash
# Build and run all Prowser unit tests (no Xcode GUI required).
set -euo pipefail

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
