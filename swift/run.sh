#!/bin/bash
# Convenience wrapper for Scripts/run.sh (debug build + launch Swift Prowser).

case "${1:-}" in
    -h|--help)
        exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Scripts/run.sh" "$@"
        ;;
esac

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Scripts/run.sh" "$@"
