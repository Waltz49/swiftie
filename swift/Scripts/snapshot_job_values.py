#!/usr/bin/env python3
"""Freeze job values at submit (LoRA paths, etc.) for Swift image generation."""

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
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.job_values_snapshot import snapshot_job_values_at_submit

    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"error": "empty input"}), flush=True)
        return 1
    doc = json.loads(raw)
    plugin_id = str(doc.get("plugin_id") or "").strip()
    values = doc.get("values")
    if not plugin_id or not isinstance(values, dict):
        print(json.dumps({"error": "plugin_id and values object required"}), flush=True)
        return 1
    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        print(json.dumps({"error": f"unknown plugin {plugin_id}"}), flush=True)
        return 1
    out = snapshot_job_values_at_submit(plugin, values)
    print(json.dumps(out), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
