#!/usr/bin/env python3
"""Freeze job values at submit (LoRA paths, etc.) for Swift image generation.

Reads JSON ``{"plugin_id": "...", "values": {...}}`` from stdin; prints snapshot JSON on stdout.
Invoked as ``python -m imagegen_plugins.swift_job_values_snapshot_cli``.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    from workers.ipc_json import configure_profile_from_env

    configure_profile_from_env()
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
