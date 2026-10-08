#!/usr/bin/env python3
"""Freeze dialog-controlled job inputs at submit time for queued generation."""

from __future__ import annotations

import os
from typing import Any, Dict, List

from imagegen_plugins.image_gen_registry import ImageGenModelPlugin

JOB_VALUES_SNAPSHOTTED_KEY = "_job_values_snapshotted"
LORA_SCALES_BY_ID_KEY = "mflux_lora_scales_by_id"
LORA_TRIGGER_WORDS_KEY = "mflux_lora_trigger_words"
JOB_QUEUE_ONLY_SUBMIT_KEYS = frozenset(
    {"series_refinement", "series_prompt_refinement"}
)


def job_values_snapshotted(values: Dict[str, Any] | None) -> bool:
    return bool(isinstance(values, dict) and values.get(JOB_VALUES_SNAPSHOTTED_KEY))


def _lora_scale_for_preset(values: Dict[str, Any], preset_id: str) -> float:
    scales_by_id = values.get(LORA_SCALES_BY_ID_KEY)
    if isinstance(scales_by_id, dict) and preset_id in scales_by_id:
        try:
            return float(scales_by_id[preset_id])
        except (TypeError, ValueError):
            pass
    from imagegen_plugins.lora_catalog import get_lora_entry

    entry = get_lora_entry(preset_id)
    if entry is not None:
        return float(entry.scale)
    return 1.0


def _snapshot_lora_for_job(values: Dict[str, Any], pipeline_id: str) -> None:
    from imagegen_plugins.lora_catalog import get_lora_entry
    from imagegen_plugins.lora_host_registry import HOST_SD15, HOST_SDXL, lora_host_for_pipeline
    from imagegen_plugins.mflux_lora_presets import (
        effective_lora_ids_from_values,
        resolve_lora_path,
    )

    host = lora_host_for_pipeline(pipeline_id)
    stack = effective_lora_ids_from_values(
        values, pipeline_id=pipeline_id, pop=False
    )
    if not stack:
        values.pop("mflux_lora_paths", None)
        values.pop("mflux_lora_scales", None)
        values.pop("sd15_lora_paths", None)
        values.pop("sd15_lora_scales", None)
        values.pop("sdxl_lora_paths", None)
        values.pop("sdxl_lora_scales", None)
        values.pop(LORA_TRIGGER_WORDS_KEY, None)
        values.pop(LORA_SCALES_BY_ID_KEY, None)
        if host == HOST_SD15:
            values["mflux_lora"] = "none"
            values.pop("mflux_lora_stack", None)
        else:
            values["mflux_lora_stack"] = []
            values.pop("mflux_lora", None)
        return

    paths: List[str] = []
    scales: List[float] = []
    trigger_words: List[str] = []
    for preset_id in stack:
        entry = get_lora_entry(preset_id)
        if entry is None:
            raise ValueError(f"Unknown LoRA preset: {preset_id}")
        paths.append(resolve_lora_path(preset_id))
        scales.append(_lora_scale_for_preset(values, preset_id))
        trigger = (entry.trigger_word or "").strip()
        if trigger:
            trigger_words.append(trigger)

    values[LORA_TRIGGER_WORDS_KEY] = trigger_words
    values[LORA_SCALES_BY_ID_KEY] = {
        preset_id: scales[i] for i, preset_id in enumerate(stack)
    }
    if host == HOST_SD15:
        values["mflux_lora"] = stack[0]
        values.pop("mflux_lora_stack", None)
        values["sd15_lora_paths"] = paths
        values["sd15_lora_scales"] = scales
        values.pop("mflux_lora_paths", None)
        values.pop("mflux_lora_scales", None)
        values.pop("sdxl_lora_paths", None)
        values.pop("sdxl_lora_scales", None)
    elif host == HOST_SDXL:
        values["mflux_lora_stack"] = list(stack)
        values.pop("mflux_lora", None)
        values["sdxl_lora_paths"] = paths
        values["sdxl_lora_scales"] = scales
        values.pop("mflux_lora_paths", None)
        values.pop("mflux_lora_scales", None)
        values.pop("sd15_lora_paths", None)
        values.pop("sd15_lora_scales", None)
    else:
        values["mflux_lora_stack"] = list(stack)
        values.pop("mflux_lora", None)
        values["mflux_lora_paths"] = paths
        values["mflux_lora_scales"] = scales
        values.pop("sd15_lora_paths", None)
        values.pop("sd15_lora_scales", None)
        values.pop("sdxl_lora_paths", None)
        values.pop("sdxl_lora_scales", None)


