#!/usr/bin/env python3
"""NDJSON bridge for Swift UI: LoRA catalog, settings, import, and run-dialog choices."""

from __future__ import annotations

import os
import sys
import threading
from typing import Any, Dict, List, Optional

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, parse_command_line, read_line

_IMPORT_PROGRESS_PROBE_STEPS = 6
_IMPORT_PROGRESS_SKIP_PROBE_STEPS = 3
_DEFAULT_REFERENCE_PROMPT = "test image of person standing"

_active_import_thread: Optional[threading.Thread] = None
_import_cancel_flag: List[bool] = [False]

_check_loras_prepared = None
_check_loras_cancel_flag: List[bool] = [False]
_check_loras_running = False
_check_loras_preparing = False
_active_check_loras_thread: Optional[threading.Thread] = None
_active_check_loras_prepare_thread: Optional[threading.Thread] = None


def _entry_to_dict(entry, *, model_key: str = "") -> Dict[str, Any]:
    from imagegen_plugins.lora_catalog import (
        has_recovery_source,
        is_lora_installed,
        lora_base_display_name,
        lora_choice_label,
        lora_lifecycle_state,
        lora_model_is_cross_family,
        lora_status_label,
    )

    settings = None
    try:
        from config import get_config

        settings = get_config().load_settings()
    except Exception:
        settings = {}
    lifecycle = lora_lifecycle_state(entry.lora_id, model_key, settings)
    base = lora_base_display_name(entry, model_key=model_key)
    if model_key and lora_model_is_cross_family(entry.lora_id, model_key):
        base = f"{base} *"
    trigger = (entry.trigger_word or "").strip()
    label = base
    if trigger:
        max_len = 30
        if len(trigger) > max_len:
            trigger = f"{trigger[: max_len - 3]}..."
        label = f"{base} - Trigger: {trigger}"
    return {
        "lora_id": entry.lora_id,
        "display_name": entry.display_name,
        "label": label,
        "choice_label": lora_choice_label(entry, model_key=model_key),
        "host_id": entry.host_id,
        "scale": float(entry.scale),
        "best_guess": float(entry.best_guess),
        "trigger_word": entry.trigger_word or "",
        "comment": entry.comment or "",
        "reference_prompt": entry.reference_prompt or "",
        "repo_id": entry.repo_id or "",
        "filename": entry.filename or "",
        "local_path": entry.local_path or "",
        "source_path": entry.source_path or "",
        "installed": bool(is_lora_installed(entry.lora_id)),
        "lifecycle": lifecycle,
        "status_label": lora_status_label(entry.lora_id, model_key, settings),
        "has_recovery_source": bool(has_recovery_source(entry)),
        "registered": True,
    }


def _discovered_disk_entry_dict(path) -> Dict[str, Any]:
    from pathlib import Path

    from imagegen_plugins.lora_user_entries import display_name_from_path

    p = Path(path).expanduser()
    try:
        resolved = str(p.resolve())
    except OSError:
        resolved = str(p)
    name = display_name_from_path(p)
    return {
        "lora_id": f"path:{resolved}",
        "display_name": name,
        "label": name,
        "choice_label": name,
        "host_id": "",
        "scale": 1.0,
        "best_guess": 1.0,
        "trigger_word": "",
        "comment": "",
        "reference_prompt": "",
        "repo_id": "",
        "filename": p.name,
        "local_path": resolved,
        "source_path": resolved,
        "installed": True,
        "lifecycle": "discovered",
        "status_label": "on disk (not registered)",
        "has_recovery_source": False,
        "registered": False,
    }


def _handle_settings_models(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.lora_model_registry import (
        lora_model_available_in_label,
        lora_models_for_settings,
    )

    models = []
    for model in lora_models_for_settings():
        models.append(
            {
                "model_key": model.model_key,
                "display_name": model.display_name.rsplit("/", 1)[-1],
                "available_in_label": lora_model_available_in_label(model.model_key),
            }
        )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "settings_models",
        "models": models,
    }


def _overlay_drafts(settings: dict, draft_by_model: Optional[dict]) -> dict:
    if not isinstance(draft_by_model, dict):
        return settings
    from imagegen_plugins.lora_catalog_settings import lora_catalog_from_settings

    cfg = dict(settings)
    imagegen = dict(cfg.get("imagegen") or {})
    lc = dict(lora_catalog_from_settings(cfg))
    bm = dict(lc.get("by_model") or {})
    for mk, slice_ in draft_by_model.items():
        if isinstance(slice_, dict):
            bm[str(mk)] = {
                "enabled_ids": list(slice_.get("enabled_ids") or []),
                "deleted_ids": list(
                    slice_.get("deleted_ids") or slice_.get("hidden_ids") or []
                ),
            }
    lc["by_model"] = bm
    imagegen["lora_catalog"] = lc
    cfg["imagegen"] = imagegen
    return cfg


