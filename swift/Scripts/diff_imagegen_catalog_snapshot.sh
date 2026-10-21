#!/usr/bin/env bash
# Fail if vendored Python plugin list diverges from Swift catalog snapshot (CI drift check).
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — CI check: ImageGen Python plugins vs Swift catalog snapshot.

Regenerates ImageGenPluginCatalogSnapshot.json from ImageGenPython, then ensures
plugin_id sets match ImageGenPluginCatalog.swift (no drift between Python and Swift).

Usage: $(basename "$0")

Options:
  -h, --help    Show this help

Exits 0 when sets match; exits 1 and prints drift details on mismatch.
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