def _normalize_job_source_paths(
    plugin: ImageGenModelPlugin, values: Dict[str, Any]
) -> None:
    """Keep queued job source paths consistent with the dialog function."""
    from imagegen_plugins.image_gen_active_model import (
        FUNCTION_EDIT,
        FUNCTION_EXPAND,
        FUNCTION_INFILL_PAINT,
    )
    from imagegen_plugins.image_gen_naming import resolve_source_image_paths

    function = plugin.function
    if function in (FUNCTION_EXPAND, FUNCTION_INFILL_PAINT):
        primary = str(values.get("source_image_path") or "").strip()
        if primary and os.path.isfile(primary):
            ap = os.path.normpath(os.path.abspath(primary))
            values["source_image_path"] = ap
            values["source_image_paths"] = [ap]
        else:
            values.pop("source_image_path", None)
            values.pop("source_image_paths", None)
        values.pop("_canonical_source_image_paths", None)
        return
    if function == FUNCTION_EDIT:
        paths = resolve_source_image_paths(values)
        if paths:
            values["source_image_paths"] = list(paths)
            values["source_image_path"] = paths[0]
            values["_canonical_source_image_paths"] = list(paths)
        else:
            values.pop("source_image_path", None)
            values.pop("source_image_paths", None)
            values.pop("_canonical_source_image_paths", None)


def strip_dialog_leaked_job_queue_flags(values: Dict[str, Any]) -> None:
    """Drop job-toolbar flags that must not carry from dialog defaults into new jobs."""
    for key in JOB_QUEUE_ONLY_SUBMIT_KEYS:
        values.pop(key, None)


def preserve_job_queue_only_keys(
    values: Dict[str, Any], source: Dict[str, Any]
) -> None:
    """Keep toolbar-owned flags when dialog Replace/Update omits them."""
    for key in JOB_QUEUE_ONLY_SUBMIT_KEYS:
        if key in source and key not in values:
            values[key] = source[key]


def snapshot_job_values_at_submit(
    plugin: ImageGenModelPlugin, values: Dict[str, Any]
) -> Dict[str, Any]:
    """Return a copy of job values frozen for execution at submit time."""
    from workers.ipc_json import configure_profile_from_env

    configure_profile_from_env()
    from config import get_config
    from imagegen_plugins.image_gen_dim_limits import effective_max_for_plugin
    from imagegen_plugins.image_gen_pipeline_modes import get_pipeline

    out = dict(values)
    pipeline_id = plugin.pipeline_id
    out["pipeline_id"] = pipeline_id
    _normalize_job_source_paths(plugin, out)
    _snapshot_lora_for_job(out, pipeline_id)

    mode = get_pipeline(pipeline_id)
    if mode.supports_progressive_images:
        from imagegen_plugins.image_gen_persistence import load_show_progressive_images

        out["show_progressive_images"] = load_show_progressive_images()

    out["debug_mode"] = bool(
        get_config().load_settings().get("debug_mode", False)
    )
    out["max_generation_dimension"] = effective_max_for_plugin(plugin)
    out[JOB_VALUES_SNAPSHOTTED_KEY] = True
    return out


WORKER_LORA_MERGE_KEYS: tuple[str, ...] = (
    "mflux_lora_paths",
    "mflux_lora_scales",
    "sd15_lora_paths",
    "sd15_lora_scales",
    "sdxl_lora_paths",
    "sdxl_lora_scales",
    "mflux_lora_scales_by_id",
    "mflux_lora_trigger_words",
    "steps",
)


def enrich_values_with_worker_lora_fields(
    plugin: ImageGenModelPlugin,
    values: Dict[str, Any],
    *,
    output_path: str,
    apply_image_exit: bool = False,
) -> Dict[str, Any]:
    """Resolve LoRA stack to worker path/scale keys (``build_worker_payload`` parity)."""
    from imagegen_plugins.image_gen_dim_limits import effective_max_for_plugin
    from imagegen_plugins.image_gen_pipeline_modes import build_worker_payload

    max_side = effective_max_for_plugin(plugin)
    if job_values_snapshotted(values):
        snap_max = values.get("max_generation_dimension")
        if snap_max is not None:
            try:
                max_side = int(snap_max)
            except (TypeError, ValueError):
                pass
    # LoRA resolution only; image AI exit needs Qt and is applied in Swift when needed.
    built = build_worker_payload(
        plugin.pipeline_id,
        values,
        output_path,
        plugin.hf_model_id,
        effective_max_side=max_side,
        apply_image_exit=False,
    )
    out = dict(values)
    path_scale_keys = {
        k
        for k in WORKER_LORA_MERGE_KEYS
        if k.endswith("_paths") or k.endswith("_scales")
    }
    for key in WORKER_LORA_MERGE_KEYS:
        if key in built:
            out[key] = built[key]
        elif key in path_scale_keys:
            out.pop(key, None)
    return out


__all__ = [
    "JOB_QUEUE_ONLY_SUBMIT_KEYS",
    "JOB_VALUES_SNAPSHOTTED_KEY",
    "LORA_SCALES_BY_ID_KEY",
    "LORA_TRIGGER_WORDS_KEY",
    "job_values_snapshotted",
    "preserve_job_queue_only_keys",
    "snapshot_job_values_at_submit",
    "strip_dialog_leaked_job_queue_flags",
    "WORKER_LORA_MERGE_KEYS",
    "enrich_values_with_worker_lora_fields",
]
