#!/usr/bin/env bash
# Ensure ImageGenPluginCatalog.swift plugin_ids match ImageGenPluginCatalogSnapshot.json.
set -euo pipefail
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
