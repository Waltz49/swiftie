#!/usr/bin/env python3
"""NDJSON worker for Swift Check LoRAs (prescan, prepare, run)."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict
from typing import Any, Dict, List, Optional

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_SWIFT_ROOT = os.path.dirname(_SCRIPT_DIR)
_BUNDLE_ROOT = os.environ.get("PROWSER_IMAGEGEN_PYTHON_ROOT", "").strip()
if not _BUNDLE_ROOT:
    _dev_bundle = os.path.join(_SWIFT_ROOT, "ImageGenPython")
    if os.path.isdir(os.path.join(_dev_bundle, "imagegen_plugins")):
        _BUNDLE_ROOT = _dev_bundle
if _BUNDLE_ROOT and _BUNDLE_ROOT not in sys.path:
    sys.path.insert(0, _BUNDLE_ROOT)

from workers.ipc_json import emit_message, parse_command_line, read_line

_prepared = None
_cancel_flag = [False]


def _options_from_dict(raw: Dict[str, Any]):
    from imagegen_plugins.lora_compatibility_checker import (
        CheckLorasOptions,
        LORA_SCOPE_ALL,
        LORA_SCOPE_SELECTED,
        MODEL_SCOPE_ALL,
        MODEL_SCOPE_SELECTED,
        REGISTRATION_IGNORE_PREVIOUS,
        REGISTRATION_ONLY_REGISTERED,
        REGISTRATION_SKIP_REGISTERED,
        installed_probeable_models,
    )

    installed = set(installed_probeable_models())
    scope = str(raw.get("model_scope") or MODEL_SCOPE_ALL)
    selected = [str(m) for m in (raw.get("selected_model_keys") or []) if str(m) in installed]
    mode = str(raw.get("registration_mode") or REGISTRATION_IGNORE_PREVIOUS)
    lora_scope = str(raw.get("lora_scope") or LORA_SCOPE_ALL)
    selected_lora = [str(k) for k in (raw.get("selected_lora_keys") or []) if str(k)]
    return CheckLorasOptions(
        model_scope=scope,
        selected_model_keys=selected,
        lora_scope=lora_scope,
        selected_lora_keys=selected_lora,
        registration_mode=mode,
        probe_prompt=str(raw.get("probe_prompt") or "test").strip() or "test",
        skip_unchanged=bool(raw.get("skip_unchanged", True)),
        check_cross_families=bool(raw.get("check_cross_families", True)),
    )


def _choice_to_dict(choice) -> Dict[str, Any]:
    return {
        "key": choice.key,
        "label": choice.label,
        "display_name": choice.display_name or choice.label,
        "weights_path": choice.weights_path or "",
        "from_downloads": bool(choice.from_downloads),
    }


def _handle_prescan(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.lora_compatibility_checker import discover_check_lora_choices

    settings = get_config().load_settings()
    choices = discover_check_lora_choices(settings, dedupe_downloads=False)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "prescan",
        "choices": [_choice_to_dict(c) for c in choices],
        "installed_models": __import__(
            "imagegen_plugins.lora_compatibility_checker",
            fromlist=["installed_probeable_models"],
        ).installed_probeable_models(),
    }


def _handle_prepare(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _prepared
    from config import get_config
    from imagegen_plugins.lora_compatibility_checker import (
        PreparedLoraProbePlan,
        plan_disk_lora_probes,
    )

    options = _options_from_dict(cmd.get("options") or {})
    from imagegen_plugins.lora_compatibility_checker import persist_check_loras_options

    persist_check_loras_options(options)
    cfg = get_config().load_settings()
    candidates, plan, plan_stats = plan_disk_lora_probes(cfg, dedupe=True, options=options)
    _prepared = PreparedLoraProbePlan(candidates=candidates, plan=plan, stats=plan_stats)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "prepare",
        "success": True,
        "stats": asdict(plan_stats),
    }


def _handle_run(cmd: Dict[str, Any]) -> None:
    global _cancel_flag, _prepared
    from config import get_config
    from imagegen_plugins.lora_compatibility_checker import run_lora_compatibility_check

    job_id = str(cmd.get("job_id") or "")
    _cancel_flag[0] = False
    options = _options_from_dict(cmd.get("options") or {})
    settings = get_config().load_settings()

    def progress_callback(
        probe_index: int,
        probe_total: int,
        phase: str,
        lora_id: str,
        model_key: str,
        stats,
    ) -> None:
        emit_message(
            {
                "type": "progress",
                "job_id": job_id,
                "command": "run",
                "probe_index": probe_index,
                "probe_total": probe_total,
                "phase": phase,
                "lora_id": lora_id,
                "model_key": model_key,
                "stats": asdict(stats),
            }
        )

    def cancel_check() -> bool:
        return bool(_cancel_flag[0])

    result = run_lora_compatibility_check(
        settings,
        progress_callback=progress_callback,
        cancel_check=cancel_check,
        options=options,
        prepared=_prepared,
    )
    changes = [
        {
            "kind": c.kind,
            "lora_id": c.lora_id,
            "lora_label": c.lora_label,
            "model_key": c.model_key,
            "model_label": c.model_label,
        }
        for c in result.changes
    ]
    emit_message(
        {
            "type": "result",
            "job_id": job_id,
            "command": "run",
            "success": True,
            "cancelled": result.cancelled,
            "passed": result.stats.passed_probe_count,
            "failed": result.stats.failed_probe_count,
            "skipped": result.stats.skipped_loras,
            "changes": changes,
            "stats": asdict(result.stats),
            "elapsed_seconds": result.elapsed_seconds,
        }
    )


def _handle_cancel(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _cancel_flag
    _cancel_flag[0] = True
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "cancel",
        "success": True,
    }


def _handle_command(cmd: Dict[str, Any]) -> Any:
    command = str(cmd.get("command") or "").strip()
    if command == "shutdown":
        return "shutdown"
    if command == "prescan":
        return _handle_prescan(cmd)
    if command == "prepare":
        return _handle_prepare(cmd)
    if command == "run":
        _handle_run(cmd)
        return None
    if command == "cancel":
        return _handle_cancel(cmd)
    raise ValueError(f"Unknown command: {command}")


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
