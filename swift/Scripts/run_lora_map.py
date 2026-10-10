#!/usr/bin/env python3
"""JSON LoRA map for Swift Tools → Debug → Map LoRAs.

Row rules match ``imagegen_plugins.lora_map_dialog._lora_map_rows``.
This script does not import that module: the image-gen venv has no PySide6.
"""

from __future__ import annotations

import json
import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_SWIFT_ROOT = os.path.dirname(_SCRIPT_DIR)
_BUNDLE_ROOT = os.environ.get("PROWSER_IMAGEGEN_PYTHON_ROOT", "").strip()
if not _BUNDLE_ROOT:
    _dev_bundle = os.path.join(_SWIFT_ROOT, "ImageGenPython")
    if os.path.isdir(os.path.join(_dev_bundle, "imagegen_plugins")):
        _BUNDLE_ROOT = _dev_bundle
if _BUNDLE_ROOT and _BUNDLE_ROOT not in sys.path:
    sys.path.insert(0, _BUNDLE_ROOT)


def lora_map_rows():
    """Installed LoRAs and the models that accept them, sorted by display name."""
    from config import get_config
    from imagegen_plugins.hf_model_ids import LORA_PROBE_MODEL_ORDER, lora_model_display_name
    from imagegen_plugins.lora_catalog import (
        catalog_entries_sorted,
        local_lora_weights_path,
        lora_model_is_cross_family,
        lora_probe_passed_for_model,
    )
    from imagegen_plugins.lora_catalog_settings import lora_catalog_from_settings

    settings = get_config().load_settings()
    lc = lora_catalog_from_settings(settings)
    raw_ms = lc.get("model_support")
    model_support = raw_ms if isinstance(raw_ms, dict) else {}
    raw_cf = lc.get("cross_family_models")
    cross_family = raw_cf if isinstance(raw_cf, dict) else {}

    rows = []
    for entry in catalog_entries_sorted(settings):
        if local_lora_weights_path(entry.lora_id, settings, entry=entry) is None:
            continue
        label = (entry.display_name.strip() if entry.display_name else "") or entry.lora_id
        models = []
        for mk in LORA_PROBE_MODEL_ORDER:
            if not lora_probe_passed_for_model(
                entry.lora_id,
                mk,
                entry=entry,
                model_support=model_support,
            ):
                continue
            model_label = lora_model_display_name(mk)
            is_cross = lora_model_is_cross_family(
                entry.lora_id,
                mk,
                settings=settings,
                entry=entry,
                cross_family=cross_family,
            )
            if is_cross:
                model_label = f"{model_label} *"
            models.append((model_label, is_cross))
        rows.append((entry.lora_id, label, models))
    rows.sort(key=lambda row: row[1].lower())
    return rows


def main() -> int:
    out = []
    for lora_id, lora_label, models in lora_map_rows():
        out.append(
            {
                "lora_id": lora_id,
                "lora_label": lora_label,
                "models": [
                    {"label": label, "cross_family": bool(cross)}
                    for label, cross in models
                ],
            }
        )
    print(json.dumps(out), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