def _handle_settings_entries(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.lora_catalog import (
        catalog_entries_for_model,
        LORA_LIFECYCLE_UNINSTALLED,
        lora_lifecycle_state,
    )
    from imagegen_plugins.lora_catalog_settings import model_state

    model_key = str(cmd.get("model_key") or "").strip()
    hide_uninstalled = bool(cmd.get("hide_uninstalled"))
    draft_by_model = cmd.get("draft_by_model")
    settings = _overlay_drafts(get_config().load_settings(), draft_by_model)
    drafts = {}
    if isinstance(draft_by_model, dict):
        drafts = draft_by_model
    slice_ = model_state(settings, model_key) if model_key else {"enabled_ids": [], "deleted_ids": []}
    entries = []
    for entry in catalog_entries_for_model(settings, model_key, draft_by_model=drafts):
        lifecycle = lora_lifecycle_state(
            entry.lora_id, model_key, settings, draft_by_model=drafts
        )
        if hide_uninstalled and lifecycle == LORA_LIFECYCLE_UNINSTALLED:
            continue
        entries.append(_entry_to_dict(entry, model_key=model_key))

    from imagegen_plugins.lora_compatibility_checker import _path_is_registered
    from imagegen_plugins.lora_disk_discovery import discover_lora_weight_paths

    discovered_entries: List[Dict[str, Any]] = []
    seen_paths: set[str] = set()
    for weight_path in discover_lora_weight_paths(settings):
        if _path_is_registered(weight_path, settings):
            continue
        row = _discovered_disk_entry_dict(weight_path)
        key = row["local_path"]
        if key in seen_paths:
            continue
        seen_paths.add(key)
        discovered_entries.append(row)
    discovered_entries.sort(key=lambda r: (r.get("display_name") or "").lower())

    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "settings_entries",
        "model_key": model_key,
        "enabled_ids": list(slice_.get("enabled_ids") or []),
        "deleted_ids": list(slice_.get("deleted_ids") or slice_.get("hidden_ids") or []),
        "entries": entries,
        "discovered_entries": discovered_entries,
    }


def _handle_save_catalog_state(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.image_gen_persistence import save_lora_catalog_state

    by_model = cmd.get("by_model")
    if not isinstance(by_model, dict):
        raise ValueError("by_model must be an object")
    normalized = {
        str(mk): {
            "enabled_ids": list((sl or {}).get("enabled_ids") or []),
            "deleted_ids": list(
                (sl or {}).get("deleted_ids") or (sl or {}).get("hidden_ids") or []
            ),
        }
        for mk, sl in by_model.items()
        if isinstance(sl, dict)
    }
    save_lora_catalog_state(by_model=normalized)
    model_key = str(cmd.get("model_key") or "").strip()
    if model_key:
        get_config().update_settings({"imagegen_lora_model_key": model_key})
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "save_catalog_state",
        "success": True,
    }


def _handle_choices_for_plugin(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.lora_catalog import (
        get_lora_entry,
        lora_choices_for_plugin,
        lora_run_dialog_empty_hint,
        plugin_supports_lora,
    )
    from imagegen_plugins.lora_host_registry import HOST_SD15
    from imagegen_plugins.mflux_lora_presets import (
        LORA_UNSUPPORTED_LABEL,
        LORA_UNSUPPORTED_PRESET_ID,
        coerce_lora_preset_id,
    )

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    plugin = plugin_by_id(plugin_id) if plugin_id else None
    settings = get_config().load_settings()
    if not plugin_supports_lora(plugin):
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "choices_for_plugin",
            "unsupported": True,
            "unsupported_label": LORA_UNSUPPORTED_LABEL,
            "unsupported_id": LORA_UNSUPPORTED_PRESET_ID,
            "stack_mode": False,
            "popup_mode": False,
            "choices": [],
        }
    host_id = getattr(plugin, "lora_host_id", None) if plugin else None
    stack_mode = host_id is not None and host_id not in (HOST_SD15,)
    popup_mode = host_id is not None
    choices = lora_choices_for_plugin(plugin, settings) if plugin else ()
    choice_list = [{"label": str(label), "preset_id": str(pid)} for label, pid in choices]
    current_stack = cmd.get("current_stack")
    current_preset = coerce_lora_preset_id(cmd.get("current_preset_id", "none"))
    selected_ids: List[str] = []
    if isinstance(current_stack, list) and current_stack:
        for raw in current_stack:
            pid = coerce_lora_preset_id(raw)
            if pid and pid != "none":
                selected_ids.append(pid)
    elif current_preset != "none":
        selected_ids = [current_preset]
    scale_overrides = cmd.get("scale_overrides")
    if not isinstance(scale_overrides, dict):
        scale_overrides = {}
    for pid in list(selected_ids):
        if pid not in {c["preset_id"] for c in choice_list}:
            entry = get_lora_entry(pid)
            if entry is not None:
                choice_list.append(
                    {
                        "label": entry.display_name,
                        "preset_id": pid,
                    }
                )
    scales_by_id: Dict[str, float] = {}
    for pid in selected_ids:
        if pid in scale_overrides:
            try:
                scales_by_id[pid] = float(scale_overrides[pid])
                continue
            except (TypeError, ValueError):
                pass
        entry = get_lora_entry(pid)
        scales_by_id[pid] = float(entry.scale) if entry is not None else 1.0
    selectable = [c for c in choice_list if c.get("preset_id") != "none"]
    empty_hint = (
        lora_run_dialog_empty_hint(plugin, settings)
        if plugin is not None and not selectable
        else None
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "choices_for_plugin",
        "unsupported": False,
        "stack_mode": stack_mode,
        "popup_mode": popup_mode,
        "choices": choice_list,
        "selected_ids": selected_ids,
        "scales_by_id": scales_by_id,
        "empty_selection_hint": empty_hint,
    }


