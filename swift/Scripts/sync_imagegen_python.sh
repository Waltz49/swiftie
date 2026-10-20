#!/usr/bin/env bash
# Copy image-generation Python from the monorepo into swift/ImageGenPython/.
# Does not modify files under the repo root (read-only source).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_PKG="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_PKG/.." && pwd)"
DEST="$SWIFT_PKG/ImageGenPython"

mkdir -p "$DEST"

RSYNC=(rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store')

copy_dir() {
  local name="$1"
  mkdir -p "$DEST"
  "${RSYNC[@]}" "$REPO_ROOT/$name/" "$DEST/$name/"
}

copy_file() {
  local rel="$1"
  mkdir -p "$(dirname "$DEST/$rel")"
  cp -f "$REPO_ROOT/$rel" "$DEST/$rel"
}

echo "Syncing imagegen bundle: $REPO_ROOT -> $DEST"

copy_dir imagegen_plugins

# Swift app does not bundle chat UI; set SYNC_IMAGEGEN_MINIMAL=1 to omit chat_plugins/theme.
if [[ "${SYNC_IMAGEGEN_MINIMAL:-0}" != "1" ]]; then
  copy_dir chat_plugins
  copy_dir theme
else
  echo "SYNC_IMAGEGEN_MINIMAL=1: skipping chat_plugins and theme"
fi

copy_dir exif

for f in \
  config.py \
  exit_scripts.py \
  prowser_temp_files.py \
  debug_log.py \
  print_call_decorator.py \
  pyinstaller_frozen_support.py \
  pil_image_io.py \
  ; do
  if [[ -f "$REPO_ROOT/$f" ]]; then
    copy_file "$f"
  fi
done

mkdir -p "$DEST/workers"
for f in ipc_json.py model_tasks_process_registry.py; do
  copy_file "workers/$f"
done

# Bundle-local workers (not copied from monorepo); preserved across sync:
# model_tasks_worker.py, imagegen_generate_worker.py
# ``utils.py`` at bundle root is headless-only (see swift/ImageGenPython/utils.py); not copied from monorepo.
if [[ ! -f "$DEST/workers/model_tasks_worker.py" ]]; then
  cat > "$DEST/workers/model_tasks_worker.py" <<'PY'
"""Minimal worker helpers for vendored pipeline scripts (Swift ImageGenPython bundle)."""
from __future__ import annotations

import time
from typing import Any


def generation_cancel_requested() -> bool:
    return False


def emit_worker_message(msg: dict[str, Any]) -> None:
    """Stream progress to stderr for ``ImageGenPipelineWorkerRunner``."""
    if not msg or msg.get("type") != "progress":
        return
    import json
    import sys
    print(json.dumps(msg, ensure_ascii=False), file=sys.stderr, flush=True)


def perf_log_kv(event: str, **fields: Any) -> None:
    pass


def flux_prompt_system_message() -> str:
    return ""


class PerfTimer:
    """Context manager: logs elapsed on exit when perf debug is on (no-op in Swift bundle)."""

    def __init__(self, event: str, **fields: Any) -> None:
        self._event = event
        self._fields = dict(fields)
        self._t0: float | None = None

    def __enter__(self) -> PerfTimer:
        self._t0 = time.perf_counter()
        perf_log_kv(f"{self._event}_start", **self._fields)
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self._t0 is None:
            return
        elapsed = time.perf_counter() - self._t0
        status = "error" if exc is not None else "ok"
        perf_log_kv(
            self._event,
            elapsed=elapsed,
            status=status,
            **self._fields,
        )
PY
fi

if [[ ! -f "$DEST/workers/__init__.py" ]]; then
  echo '"""Workers package (bundle subset)."""' > "$DEST/workers/__init__.py"
fi

# Swift headless registry runs in the imagegen venv (no PySide6). Keep availability checks
# and plugin listing from importing Qt-only pixelmator helpers at module load.
apply_bundle_patches() {
  local fill_py="$DEST/imagegen_plugins/pipelines/mflux_fill_expand.py"
  if [[ -f "$fill_py" ]] && grep -q '^from imagegen_plugins.pixelmator_export import pixelmator_mask_to_mflux' "$fill_py"; then
    python3 - "$fill_py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = "from imagegen_plugins.pixelmator_export import pixelmator_mask_to_mflux\n"
if old not in text:
    sys.exit(0)
text = text.replace(old, "", 1)
needle = "        mask = pixelmator_mask_to_mflux(mask_src)\n"
if needle in text and "from imagegen_plugins.pixelmator_export import pixelmator_mask_to_mflux" not in text:
    text = text.replace(
        needle,
        "        from imagegen_plugins.pixelmator_export import pixelmator_mask_to_mflux\n\n        mask = pixelmator_mask_to_mflux(mask_src)\n",
        1,
    )
path.write_text(text)
PY
  fi

  local check_py="$DEST/imagegen_plugins/pipeline_check_registry.py"
  if [[ -f "$check_py" ]]; then
    python3 - "$check_py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """def _check_mflux_fill_available() -> bool:
    from imagegen_plugins.pipelines.mflux_fill_expand import mflux_is_installed

    return mflux_is_installed()
"""
new = """def _check_mflux_fill_available() -> bool:
    from pyinstaller_frozen_support import mflux_is_installed

    return mflux_is_installed()
"""
if old in text:
    path.write_text(text.replace(old, new, 1))
PY
  fi

  local avail_py="$DEST/imagegen_plugins/image_gen_model_availability.py"
  if [[ -f "$avail_py" ]] && grep -q '^from PySide6.QtWidgets import QMessageBox' "$avail_py"; then
    python3 - "$avail_py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """from PySide6.QtWidgets import QMessageBox

from utils import show_styled_ok_cancel

from imagegen_plugins.model_download_progress import ModelDownloadCancelled

"""
if old not in text:
    sys.exit(0)
text = text.replace(old, "", 1)
needle = "    if is_local:\n        return True\n    name = model_display_name"
if needle in text and "show_styled_ok_cancel" not in text.split("confirm_model_download_if_needed", 1)[1].split("def ", 1)[0]:
    text = text.replace(
        needle,
        "    if is_local:\n        return True\n    from PySide6.QtWidgets import QMessageBox\n\n    from utils import show_styled_ok_cancel\n\n    name = model_display_name",
        1,
    )
path.write_text(text)
PY
  fi

  local queue_py="$DEST/imagegen_plugins/model_task_queue.py"
  if [[ -f "$queue_py" ]] && grep -q '^from imagegen_plugins.pixelmator_export import missing_infill_export_paths' "$queue_py"; then
    python3 - "$queue_py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = "from imagegen_plugins.pixelmator_export import missing_infill_export_paths\n\n\n"
if old in text:
    text = text.replace(old, "\n\n", 1)
needle = "    elif function == FUNCTION_INFILL:\n        missing.extend(missing_infill_export_paths(values))"
if needle in text and "from imagegen_plugins.pixelmator_export import missing_infill_export_paths" not in text:
    text = text.replace(
        needle,
        "    elif function == FUNCTION_INFILL:\n        from imagegen_plugins.pixelmator_export import missing_infill_export_paths\n\n        missing.extend(missing_infill_export_paths(values))",
        1,
    )
path.write_text(text)
PY
  fi

  local bridge_py="$DEST/imagegen_plugins/registry_bridge.py"
  if [[ -f "$bridge_py" ]] && grep -q 'refresh_queued_job_status(job)$' "$bridge_py"; then
    python3 - "$bridge_py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = "        refresh_queued_job_status(job)\n        view = build_queue_job_status_view("
new = "        # Headless Swift registry: prefix/postfix and exit scripts are applied in Swift.\n        refresh_queued_job_status(job, skip_image_exit=True)\n        view = build_queue_job_status_view("
if old in text:
    path.write_text(text.replace(old, new, 1))
PY
  fi
}
apply_bundle_patches

# Swift app uses SwiftImageGenRegistry; pipeline workers only in the shipped bundle.
rm -f "$DEST/registry_oneshot.py" "$DEST/imagegen_plugins/registry_bridge.py"

echo "Done. Bundle at $DEST"
