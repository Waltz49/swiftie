#!/usr/bin/env python3
"""Thin NDJSON worker: LoRA import, Check LoRAs, find_origin (inference-side ops only)."""

from __future__ import annotations

from typing import Any, Dict

from workers.ipc_json import emit_message, parse_command_line, read_line

# Reuse battle-tested handlers from the legacy bridge (catalog CRUD is Swift-native).
from imagegen_plugins.lora_bridge import (  # noqa: PLC2701
    _handle_cancel_import,
    _handle_check_loras_cancel,
    _handle_check_loras_clear_probe_history,
    _handle_check_loras_prepare,
    _handle_check_loras_prescan,
    _handle_check_loras_run,
    _handle_check_loras_save_options,
    _handle_find_choices,
    _handle_find_origin,
    _handle_import_lora,
    _handle_install,
    _handle_lora_removal_info,
)

def _handle_migrate_catalog(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.lora_catalog_store import load_lora_catalog_file, save_lora_catalog_file

    lc = load_lora_catalog_file()
    save_lora_catalog_file(lc)
    return {"ok": True}


_OPS_HANDLERS = {
    "migrate_catalog": _handle_migrate_catalog,
    "import_lora": _handle_import_lora,
    "cancel_import": _handle_cancel_import,
    "find_origin": _handle_find_origin,
    "install": _handle_install,
    "find_choices": _handle_find_choices,
    "lora_removal_info": _handle_lora_removal_info,
    "check_loras_prescan": _handle_check_loras_prescan,
    "check_loras_save_options": _handle_check_loras_save_options,
    "check_loras_prepare": _handle_check_loras_prepare,
    "check_loras_run": _handle_check_loras_run,
    "check_loras_cancel": _handle_check_loras_cancel,
    "check_loras_clear_probe_history": _handle_check_loras_clear_probe_history,
}


def _handle_command(cmd: Dict[str, Any]) -> Any:
    command = str(cmd.get("command") or "").strip()
    if command == "shutdown":
        return "shutdown"
    handler = _OPS_HANDLERS.get(command)
    if handler is None:
        raise ValueError(f"Unknown ops command: {command}")
    return handler(cmd)


def main() -> None:
    emit_message({"type": "ready"})
    while True:
        line = read_line()
        if line is None:
            break
        line = line.strip()
        if not line:
            continue
        job_id = ""
        try:
            cmd = parse_command_line(line)
            job_id = str(cmd.get("job_id") or "")
            result = _handle_command(cmd)
            if result == "shutdown":
                break
            if isinstance(result, dict):
                emit_message(result)
        except Exception as exc:
            emit_message({"type": "error", "job_id": job_id, "message": str(exc)})


if __name__ == "__main__":
    main()
