#!/usr/bin/env bash
# Fail if vendored Python plugin list diverges from Swift catalog snapshot (CI drift check).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp)"
"$ROOT/Scripts/generate_imagegen_catalog_snapshot.sh" >/dev/null
# generate writes in-place; compare plugin_id sets only for a stable check
python3 <<PY
import json, sys
from pathlib import Path
root = Path("$ROOT")
committed = json.loads((root / "Prowser/Resources/ImageGenPluginCatalogSnapshot.json").read_text())
ids_committed = sorted(p["plugin_id"] for p in committed["plugins"])
# Re-read after regen (same file)
ids_live = ids_committed
swift_ids = sorted(
    line.split('"')[1]
    for line in (root / "Prowser/Services/ImageGen/ImageGenPluginCatalog.swift").read_text().splitlines()
    if 'pluginID: "' in line
)
missing_in_swift = set(ids_live) - set(swift_ids)
missing_in_python = set(swift_ids) - set(ids_live)
if missing_in_swift or missing_in_python:
    print("Catalog drift:", file=sys.stderr)
    if missing_in_swift:
        print("  Python plugins not in ImageGenPluginCatalog.swift:", sorted(missing_in_swift), file=sys.stderr)
    if missing_in_python:
        print("  Swift catalog entries without Python plugin:", sorted(missing_in_python), file=sys.stderr)
    sys.exit(1)
print("ImageGen catalog plugin_id sets match.")
PY
