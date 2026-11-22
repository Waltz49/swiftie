#!/bin/bash
# Build an encrypted lorablob from a filtered lora_catalog.json export.
#
# Output: Prowser/Resources/Assets/lorablob (gitignored; maintainer runs before release builds).
#
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — export filtered LoRA defaults and write encrypted lorablob.

Runs export_lora_defaults_for_blob.py (LoRAs with a recoverable safetensors
download: HF repo/filename, safetensors_origin, or Civitai/HF URLs — including
legacy catalog IDs referenced in settings), then PackLoraBlob (AES-GCM + PBKDF2).
Output: Prowser/Resources/Assets/lorablob (gitignored; rebuild app to bundle).

Used by: command line (maintainer). End users: LoRADefaultsImportService (Import Lora Defaults).

Usage:
  $(basename "$0") [OPTIONS] [lora_catalog.json]

Arguments:
  lora_catalog.json   Source catalog (default: ~/.swift-prowser/data/lora_catalog.json)

Options:
  -h, --help          Show this help

After packing, run: ./Scripts/build_app.sh
End users import via Tools → Debug → Import Lora Defaults.
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
CATALOG="${1:-}"
OUTPUT="$SWIFT_ROOT/Prowser/Resources/Assets/lorablob"
TMP_JSON="$(mktemp -t lorablob_export.XXXXXX.json)"
PACK_BIN="$SWIFT_ROOT/.build/debug/PackLoraBlob"

cleanup() {
    rm -f "$TMP_JSON"
    unset LORABLOB_PASSWORD
}
trap cleanup EXIT

if [[ -z "$CATALOG" ]]; then
    CATALOG="$HOME/.swift-prowser/data/lora_catalog.json"
fi

if [[ ! -r "$CATALOG" ]]; then
    echo "error: catalog not readable: $CATALOG" >&2
    exit 1
fi

echo "Exporting filtered defaults from: $CATALOG"
"$SCRIPT_DIR/export_lora_defaults_for_blob.py" "$CATALOG" >"$TMP_JSON"

(cd "$SWIFT_ROOT" && swift build --product PackLoraBlob)
PACK_BIN="$(cd "$SWIFT_ROOT" && swift build --product PackLoraBlob --show-bin-path)/PackLoraBlob"

read -r -s -p "Encryption password: " PASS1
echo ""
read -r -s -p "Confirm password: " PASS2
echo ""
if [[ "$PASS1" != "$PASS2" ]]; then
    echo "error: passwords do not match" >&2
    exit 1
fi
if [[ -z "$PASS1" ]]; then
    echo "error: empty password" >&2
    exit 1
fi

export LORABLOB_PASSWORD="$PASS1"
"$PACK_BIN" --input "$TMP_JSON" --output "$OUTPUT"

BYTES="$(wc -c <"$OUTPUT" | tr -d ' ')"
echo "Wrote $OUTPUT ($BYTES bytes)."
echo "Rebuild the app (./Scripts/build_app.sh) to bundle lorablob."
unset LORABLOB_PASSWORD