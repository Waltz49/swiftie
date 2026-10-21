#!/usr/bin/env bash
# Core ML model export requires Python 3.12 or 3.13 (NOT 3.14 — coremltools native libs fail).
#
# Usage (repo root):
#   ./swift/Scripts/setup_model_export_venv.sh
#
# Then:
#   ./swift/Scripts/publish_search_models.sh

set -euo pipefail

usage() {
  cat <<EOF
$(basename "$0") — create venv_model_export for Core ML search-model export.

Uses Python 3.12 or 3.13 (coremltools does not support 3.14). Installs torch,
transformers, huggingface_hub, and coremltools into repo-root venv_model_export/.

Usage: $(basename "$0")

Environment:
  MODEL_EXPORT_PYTHON   Python binary to use (default: first python3.12 or python3.13 on PATH)

Options:
  -h, --help            Show this help

Then run: ./swift/Scripts/publish_search_models.sh
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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV_DIR="$REPO_ROOT/venv_model_export"

pick_python() {
  if [[ -n "${MODEL_EXPORT_PYTHON:-}" ]]; then
    echo "$MODEL_EXPORT_PYTHON"
    return 0
  fi
  for cmd in python3.12 python3.13; do
    if command -v "$cmd" &>/dev/null; then
      echo "$(command -v "$cmd")"
      return 0
    fi
  done
  echo "Need python3.12 or python3.13 on PATH (or set MODEL_EXPORT_PYTHON)." >&2
  echo "Example: brew install python@3.12" >&2
  exit 1
}

PY="$(pick_python)"
ver="$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$ver" == "3.14" ]]; then
  echo "Refusing Python 3.14 for coremltools export. Use 3.12 or 3.13." >&2
  exit 1
fi

echo "Using $PY ($ver)"
echo "Creating $VENV_DIR ..."
"$PY" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --upgrade pip --quiet
pip install certifi huggingface_hub torch torchvision transformers 'coremltools>=8.0,<9' --quiet

# python.org macOS builds ship without system roots linked into ssl
PY_BIN="$(command -v python)"
PY_ROOT="$(cd "$(dirname "$PY_BIN")/.." && pwd)"
if [[ -f "$PY_ROOT/Install Certificates.command" ]]; then
  echo "Installing TLS roots for Python.org framework (one-time) ..."
  bash "$PY_ROOT/Install Certificates.command" || true
fi
export SSL_CERT_FILE="$(python -c 'import certifi; print(certifi.where())')"
echo "SSL_CERT_FILE=$SSL_CERT_FILE"

echo "Verifying coremltools can write .mlpackage ..."
python - <<'PY'
import os
import tempfile
import torch
import coremltools as ct

class Identity(torch.nn.Module):
    def forward(self, x):
        return x

m = Identity().eval()
ex = torch.rand(1, 3, 224, 224)
traced = torch.jit.trace(m, ex)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=ex.shape)],
    minimum_deployment_target=ct.target.macOS13,
)
path = os.path.join(tempfile.mkdtemp(), "probe.mlpackage")
mlmodel.save(path)
print("coremltools OK:", ct.__version__)
PY

echo ""
echo "Done. Run: ./swift/Scripts/publish_search_models.sh"