def _handle_selected_display_text(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.image_gen_naming import format_exif_lora_weight
    from imagegen_plugins.lora_catalog import get_lora_entry, lora_base_display_name
    from imagegen_plugins.lora_model_registry import lora_model_key_for_plugin
    from imagegen_plugins.mflux_lora_presets import coerce_lora_preset_id

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    plugin = plugin_by_id(plugin_id) if plugin_id else None
    model_key = lora_model_key_for_plugin(plugin) if plugin is not None else ""
    selected_ids = [
        coerce_lora_preset_id(x)
        for x in (cmd.get("selected_ids") or [])
        if coerce_lora_preset_id(x) not in ("", "none")
    ]
    scales = cmd.get("scales_by_id")
    if not isinstance(scales, dict):
        scales = {}
    parts: List[str] = []
    for pid in selected_ids:
        entry = get_lora_entry(pid)
        if entry is not None:
            name = lora_base_display_name(entry, model_key=model_key or "")
        else:
            name = str(pid)
        scale = float(scales.get(pid, 1.0))
        parts.append(f"{name} [{format_exif_lora_weight(scale)}]")
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "selected_display_text",
        "text": ", ".join(parts),
    }


def _handle_exif_label_from_values(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.mflux_lora_presets import lora_name_for_exif_from_values

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    if not isinstance(values, dict):
        values = {}
    plugin = plugin_by_id(plugin_id) if plugin_id else None
    pipeline_id = plugin.pipeline_id if plugin is not None else None
    label = lora_name_for_exif_from_values(values, pipeline_id=pipeline_id)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "exif_label_from_values",
        "text": label or "",
    }


def _handle_update_entry_scales(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import update_lora_entry_metadata
    from imagegen_plugins.lora_catalog import get_lora_entry

    scales = cmd.get("scales_by_id")
    if not isinstance(scales, dict):
        raise ValueError("scales_by_id must be an object")
    for lora_id, new_scale in scales.items():
        entry = get_lora_entry(str(lora_id))
        if entry is None:
            continue
        try:
            scale = float(new_scale)
        except (TypeError, ValueError):
            continue
        if abs(float(entry.scale) - scale) < 1e-6:
            continue
        try:
            update_lora_entry_metadata(
                entry.lora_id,
                display_name=entry.display_name,
                trigger_word=entry.trigger_word,
                scale=scale,
                comment=entry.comment,
            )
        except Exception:
            pass
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "update_entry_scales",
        "success": True,
    }


def _handle_install(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import install_lora_entry

    lora_id = str(cmd.get("lora_id") or "").strip()
    if not lora_id:
        raise ValueError("lora_id is required")
    install_lora_entry(lora_id)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "install",
        "success": True,
    }


def _handle_delete(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import (
        delete_lora_from_library,
        uninstall_lora_weights,
    )

    lora_id = str(cmd.get("lora_id") or "").strip()
    model_key = str(cmd.get("model_key") or "").strip()
    do_uninstall = bool(cmd.get("do_uninstall"))
    if not lora_id:
        raise ValueError("lora_id is required")
    if do_uninstall:
        uninstall_lora_weights(lora_id)
    else:
        delete_lora_from_library(lora_id, model_key=model_key)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "delete",
        "success": True,
    }


def _handle_save_user_preset(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import save_lora_user_preset

    save_lora_user_preset()
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "save_user_preset",
        "success": True,
    }


def _handle_apply_user_preset(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import apply_lora_user_preset

    enabled_count, _install_count = apply_lora_user_preset(install_missing=False)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "apply_user_preset",
        "enabled_count": enabled_count,
    }


