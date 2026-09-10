#!/usr/bin/env python3
"""NDJSON bridge for Swift UI: plugin discovery, payload build, value normalization."""

from __future__ import annotations

import os
import sys
from typing import Any, Dict, Optional

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from imagegen_plugins.image_gen_fields import FieldGroup, FieldSpec, FieldNode
from workers.ipc_json import emit_message, parse_command_line, read_line


def _field_spec_to_dict(spec: FieldSpec) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "key": spec.key,
        "label": spec.label,
        "kind": spec.kind,
        "default": spec.default,
        "required": bool(spec.required),
    }
    if spec.min_value is not None:
        out["min_value"] = spec.min_value
    if spec.max_value is not None:
        out["max_value"] = spec.max_value
    if spec.step is not None:
        out["step"] = spec.step
    if spec.choices is not None:
        out["choices"] = list(spec.choices)
    if spec.bool_label_override is not None:
        out["bool_label_override"] = spec.bool_label_override
    if spec.reset_default is not None:
        out["reset_default"] = spec.reset_default
    return out


def _field_node_to_dict(node: FieldNode) -> Dict[str, Any]:
    if isinstance(node, FieldSpec):
        return {"type": "field", "spec": _field_spec_to_dict(node)}
    return {
        "type": "group",
        "layout": node.layout,
        "label": node.label,
        "children": [_field_node_to_dict(child) for child in node.children],
    }


