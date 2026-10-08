#!/usr/bin/env python3
"""JSON LoRA map for Swift Tools → Debug → Map LoRAs."""

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


def main() -> int:
    from imagegen_plugins.lora_map_dialog import _lora_map_rows

    rows = _lora_map_rows()
    out = []
    for lora_label, models in rows:
        out.append(
            {
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