def _handle_restore_recommendations(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import restore_app_lora_recommendations

    enabled_count, _install_count = restore_app_lora_recommendations(
        install_missing=False,
        overwrite_enabled=False,
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "restore_recommendations",
        "enabled_count": enabled_count,
    }


def _handle_find_choices(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.lora_compatibility_checker import discover_find_lora_choices

    choices = discover_find_lora_choices(get_config().load_settings())
    items = []
    for choice in sorted(
        choices or [],
        key=lambda c: ((c.display_name or c.label or "").lower()),
    ):
        items.append(
            {
                "key": choice.key,
                "display_name": choice.display_name or choice.label or choice.key,
                "weights_path": choice.weights_path or "",
                "trigger_word": choice.trigger_word or "",
                "comment": choice.comment or "",
                "repo_id": choice.repo_id or "",
                "filename": choice.filename or "",
                "source_path": choice.source_path or "",
                "scale": float(choice.scale) if choice.scale is not None else 1.0,
                "from_downloads": bool(choice.from_downloads),
            }
        )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "find_choices",
        "choices": items,
    }


def _handle_get_entry(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.lora_catalog import get_lora_entry

    lora_id = str(cmd.get("lora_id") or "").strip()
    model_key = str(cmd.get("model_key") or "").strip()
    entry = get_lora_entry(lora_id)
    if entry is None:
        raise ValueError(f"LoRA {lora_id!r} was not found.")
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "get_entry",
        "entry": _entry_to_dict(entry, model_key=model_key),
    }


def _handle_validate_source(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.lora_model_registry import host_id_for_lora_model
    from imagegen_plugins.lora_user_entries import (
        display_name_from_path,
        find_user_lora_for_source,
        validate_safetensors_source,
    )

    model_key = str(cmd.get("model_key") or "").strip()
    path = str(cmd.get("path") or "").strip()
    if not path:
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "validate_source",
            "valid": False,
        }
    host_id = host_id_for_lora_model(model_key)
    try:
        source = validate_safetensors_source(path)
        display_path = str(source)
        existing = find_user_lora_for_source(source, host_id=host_id) if host_id else None
        if existing is not None:
            return {
                "type": "result",
                "job_id": cmd.get("job_id", ""),
                "command": "validate_source",
                "valid": True,
                "display_path": display_path,
                "reuse_lora_id": existing.lora_id,
                "display_name": existing.display_name,
                "trigger_word": existing.trigger_word or "",
                "reference_prompt": existing.reference_prompt or "",
                "scale": float(existing.scale),
                "best_guess": float(existing.best_guess),
                "comment": existing.comment or "",
                "reusing": True,
            }
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "validate_source",
            "valid": True,
            "display_path": display_path,
            "display_name": display_name_from_path(source),
            "reusing": False,
        }
    except Exception as exc:
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "validate_source",
            "valid": False,
            "error": str(exc),
        }