def _plugin_to_dict(plugin, saved: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_dim_limits import effective_max_for_plugin

    values = plugin.merged_values(saved)
    layout = plugin.field_layout_builder(
        plugin, values, effective_max_for_plugin(plugin)
    ) if plugin.field_layout_builder else ()
    return {
        "plugin_id": plugin.plugin_id,
        "pipeline_id": plugin.pipeline_id,
        "display_name": plugin.display_name,
        "model_label": plugin.model_label(saved),
        "model_comment": plugin.model_comment,
        "hf_model_id": plugin.hf_model_id,
        "function": plugin.function,
        "lora_host_id": plugin.lora_host_id,
        "max_generation_dimension": plugin.max_generation_dimension,
        "quantize_status_key": plugin.quantize_status_key,
        "available": plugin.is_available(),
        "merged_defaults": values,
        "field_layout": [_field_node_to_dict(node) for node in layout],
    }


def _handle_list_plugins(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import discover_plugins, plugins_for_function

    function = str(cmd.get("function") or "").strip()
    saved = cmd.get("saved_values")
    if not isinstance(saved, dict):
        saved = None
    if function:
        plugins = plugins_for_function(function)
    else:
        plugins = discover_plugins()
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "list_plugins",
        "plugins": [_plugin_to_dict(p, saved) for p in plugins],
    }


def _handle_build_payload(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    output_path = str(cmd.get("output_path") or "").strip()
    if not plugin_id:
        raise ValueError("plugin_id is required")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    if not output_path:
        raise ValueError("output_path is required")
    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")
    apply_exit = bool(cmd.get("apply_image_exit", True))
    payload = plugin.build_payload(values, output_path, apply_image_exit=apply_exit)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "build_payload",
        "payload": payload,
    }


def _handle_normalize_values(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.job_values_snapshot import (
        snapshot_job_values_at_submit,
        strip_dialog_leaked_job_queue_flags,
    )

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    mode = str(cmd.get("mode") or "snapshot").strip()
    if not plugin_id:
        raise ValueError("plugin_id is required")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")
    out = dict(values)
    if mode == "strip_dialog_flags":
        strip_dialog_leaked_job_queue_flags(out)
    elif mode == "snapshot":
        out = snapshot_job_values_at_submit(plugin, out)
    else:
        raise ValueError(f"Unknown normalize mode: {mode}")
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "normalize_values",
        "values": out,
    }


def _queue_status_row_to_dict(row: Any) -> Dict[str, Any]:
    from imagegen_plugins.job_status_views import (
        QueueBannerRow,
        QueueInlineRow,
        QueueLabelValueRow,
        QueuePromptRow,
        QueueTitleRow,
        QueueUnavailableRow,
    )

    if isinstance(row, QueueTitleRow):
        return {"type": "title", "title": row.title, "running": bool(row.running)}
    if isinstance(row, QueueLabelValueRow):
        return {"type": "label_value", "label": row.label, "value": row.value}
    if isinstance(row, QueuePromptRow):
        return {"type": "prompt", "label": row.label, "value": row.value}
    if isinstance(row, QueueInlineRow):
        return {
            "type": "inline",
            "label": row.label,
            "primary_value": row.primary_value,
            "inline_parts": [
                {"label": part_label, "value": part_value}
                for part_label, part_value in row.inline_parts
            ],
        }
    if isinstance(row, QueueUnavailableRow):
        return {
            "type": "unavailable",
            "heading": row.heading,
            "copies_line": row.copies_line,
            "prompt_line": row.prompt_line,
        }
    if isinstance(row, QueueBannerRow):
        return {"type": "banner", "text": row.text}
    return {"type": "unknown"}


def _queue_status_view_to_dict(view: Any) -> Dict[str, Any]:
    return {
        "rows": [_queue_status_row_to_dict(row) for row in view.rows],
        "cooldown_remaining": view.cooldown_remaining,
        "show_skip_cooldown": bool(view.show_skip_cooldown),
        "running": bool(view.running),
    }


def _strip_row_to_dict(row: Any) -> Dict[str, Any]:
    from imagegen_plugins.job_status_views import StripBarRow, StripCountRow

    if isinstance(row, StripBarRow):
        return {
            "type": "bar",
            "label": row.label,
            "prefix": row.prefix,
            "postfix": row.postfix,
            "fill_percent": int(row.fill_percent),
            "slot_text": row.slot_text,
            "show_pending_start": bool(row.show_pending_start),
        }
    if isinstance(row, StripCountRow):
        return {"type": "count", "label": row.label, "count": row.count}
    return {"type": "unknown"}


def _strip_view_to_dict(view: Any) -> Dict[str, Any]:
    return {
        "rows": [_strip_row_to_dict(row) for row in view.rows],
        "mode": view.mode,
        "cooldown_text": view.cooldown_text,
        "cooldown_count_text": view.cooldown_count_text,
        "show_skip_icon": bool(view.show_skip_icon),
        "show_cancel_icon": bool(view.show_cancel_icon),
    }


def _handle_build_queue_status_view(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job
    from imagegen_plugins.model_task_queue import (
        QueuedGenerateJob,
        job_references_invalid,
        refresh_queued_job_status,
        thumbnail_paths_for_values,
    )
    from imagegen_plugins.model_task_status_info import (
        build_queue_job_status_view,
        build_unavailable_queue_status_view,
    )

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    function = str(cmd.get("function") or "create").strip()
    values = cmd.get("values")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    copies_total = int(cmd.get("copies_total") or 1)
    plugin_unavailable = bool(cmd.get("plugin_unavailable", False))
    running = bool(cmd.get("running", False))
    omit_live_steps_row = bool(cmd.get("omit_live_steps_row", False))
    with_ai = bool(cmd.get("with_ai", False))
    step = cmd.get("step")
    step_total = cmd.get("step_total")
    elapsed_seconds = cmd.get("elapsed_seconds")
    estimate_seconds = cmd.get("estimate_seconds")

    plugin = plugin_by_id(plugin_id) if plugin_id else None
    if plugin is None or plugin_unavailable:
        view = build_unavailable_queue_status_view(
            plugin_id,
            function,
            values,
            copies_total=copies_total,
        )
        thumb_paths: list[str] = []
        full_prompt = str(values.get("prompt") or "").strip()
        refs_invalid = True
    else:
        job = QueuedGenerateJob(
            job_id="bridge",
            plugin=plugin,
            values=dict(values),
            status_html="",
            thumbnail_paths=thumbnail_paths_for_values(plugin, values),
            copies_total=copies_total,
            plugin_id=plugin.plugin_id,
            function=plugin.function,
        )
        refresh_queued_job_status(job)
        view = build_queue_job_status_view(
            plugin,
            job.values,
            step=step if step is not None else None,
            step_total=step_total if step_total is not None else None,
            elapsed_seconds=float(elapsed_seconds) if elapsed_seconds is not None else None,
            estimate_seconds=float(estimate_seconds) if estimate_seconds is not None else None,
            running=running,
            series_copies_total=copies_total,
            omit_live_steps_row=omit_live_steps_row,
            with_ai=with_ai or has_flux_prompt_ai_job(values),
        )
        thumb_paths = list(job.thumbnail_paths)
        full_prompt = job.full_prompt
        refs_invalid = job_references_invalid(plugin, values)

    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "build_queue_status_view",
        "status_view": _queue_status_view_to_dict(view),
        "thumbnail_paths": thumb_paths,
        "full_prompt": full_prompt,
        "references_invalid": refs_invalid,
    }


def _handle_build_active_job_strip_view(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.job_status_views import ActiveJobStripView
    from imagegen_plugins.model_task_status_info import (
        _active_job_time_progress_row,
        _panel_rows_to_strip_view_rows,
        _queue_jobs_count_row,
        _series_progress_row,
        _steps_progress_row,
    )

    cooldown_remaining = int(cmd.get("cooldown_remaining") or 0)
    include_queue_jobs_row = bool(cmd.get("include_queue_jobs_row", False))
    completed_series = cmd.get("completed_series")
    total_series = cmd.get("total_series")
    total_queue_jobs = cmd.get("total_queue_jobs")
    steps_label = str(cmd.get("steps_label") or "Steps:")

    if cooldown_remaining > 0:
        progress_rows = []
        if completed_series is not None and total_series is not None:
            series_row = _series_progress_row(int(completed_series), int(total_series))
            if series_row is not None:
                progress_rows.append(series_row)
        if include_queue_jobs_row and total_queue_jobs is not None:
            jobs_row = _queue_jobs_count_row(int(total_queue_jobs))
            if jobs_row is not None:
                progress_rows.append(jobs_row)
        strip_rows = _panel_rows_to_strip_view_rows(progress_rows)
        remaining_i = max(0, int(cooldown_remaining))
        view = ActiveJobStripView(
            rows=tuple(strip_rows),
            mode="cooldown",
            cooldown_text="Cooldown:",
            cooldown_count_text=f"({remaining_i})",
            show_skip_icon=True,
            show_cancel_icon=True,
        )
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "build_active_job_strip_view",
            "strip_view": _strip_view_to_dict(view),
        }

    elapsed_seconds = cmd.get("elapsed_seconds")
    if elapsed_seconds is None:
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "build_active_job_strip_view",
            "strip_view": _strip_view_to_dict(ActiveJobStripView()),
        }

    elapsed = float(elapsed_seconds)
    estimate = cmd.get("estimate_seconds")
    estimate_f = float(estimate) if estimate is not None else None
    step = int(cmd.get("step") or 0)
    step_total = int(cmd.get("step_total") or 0)

    progress_rows = [_active_job_time_progress_row(elapsed, estimate_f)]
    if step_total > 0:
        steps_row = _steps_progress_row(step, step_total, steps_label=steps_label)
        if steps_row is not None:
            progress_rows.append(steps_row)
    if completed_series is not None and total_series is not None:
        series_row = _series_progress_row(int(completed_series), int(total_series))
        if series_row is not None:
            progress_rows.append(series_row)
    if include_queue_jobs_row and total_queue_jobs is not None:
        jobs_row = _queue_jobs_count_row(int(total_queue_jobs))
        if jobs_row is not None:
            progress_rows.append(jobs_row)

    pending_start = step_total > 0 and step <= 0
    strip_rows = _panel_rows_to_strip_view_rows(
        progress_rows,
        steps_label=steps_label,
        show_pending_start_indicator=pending_start,
    )
    view = ActiveJobStripView(
        rows=tuple(strip_rows),
        mode="timing",
        show_cancel_icon=True,
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "build_active_job_strip_view",
        "strip_view": _strip_view_to_dict(view),
    }


