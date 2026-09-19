#!/usr/bin/env bash
# Build Swift Prowser search-model zips and upload to your web host.
#
# There is NO public zip CDN to curl. This script:
#   1) Uses Python to download upstream weights (torchvision ResNet, HF CLIP)
#      and export Core ML .mlpackage bundles into swift/ModelArtifacts/*.zip
#   2) Copies image_recognition_models.json for the app to fetch from your HTTPS folder
#   3) rsyncs artifacts to REMOTE (edit pi@rpi:/models/ below)
#
# Prereqs: Python 3.12 or 3.13 venv (NOT venv_image_browser on Python 3.14).
#   ./swift/Scripts/setup_model_export_venv.sh
#
# Usage (from anywhere):
#   ./swift/Scripts/publish_search_models.sh
#   ./swift/Scripts/publish_search_models.sh --only clip_b32
#   ./swift/Scripts/publish_search_models.sh --build-only
#   ./swift/Scripts/publish_search_models.sh --upload-only

set -euo pipefail

# --- edit these ---
REMOTE="pi@rpi:/models/"
# Web path on the Pi should match app default base URL, e.g.:
#   https://waltzremote.com/swift-prowser/search-models/v1/clip_vit_b32_text.zip
# Map REMOTE to whatever nginx/httpd serves as that v1 folder.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV="${VENV:-$REPO_ROOT/venv_model_export}"
ARTIFACTS="$REPO_ROOT/swift/ModelArtifacts"
BUILD_SCRIPT="$REPO_ROOT/swift/Scripts/build_image_recognition_models.py"
BUNDLED_MANIFEST="$REPO_ROOT/swift/Prowser/Resources/image_recognition_models.json"
PYTHON="${PYTHON:-}"

BUILD_ONLY=false
UPLOAD_ONLY=false
ONLY="all"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Options:"
  echo "  --only resnet18|resnet50|resnet101|clip_b32|clip_l14|all   (default: all)"
  echo "  --build-only   Export zips locally, do not rsync"
  echo "  --upload-only  Rsync existing ModelArtifacts only"
  echo "  -h, --help"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=true; shift ;;
    --upload-only) UPLOAD_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

activate_venv() {
  if [[ -n "$PYTHON" && -x "$PYTHON" ]]; then
    return 0
  fi
  if [[ -f "$VENV/bin/activate" ]]; then
    # shellcheck disable=SC1090
    source "$VENV/bin/activate"
    PYTHON="$(command -v python)"
    return 0
  fi
  PYTHON="$(command -v python3 || command -v python)"
  if [[ -z "$PYTHON" ]]; then
    echo "No python found. Set VENV or PYTHON." >&2
    exit 1
  fi
}

check_python_deps() {
  if [[ ! -f "$VENV/bin/activate" ]]; then
    echo "Model export venv not found: $VENV" >&2
    echo "Run: ./swift/Scripts/setup_model_export_venv.sh" >&2
    exit 1
  fi
  "$PYTHON" - <<'PY' || {
import sys
missing = []
for mod in ("certifi", "torch", "torchvision", "transformers", "coremltools"):
    try:
        __import__(mod)
    except ImportError:
        missing.append(mod)
if missing:
    print("Missing Python packages:", ", ".join(missing), file=sys.stderr)
    print("Run: ./swift/Scripts/setup_model_export_venv.sh", file=sys.stderr)
    sys.exit(1)
if sys.version_info >= (3, 14):
    print(
        "Python 3.14 cannot export Core ML models (coremltools BlobWriter fails).",
        file=sys.stderr,
    )
    print("Use venv_model_export from setup_model_export_venv.sh (Python 3.12/3.13).", file=sys.stderr)
    sys.exit(1)
import os
import tempfile
import torch
import coremltools as ct

class _Probe(torch.nn.Module):
    def forward(self, x):
        return x

try:
    m = _Probe().eval()
    ex = torch.rand(1, 3, 4, 4)
    tr = torch.jit.trace(m, ex)
    ml = ct.convert(
        tr,
        inputs=[ct.TensorType(name="input", shape=ex.shape)],
        minimum_deployment_target=ct.target.macOS13,
    )
    p = os.path.join(tempfile.mkdtemp(), "probe.mlpackage")
    ml.save(p)
except Exception as exc:
    print("coremltools cannot save models:", exc, file=sys.stderr)
    print("Re-run: ./swift/Scripts/setup_model_export_venv.sh", file=sys.stderr)
    sys.exit(1)
PY
    exit 1
  }
}

build_artifacts() {
  mkdir -p "$ARTIFACTS"
  echo "==> Building Core ML zips (this downloads HF/torchvision weights on first run)..."
  export SSL_CERT_FILE="$("$PYTHON" -c 'import certifi; print(certifi.where())')"
  "$PYTHON" "$BUILD_SCRIPT" --out "$ARTIFACTS" --only "$ONLY" --skip-existing

  if [[ ! -f "$BUNDLED_MANIFEST" ]]; then
    echo "Bundled manifest not found: $BUNDLED_MANIFEST" >&2
    exit 1
  fi
  cp "$BUNDLED_MANIFEST" "$ARTIFACTS/image_recognition_models.json"

  SNIPPET="$ARTIFACTS/manifest_sha256_snippet.json"
  if [[ -f "$SNIPPET" ]]; then
    echo "==> Merging zip SHA256 into image_recognition_models.json (first artifact per model)..."
    "$PYTHON" - <<PY
import json
from pathlib import Path
artifacts = Path("$ARTIFACTS")
manifest_path = artifacts / "image_recognition_models.json"
snippet_path = artifacts / "manifest_sha256_snippet.json"
manifest = json.loads(manifest_path.read_text())
snippets = {row["id"]: row.get("zipSha256", "") for row in json.loads(snippet_path.read_text())}
id_to_zip = {
    "resnet18_feature": "resnet18_feature.zip",
    "resnet50_feature": "resnet50_feature.zip",
    "resnet101_feature": "resnet101_feature.zip",
    "clip_vit_b32_image": "clip_vit_b32_image.zip",
    "clip_vit_b32_text": "clip_vit_b32_text.zip",
    "clip_vit_l14_image": "clip_vit_l14_image.zip",
    "clip_vit_l14_text": "clip_vit_l14_text.zip",
}
for model in manifest.get("models", []):
    mid = model.get("id")
    if mid not in snippets or not snippets[mid]:
        continue
    digest = snippets[mid]
    for art in model.get("artifacts", []):
        art["sha256"] = digest
        break
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
print("Updated", manifest_path)
PY
  fi

  echo "==> Local artifacts:"
  ls -la "$ARTIFACTS"/*.zip 2>/dev/null || true
  ls -la "$ARTIFACTS/image_recognition_models.json"
}

upload_artifacts() {
  echo "==> Uploading to $REMOTE"
  if [[ "$REMOTE" == *"pi@rpi"* ]]; then
    echo "    (edit REMOTE at top of this script if needed)"
  fi
  rsync -av --progress \
    "$ARTIFACTS"/*.zip \
    "$ARTIFACTS/image_recognition_models.json" \
    "$REMOTE"
  echo "==> Done. Ensure HTTPS serves these files at your search-models/v1 URL."
}

if [[ "$UPLOAD_ONLY" == true ]]; then
  upload_artifacts
  exit 0
fi

activate_venv
check_python_deps
build_artifacts

if [[ "$BUILD_ONLY" == true ]]; then
  echo "Build-only; skipped upload."
  exit 0
fi

upload_artifacts