def _handle_save_metadata(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import update_lora_entry_metadata

    lora_id = str(cmd.get("lora_id") or "").strip()
    if not lora_id:
        raise ValueError("lora_id is required")
    update_lora_entry_metadata(
        lora_id,
        display_name=str(cmd.get("display_name") or "").strip(),
        trigger_word=str(cmd.get("trigger_word") or "").strip() or None,
        best_guess=float(cmd.get("best_guess") or 1.0),
        comment=str(cmd.get("comment") or "").strip() or None,
        reference_prompt=str(cmd.get("reference_prompt") or "").strip(),
        repo_id=str(cmd.get("repo_id") or "").strip(),
        filename=str(cmd.get("filename") or "").strip(),
        source_path=str(cmd.get("source_path") or "").strip() or None,
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "save_metadata",
        "success": True,
    }


def _probe_fallback_prompt(reference_prompt: str) -> str:
    return (reference_prompt or "test").strip() or "test"


def _run_import_worker(cmd: Dict[str, Any], job_id: str) -> None:
    global _import_cancel_flag
    entry = None
    created_new = False
    try:
        from imagegen_plugins.hf_model_ids import lora_model_display_name
        from imagegen_plugins.image_gen_persistence import (
            enrich_lora_origin_metadata,
            register_user_lora,
            update_lora_entry_metadata,
        )
        from imagegen_plugins.lora_catalog import get_lora_entry, lora_model_support, lora_probe_prompt
        from imagegen_plugins.lora_compatibility_checker import probe_lora_on_model
        from imagegen_plugins.lora_model_registry import (
            host_id_for_lora_model,
            klein_lora_model_aliases,
            lora_probe_model_is_local,
        )
        from imagegen_plugins.lora_user_entries import (
            build_user_lora_entry,
            find_user_lora_for_source,
            remove_user_lora_files,
            validate_safetensors_source,
        )
        from imagegen_plugins.mflux_lora_presets import assert_lora_compatible_for_model

        def cancelled() -> bool:
            return bool(_import_cancel_flag[0])

        def emit_progress(activity: str, step: int, maximum: int) -> None:
            emit_message(
                {
                    "type": "progress",
                    "job_id": job_id,
                    "command": "import_lora",
                    "activity": activity,
                    "step": step,
                    "maximum": maximum,
                }
            )

        model_key = str(cmd.get("model_key") or "").strip()
        source_path = str(cmd.get("source_path") or "").strip()
        display_name = str(cmd.get("display_name") or "").strip()
        trigger_word = str(cmd.get("trigger_word") or "").strip()
        best_guess = float(cmd.get("best_guess") or 1.0)
        comment = str(cmd.get("comment") or "").strip()
        reference_prompt = str(cmd.get("reference_prompt") or "").strip()
        reuse_lora_id = str(cmd.get("reuse_lora_id") or "").strip() or None
        repo_id = str(cmd.get("repo_id") or "").strip()
        filename = str(cmd.get("filename") or "").strip()
        recovery_source_path = str(cmd.get("recovery_source_path") or "").strip()

        if cancelled():
            emit_message(
                {
                    "type": "result",
                    "job_id": job_id,
                    "command": "import_lora",
                    "success": False,
                    "message": "Cancelled",
                }
            )
            return

        emit_progress("Validating LoRA weights…", 0, _IMPORT_PROGRESS_PROBE_STEPS)
        source = validate_safetensors_source(source_path)
        if not lora_probe_model_is_local(model_key):
            raise RuntimeError(
                f"The base model ({lora_model_display_name(model_key)}) "
                "is not installed locally. Download it first, then import the LoRA."
            )
        host_id = host_id_for_lora_model(model_key)
        if not host_id:
            raise ValueError(f"LoRAs are not supported for model {model_key!r}.")
        emit_progress("Preparing LoRA entry…", 1, _IMPORT_PROGRESS_PROBE_STEPS)
        if reuse_lora_id:
            entry = get_lora_entry(reuse_lora_id)
            if entry is None:
                raise ValueError(f"LoRA {reuse_lora_id!r} was not found.")
            if entry.host_id != host_id:
                raise ValueError(
                    "This LoRA file is already imported for a different model family."
                )
            update_lora_entry_metadata(
                entry.lora_id,
                display_name=display_name,
                trigger_word=trigger_word or None,
                best_guess=best_guess,
                comment=comment or None,
                reference_prompt=reference_prompt,
                repo_id=repo_id,
                filename=filename,
                source_path=recovery_source_path or None,
            )
            entry = get_lora_entry(entry.lora_id)
            if entry is None:
                raise ValueError(f"LoRA {reuse_lora_id!r} was not found.")
        else:
            existing = find_user_lora_for_source(source, host_id=host_id)
            if existing is not None:
                update_lora_entry_metadata(
                    existing.lora_id,
                    display_name=display_name,
                    trigger_word=trigger_word or None,
                    best_guess=best_guess,
                    comment=comment or None,
                    reference_prompt=reference_prompt,
                    repo_id=repo_id,
                    filename=filename,
                    source_path=recovery_source_path or None,
                )
                entry = get_lora_entry(existing.lora_id)
                if entry is None:
                    raise ValueError(f"LoRA {existing.lora_id!r} was not found.")
            else:
                entry = build_user_lora_entry(
                    source_path=source,
                    display_name=display_name,
                    model_key=model_key,
                    trigger_word=trigger_word or None,
                    scale=best_guess,
                    best_guess=best_guess,
                    comment=comment or None,
                    reference_prompt=reference_prompt,
                    repo_id=repo_id,
                    filename=filename,
                )
                if recovery_source_path:
                    from dataclasses import replace

                    entry = replace(entry, source_path=recovery_source_path)
                created_new = True
        assert_lora_compatible_for_model(
            entry.local_path or "",
            model_key,
            catalog_host_id=entry.host_id,
        )
        support = lora_model_support().get(entry.lora_id, ())
        aliases = klein_lora_model_aliases(model_key)
        already_supported = any(m in support for m in aliases)
        progress_max = (
            _IMPORT_PROGRESS_SKIP_PROBE_STEPS
            if already_supported
            else _IMPORT_PROGRESS_PROBE_STEPS
        )
        if not already_supported:
            emit_progress(
                f"Testing compatibility on {lora_model_display_name(model_key)}…",
                1,
                progress_max,
            )

            def activity_callback(message: str) -> None:
                emit_progress(message, 2, progress_max)

            ok = probe_lora_on_model(
                model_key,
                entry.local_path or "",
                entry.scale,
                cancelled,
                entry=entry,
                probe_prompt=lora_probe_prompt(
                    entry,
                    fallback=_probe_fallback_prompt(reference_prompt),
                    weights_path=entry.local_path or "",
                    allow_online=False,
                ),
                activity_callback=activity_callback,
            )
            if cancelled():
                emit_message(
                    {
                        "type": "result",
                        "job_id": job_id,
                        "command": "import_lora",
                        "success": False,
                        "message": "Cancelled",
                        "entry": _entry_to_dict(entry, model_key=model_key),
                    }
                )
                return
            if not ok:
                emit_message(
                    {
                        "type": "result",
                        "job_id": job_id,
                        "command": "import_lora",
                        "success": False,
                        "message": (
                            f"LoRA «{entry.display_name}» failed the compatibility test for "
                            f"{lora_model_display_name(model_key)}."
                        ),
                        "entry": _entry_to_dict(entry, model_key=model_key),
                        "created_new_entry": created_new,
                    }
                )
                return
        else:
            emit_progress(
                "LoRA already tested for this model; skipping probe…",
                2,
                progress_max,
            )
        emit_progress("Adding to library…", progress_max - 1, progress_max)
        register_user_lora(
            entry,
            model_key=model_key,
            supported_models=[model_key],
        )
        try:
            emit_progress("Looking up source metadata…", progress_max, progress_max)
            enrich_lora_origin_metadata(entry.lora_id)
            refreshed = get_lora_entry(entry.lora_id)
            if refreshed is not None:
                entry = refreshed
        except Exception:
            pass
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "import_lora",
                "success": True,
                "entry": _entry_to_dict(entry, model_key=model_key),
            }
        )
    except Exception as exc:
        if entry is not None and created_new:
            try:
                from imagegen_plugins.lora_user_entries import remove_user_lora_files

                remove_user_lora_files(entry)
            except Exception:
                pass
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "import_lora",
                "success": False,
                "message": str(exc),
                "created_new_entry": created_new,
            }
        )


