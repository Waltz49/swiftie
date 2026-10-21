#!/usr/bin/env bash
# Ensure ImageGenPluginCatalog.swift plugin_ids match ImageGenPluginCatalogSnapshot.json.
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — verify Swift ImageGen plugin IDs match the JSON catalog snapshot.

Compares pluginID entries in ImageGenPluginCatalog.swift against
Prowser/Resources/ImageGenPluginCatalogSnapshot.json (sorted plugin_id lists).

Usage: $(basename "$0")

Options:
  -h, --help    Show this help

Exits 0 when lists match; non-zero when diff reports differences.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_IDS="$(rg 'pluginID: "' "$ROOT/Prowser/Services/ImageGen/ImageGenPluginCatalog.swift" -o | sed 's/pluginID: "//;s/"$//' | sort -u)"
JSON_IDS="$(python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
for pl in sorted(data.get('plugins', []), key=lambda x: x.get('plugin_id','')):
    print(pl['plugin_id'])
" "$ROOT/Prowser/Resources/ImageGenPluginCatalogSnapshot.json")"
diff -u <(echo "$SWIFT_IDS") <(echo "$JSON_IDS") && echo "Plugin catalog ids match."
