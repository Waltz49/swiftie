#!/bin/bash
# Run the Swift Prowser app (development).
#
# Default: launch via `open` so macOS treats Prowser as the foreground GUI app
# (keyboard focus works; do NOT background with `&` from the terminal).
#
# For debug logging to the terminal, use:
#   ./Scripts/run.sh --foreground ~/Downloads/
#   ./Scripts/run.sh --foreground --debug ~/Downloads/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$SWIFT_ROOT/.build/debug/Prowser"

cd "$SWIFT_ROOT"
swift build -c debug

ARGS=()
FOREGROUND=0
for arg in "$@"; do
    if [[ "$arg" == "--foreground" ]]; then
        FOREGROUND=1
    else
        ARGS+=("$arg")
    fi
done

if [[ "$FOREGROUND" -eq 1 ]]; then
    exec "$BINARY" "${ARGS[@]}"
fi

# Launch as a proper GUI process; activates and receives keyboard focus.
open -na "$BINARY" --args "${ARGS[@]}"