def _handle_import_lora(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _active_import_thread, _import_cancel_flag
    if _check_loras_running:
        raise RuntimeError("Check LoRAs is running. Wait for it to finish.")
    if _active_import_thread is not None and _active_import_thread.is_alive():
        raise RuntimeError("Another LoRA import is already running.")
    job_id = str(cmd.get("job_id") or "")
    _import_cancel_flag = [False]
    thread = threading.Thread(
        target=_run_import_worker,
        args=(cmd, job_id),
        daemon=True,
    )
    _active_import_thread = thread
    thread.start()
    return {
        "type": "result",
        "job_id": job_id,
        "command": "import_lora",
        "started": True,
    }


def _handle_cancel_import(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _import_cancel_flag
    _import_cancel_flag[0] = True
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "cancel_import",
        "success": True,
    }


def _run_find_origin_worker(lora_id: str, job_id: str) -> None:
    try:
        from imagegen_plugins.image_gen_persistence import enrich_lora_origin_metadata

        match = enrich_lora_origin_metadata(lora_id)
        if match is None:
            emit_message(
                {
                    "type": "result",
                    "job_id": job_id,
                    "command": "find_origin",
                    "success": False,
                    "message": "No matching Civitai or Hugging Face source was found.",
                }
            )
            return
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "find_origin",
                "success": True,
                "page_url": str(getattr(match, "page_url", "") or ""),
                "download_url": str(getattr(match, "download_url", "") or ""),
                "note": str(getattr(match, "note", "") or ""),
            }
        )
    except Exception as exc:
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "find_origin",
                "success": False,
                "message": str(exc),
            }
        )


def _handle_find_origin(cmd: Dict[str, Any]) -> Dict[str, Any]:
    lora_id = str(cmd.get("lora_id") or "").strip()
    job_id = str(cmd.get("job_id") or "")
    if not lora_id:
        raise ValueError("lora_id is required")
    thread = threading.Thread(
        target=_run_find_origin_worker,
        args=(lora_id, job_id),
        daemon=True,
    )
    thread.start()
    return {
        "type": "result",
        "job_id": job_id,
        "command": "find_origin",
        "started": True,
    }


def _check_loras_options_from_dict(raw: Dict[str, Any]):
    from imagegen_plugins.lora_compatibility_checker import (
        CheckLorasOptions,
        LORA_SCOPE_ALL,
        MODEL_SCOPE_ALL,
        REGISTRATION_IGNORE_PREVIOUS,
        installed_probeable_models,
        normalize_check_loras_probe_prompt,
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
        probe_prompt=normalize_check_loras_probe_prompt(raw.get("probe_prompt")),
        skip_unchanged=bool(raw.get("skip_unchanged", True)),
        check_cross_families=bool(raw.get("check_cross_families", True)),
    )


def _check_loras_options_to_dict(options) -> Dict[str, Any]:
    return {
        "model_scope": options.model_scope,
        "selected_model_keys": list(options.selected_model_keys),
        "lora_scope": options.lora_scope,
        "selected_lora_keys": list(options.selected_lora_keys),
        "registration_mode": options.registration_mode,
        "probe_prompt": options.probe_prompt,
        "skip_unchanged": bool(options.skip_unchanged),
        "check_cross_families": bool(options.check_cross_families),
    }


def _check_loras_choice_to_dict(choice) -> Dict[str, Any]:
    return {
        "key": choice.key,
        "label": choice.label,
        "display_name": choice.display_name or choice.label,
        "weights_path": choice.weights_path or "",
        "from_downloads": bool(choice.from_downloads),
    }


def _check_loras_nothing_to_probe_message(prepared, options) -> str:
    plan_stats = prepared.stats
    return (
        "Nothing to probe with the current options.\n\n"
        f"Catalog candidates considered: {len(prepared.candidates)}\n"
        f"Skipped (not on disk): {plan_stats.skipped_not_on_disk}\n"
        f"Weight files discovered: {plan_stats.files_discovered}\n"
        f"Downloads scanned: {plan_stats.downloads_scanned}\n"
        f"Unchanged (history): {plan_stats.skipped_unchanged}\n"
        f"Models in plan: {plan_stats.models_total}\n"
        f"Probes planned: {plan_stats.probes_total} GPU · "
        f"{plan_stats.skipped_unchanged_probes} history\n\n"
        "Adjust options, download LoRA weights (or place .safetensors in "
        "cache or ~/Downloads), or install a base model, then try again."
    )