def _handle_format_generation_exif_comment(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.image_gen_naming import format_image_exif_prompt
    from imagegen_plugins.image_gen_seed_persistence import (
        extract_used_seed_from_worker_result,
    )
    from imagegen_plugins.lora_trigger_prompt_guard import (
        lora_name_for_exif_from_values,
        prompt_text_for_exif,
    )

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")

    worker_result = cmd.get("worker_result")
    if not isinstance(worker_result, dict):
        worker_result = {}
    elapsed = cmd.get("elapsed_seconds")
    elapsed_f = float(elapsed) if elapsed is not None else None

    used_seed = extract_used_seed_from_worker_result(plugin.pipeline_id, worker_result)
    if used_seed is None and not values.get("random_seed"):
        try:
            used_seed = int(values.get("seed"))
        except (TypeError, ValueError):
            used_seed = None

    include_quantization = plugin.plugin_reports_quantization(values)
    comment = format_image_exif_prompt(
        plugin.menu_label(values),
        prompt_text_for_exif(values),
        elapsed_seconds=elapsed_f,
        seed=used_seed,
        steps=values.get("steps"),
        quantization=(
            plugin.quantize_for_exif(values) if include_quantization else None
        ),
        lora=lora_name_for_exif_from_values(
            values, pipeline_id=plugin.pipeline_id
        ),
        guidance=values.get("guidance_scale"),
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "format_generation_exif_comment",
        "comment": comment,
    }


def _exif_reference_entries_for_output(
    plugin,
    values: Dict[str, Any],
    output_path: str,
    *,
    fallback_source_paths: Optional[list] = None,
) -> tuple[Optional[list], bool]:
    """Mirror ``ImageGenController._exif_reference_entries_for_output``."""
    ref_entries = None
    allow_cross_dir = False
    if plugin.pipeline_id == "mflux_fill_infill":
        from imagegen_plugins.pixelmator_export import resolve_infill_reference

        resolved = resolve_infill_reference(
            output_path,
            values.get("pixelmator_doc_name"),
            pixelmator_file_path=values.get("pixelmator_doc_path"),
            fallback_paths=fallback_source_paths,
        )
        if resolved is not None:
            ref_entries = [resolved]
            allow_cross_dir = True
    else:
        from imagegen_plugins.flux_prompt_job import flux_prompt_ai_reference_image_paths
        from imagegen_plugins.image_gen_naming import (
            reference_entries_for_source_paths,
            source_paths_for_generation_exif,
        )
        from imagegen_plugins.image_gen_pipeline_modes import job_run_uses_source_image

        extra_paths: list = []
        if fallback_source_paths:
            extra_paths.extend(fallback_source_paths)
        extra_paths.extend(flux_prompt_ai_reference_image_paths(values))
        if not (job_run_uses_source_image(plugin.pipeline_id, values) or extra_paths):
            return ref_entries, allow_cross_dir
        source_paths = source_paths_for_generation_exif(
            values, extra_paths=extra_paths or None
        )
        ref_entries = reference_entries_for_source_paths(source_paths, output_path)
        if ref_entries:
            allow_cross_dir = True
    return ref_entries, allow_cross_dir


def _handle_write_generation_exif(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.image_gen_naming import (
        format_image_exif_prompt,
        resolve_generation_elapsed_seconds,
        write_exif_user_comment,
    )
    from imagegen_plugins.image_gen_seed_persistence import (
        extract_used_seed_from_worker_result,
    )
    from imagegen_plugins.lora_trigger_prompt_guard import (
        lora_name_for_exif_from_values,
        prompt_text_for_exif,
    )

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    output_path = str(cmd.get("output_path") or "").strip()
    values = cmd.get("values")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    if not plugin_id or not output_path:
        raise ValueError("plugin_id and output_path are required")
    if not os.path.isfile(output_path):
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "write_generation_exif",
            "success": False,
        }

    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")

    worker_result = cmd.get("worker_result")
    if not isinstance(worker_result, dict):
        worker_result = {}
    elapsed = cmd.get("elapsed_seconds")
    elapsed_f = float(elapsed) if elapsed is not None else None
    local_elapsed = cmd.get("local_elapsed")
    local_elapsed_f = float(local_elapsed) if local_elapsed is not None else None

    include_quantization = plugin.plugin_reports_quantization(values)
    if elapsed_f is not None:
        elapsed_seconds = elapsed_f
    else:
        elapsed_seconds = resolve_generation_elapsed_seconds(
            worker_result,
            output_path,
            local_elapsed=local_elapsed_f,
        )

    used_seed = extract_used_seed_from_worker_result(plugin.pipeline_id, worker_result)
    if used_seed is None and not values.get("random_seed"):
        try:
            used_seed = int(values.get("seed"))
        except (TypeError, ValueError):
            used_seed = None

    comment = format_image_exif_prompt(
        plugin.menu_label(values),
        prompt_text_for_exif(values),
        elapsed_seconds=elapsed_seconds,
        seed=used_seed,
        steps=values.get("steps"),
        quantization=(
            plugin.quantize_for_exif(values) if include_quantization else None
        ),
        lora=lora_name_for_exif_from_values(
            values, pipeline_id=plugin.pipeline_id
        ),
        guidance=values.get("guidance_scale"),
    )

    fallback_source_paths = cmd.get("fallback_source_paths")
    if not isinstance(fallback_source_paths, list):
        fallback_source_paths = []

    ref_entries, allow_cross_dir = _exif_reference_entries_for_output(
        plugin,
        values,
        output_path,
        fallback_source_paths=fallback_source_paths,
    )
    success = write_exif_user_comment(
        output_path,
        comment,
        reference_entries=ref_entries,
        allow_cross_directory_references=allow_cross_dir,
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "write_generation_exif",
        "success": bool(success),
        "comment": comment,
    }


def _handle_get_exif_user_description(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from exif.exif_utils import (
        get_exif_dict_named_from_image_path,
        get_user_description_from_exif_dict,
    )
    from imagegen_plugins.image_gen_naming import format_user_comment_text_for_display

    path = str(cmd.get("path") or "").strip()
    if not path or not os.path.isfile(path):
        return {
            "type": "result",
            "job_id": cmd.get("job_id", ""),
            "command": "get_exif_user_description",
            "description": None,
        }
    exif_dict = get_exif_dict_named_from_image_path(path)
    desc = get_user_description_from_exif_dict(exif_dict)
    if desc:
        desc = format_user_comment_text_for_display(desc) or desc
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "get_exif_user_description",
        "description": desc,
    }


def _handle_write_exif_user_comment(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_naming import write_exif_user_comment

    path = str(cmd.get("path") or "").strip()
    comment = str(cmd.get("comment") or "")
    if not path:
        raise ValueError("path is required")
    reference_entries = cmd.get("reference_entries")
    if reference_entries is not None and not isinstance(reference_entries, list):
        reference_entries = None
    allow_cross_directory = bool(cmd.get("allow_cross_directory_references"))
    success = write_exif_user_comment(
        path,
        comment,
        reference_entries=reference_entries,
        allow_cross_directory_references=allow_cross_directory,
    )
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "write_exif_user_comment",
        "success": bool(success),
    }


def _handle_delete_exif_user_comment(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from exif.exif_utils import delete_usercomment_from_file, get_usercomment_from_path

    path = str(cmd.get("path") or "").strip()
    if not path:
        raise ValueError("path is required")
    success = delete_usercomment_from_file(path)
    if success and get_usercomment_from_path(path):
        success = False
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "delete_exif_user_comment",
        "success": bool(success),
    }


def _handle_thumbnail_paths(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.model_task_queue import thumbnail_paths_for_values

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    plugin = plugin_by_id(plugin_id) if plugin_id else None
    paths = thumbnail_paths_for_values(plugin, values)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "thumbnail_paths",
        "thumbnail_paths": paths,
    }


def _handle_materialize_steps(cmd: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins import plugin_by_id
    from imagegen_plugins.job_step_queue import materialize_steps

    plugin_id = str(cmd.get("plugin_id") or "").strip()
    values = cmd.get("values")
    copies = int(cmd.get("copies") or 1)
    if not plugin_id:
        raise ValueError("plugin_id is required")
    if not isinstance(values, dict):
        raise ValueError("values must be an object")
    plugin = plugin_by_id(plugin_id)
    if plugin is None:
        raise ValueError(f"Unknown plugin: {plugin_id}")
    steps = materialize_steps(plugin, values, copies)
    return {
        "type": "result",
        "job_id": cmd.get("job_id", ""),
        "command": "materialize_steps",
        "steps": steps,
    }


def _handle_command(cmd: Dict[str, Any]) -> Any:
    command = str(cmd.get("command") or "").strip()
    if command == "shutdown":
        return "shutdown"
    handlers = {
        "list_plugins": _handle_list_plugins,
        "build_payload": _handle_build_payload,
        "normalize_values": _handle_normalize_values,
        "materialize_steps": _handle_materialize_steps,
        "build_queue_status_view": _handle_build_queue_status_view,
        "build_active_job_strip_view": _handle_build_active_job_strip_view,
        "format_generation_exif_comment": _handle_format_generation_exif_comment,
        "write_generation_exif": _handle_write_generation_exif,
        "get_exif_user_description": _handle_get_exif_user_description,
        "write_exif_user_comment": _handle_write_exif_user_comment,
        "delete_exif_user_comment": _handle_delete_exif_user_comment,
        "thumbnail_paths": _handle_thumbnail_paths,
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
