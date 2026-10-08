#!/usr/bin/env python3
"""Apply LoRA resolution from ``build_worker_payload`` for Swift worker payloads.

Reads JSON ``{"plugin_id": "...", "values": {...}, "output_path": "...", "apply_image_exit": false}``
from stdin; prints enriched values JSON on stdout.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    import traceback

    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.job_values_snapshot import enrich_values_with_worker_lora_fields

    try:
        raw = sys.stdin.read()
        if not raw.strip():
            print(json.dumps({"error": "empty input"}), flush=True)
            return 1
        doc = json.loads(raw)
        plugin_id = str(doc.get("plugin_id") or "").strip()
        values = doc.get("values")
        output_path = str(doc.get("output_path") or "/tmp/.prowser_lora_enrich.png")
        apply_image_exit = bool(doc.get("apply_image_exit"))
        if not plugin_id or not isinstance(values, dict):
            print(json.dumps({"error": "plugin_id and values object required"}), flush=True)
            return 1
        plugin = plugin_by_id(plugin_id)
        if plugin is None:
            print(json.dumps({"error": f"unknown plugin {plugin_id}"}), flush=True)
            return 1
        out = enrich_values_with_worker_lora_fields(
            plugin,
            values,
            output_path=output_path,
            apply_image_exit=apply_image_exit,
        )
        print(json.dumps(out), flush=True)
        return 0
    except Exception as exc:
        print(
            json.dumps(
                {
                    "error": str(exc),
                    "traceback": traceback.format_exc(),
                }
            ),
            flush=True,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