def _handle_check_loras_prescan(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.hf_model_ids import lora_model_display_name
    from imagegen_plugins.lora_compatibility_checker import (
        check_loras_options_from_settings,
        discover_check_lora_choices,
        installed_probeable_models,
    )

    settings = get_config().load_settings()
    choices = discover_check_lora_choices(settings, dedupe_downloads=False)
    saved = check_loras_options_from_settings(settings)
    installed = [
        {"model_key": key, "display_name": lora_model_display_name(key)}
        for key in installed_probeable_models()
    ]
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "check_loras_prescan",
        "choices": [_check_loras_choice_to_dict(c) for c in choices],
        "installed_models": installed,
        "saved_options": _check_loras_options_to_dict(saved),
    }


def _run_check_loras_prepare_worker(cmd: Dict[str, Any], job_id: str) -> None:
    global _check_loras_prepared, _check_loras_preparing
    from dataclasses import asdict

    from config import get_config
    from imagegen_plugins.lora_compatibility_checker import (
        PreparedLoraProbePlan,
        normalize_check_loras_probe_prompt,
        persist_check_loras_options,
        plan_disk_lora_probes,
    )

    options = _check_loras_options_from_dict(cmd.get("options") or {})
    try:
        persist_check_loras_options(options)
        cfg = get_config().load_settings()
        candidates, plan, plan_stats = plan_disk_lora_probes(
            cfg, dedupe=True, options=options
        )
        if _check_loras_cancel_flag[0]:
            emit_message(
                {
                    "type": "result",
                    "job_id": job_id,
                    "command": "check_loras_prepare",
                    "success": False,
                    "cancelled": True,
                }
            )
            return
        plan_stats.probe_prompt = normalize_check_loras_probe_prompt(options.probe_prompt)
        prepared = PreparedLoraProbePlan(
            candidates=candidates, plan=plan, stats=plan_stats
        )
        _check_loras_prepared = prepared
        nothing = not plan or (
            plan_stats.probes_total == 0
            and plan_stats.skipped_unchanged_probes == 0
            and plan_stats.skipped_unchanged == 0
        )
        payload: Dict[str, Any] = {
            "type": "result",
            "job_id": job_id,
            "command": "check_loras_prepare",
            "success": True,
            "cancelled": False,
            "stats": asdict(plan_stats),
            "candidates_count": len(candidates),
            "nothing_to_probe": nothing,
        }
        if nothing:
            payload["message"] = _check_loras_nothing_to_probe_message(prepared, options)
        emit_message(payload)
    except Exception as exc:
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "check_loras_prepare",
                "success": False,
                "cancelled": bool(_check_loras_cancel_flag[0]),
                "message": str(exc),
            }
        )
    finally:
        _check_loras_preparing = False


def _handle_check_loras_prepare(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _check_loras_cancel_flag, _active_check_loras_prepare_thread, _check_loras_preparing

    if _check_loras_running:
        raise RuntimeError("Check LoRAs is already running.")
    if _check_loras_preparing:
        raise RuntimeError("Check LoRAs prepare is already running.")
    if _active_import_thread is not None and _active_import_thread.is_alive():
        raise RuntimeError("A LoRA import is running. Wait for it to finish.")

    job_id = str(cmd.get("job_id") or "")
    _check_loras_cancel_flag[0] = False
    _check_loras_preparing = True
    thread = threading.Thread(
        target=_run_check_loras_prepare_worker,
        args=(cmd, job_id),
        daemon=True,
    )
    _active_check_loras_prepare_thread = thread
    thread.start()
    return {
        "type": "result",
        "job_id": job_id,
        "command": "check_loras_prepare",
        "started": True,
    }


def _handle_check_loras_save_options(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.lora_compatibility_checker import persist_check_loras_options

    options = _check_loras_options_from_dict(cmd.get("options") or {})
    persist_check_loras_options(options)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "check_loras_save_options",
        "success": True,
    }


def _run_check_loras_worker(cmd: Dict[str, Any], job_id: str) -> None:
    global _check_loras_prepared, _check_loras_running
    from dataclasses import asdict

    from config import get_config
    from imagegen_plugins.check_loras_debug import (
        apply_lora_check_result,
        format_check_loras_results_text,
    )
    from imagegen_plugins.lora_compatibility_checker import (
        lora_check_work_total,
        run_lora_compatibility_check,
    )

    options = _check_loras_options_from_dict(cmd.get("options") or {})
    settings = get_config().load_settings()

    def progress_callback(
        probe_index: int,
        probe_total: int,
        phase: str,
        lora_id: str,
        model_key: str,
        stats,
    ) -> None:
        work_total = max(1, lora_check_work_total(stats))
        emit_message(
            {
                "type": "progress",
                "job_id": job_id,
                "command": "check_loras_run",
                "probe_index": probe_index,
                "probe_total": probe_total,
                "work_total": work_total,
                "phase": phase,
                "lora_id": lora_id,
                "model_key": model_key,
                "stats": asdict(stats),
            }
        )

    def cancel_check() -> bool:
        return bool(_check_loras_cancel_flag[0])

    try:
        result = run_lora_compatibility_check(
            settings,
            progress_callback=progress_callback,
            cancel_check=cancel_check,
            options=options,
            prepared=_check_loras_prepared,
        )
        report_paths: List[str] = []
        results_text = ""
        if result.cancelled and result.stats.probes_done == 0:
            results_text = (
                "Check LoRAs was cancelled.\n\nNo probes were completed."
            )
        else:
            report_paths = apply_lora_check_result(result)
            results_text = format_check_loras_results_text(result, report_paths)

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
                "command": "check_loras_run",
                "success": True,
                "cancelled": result.cancelled,
                "passed": result.stats.passed_probe_count,
                "failed": result.stats.failed_probe_count,
                "skipped": result.stats.skipped_loras,
                "probes_done": result.stats.probes_done,
                "changes": changes,
                "stats": asdict(result.stats),
                "elapsed_seconds": result.elapsed_seconds,
                "results_text": results_text,
                "report_paths": report_paths,
            }
        )
    except Exception as exc:
        emit_message(
            {
                "type": "error",
                "job_id": job_id,
                "command": "check_loras_run",
                "message": str(exc),
            }
        )
    finally:
        _check_loras_running = False


def _handle_check_loras_run(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _check_loras_cancel_flag, _active_check_loras_thread, _check_loras_running

    if _check_loras_preparing:
        raise RuntimeError("Check LoRAs is still preparing. Wait for it to finish.")
    if _check_loras_running:
        raise RuntimeError("Check LoRAs is already running.")
    if _active_import_thread is not None and _active_import_thread.is_alive():
        raise RuntimeError("A LoRA import is running. Wait for it to finish.")

    job_id = str(cmd.get("job_id") or "")
    _check_loras_cancel_flag[0] = False
    _check_loras_running = True
    thread = threading.Thread(
        target=_run_check_loras_worker,
        args=(cmd, job_id),
        daemon=True,
    )
    _active_check_loras_thread = thread
    thread.start()
    return {
        "type": "result",
        "job_id": job_id,
        "command": "check_loras_run",
        "started": True,
    }


def _handle_check_loras_cancel(cmd: Dict[str, Any]) -> Dict[str, Any]:
    global _check_loras_cancel_flag
    _check_loras_cancel_flag[0] = True
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "check_loras_cancel",
        "success": True,
    }


def _handle_check_loras_clear_probe_history(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import clear_lora_probe_history
    from imagegen_plugins.lora_catalog import lora_probe_history

    count_before = len(lora_probe_history())
    dry_run = bool(cmd.get("dry_run"))
    removed = 0
    if not dry_run and count_before:
        removed = clear_lora_probe_history()
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "check_loras_clear_probe_history",
        "success": True,
        "count_before": count_before,
        "removed": removed,
    }


def _handle_match_exif(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.lora_catalog import match_exif_lora_names_to_ids_and_scales

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    lora_text = str(cmd.get("lora_text") or "").strip()
    plugin = plugin_by_id(plugin_id) if plugin_id else None
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")
    ids, scales = match_exif_lora_names_to_ids_and_scales(lora_text, plugin)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "match_exif",
        "ids": ids,
        "scales_by_id": scales,
    }


def _handle_command(cmd: Dict[str, Any]) -> Any:
    command = str(cmd.get("command") or "").strip()
    if command == "shutdown":
        return "shutdown"
    handlers = {
        "settings_models": _handle_settings_models,
        "settings_entries": _handle_settings_entries,
        "save_catalog_state": _handle_save_catalog_state,
        "choices_for_plugin": _handle_choices_for_plugin,
        "selected_display_text": _handle_selected_display_text,
        "exif_label_from_values": _handle_exif_label_from_values,
        "update_entry_scales": _handle_update_entry_scales,
        "install": _handle_install,
        "delete": _handle_delete,
        "save_user_preset": _handle_save_user_preset,
        "apply_user_preset": _handle_apply_user_preset,
        "restore_recommendations": _handle_restore_recommendations,
        "find_choices": _handle_find_choices,
        "get_entry": _handle_get_entry,
        "validate_source": _handle_validate_source,
        "save_metadata": _handle_save_metadata,
        "import_lora": _handle_import_lora,
        "cancel_import": _handle_cancel_import,
        "find_origin": _handle_find_origin,
        "match_exif": _handle_match_exif,
        "check_loras_prescan": _handle_check_loras_prescan,
        "check_loras_prepare": _handle_check_loras_prepare,
        "check_loras_save_options": _handle_check_loras_save_options,
        "check_loras_run": _handle_check_loras_run,
        "check_loras_cancel": _handle_check_loras_cancel,
        "check_loras_clear_probe_history": _handle_check_loras_clear_probe_history,
    }
    handler = handlers.get(command)
    if handler is None:
        raise ValueError(f"Unknown command: {command}")
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
