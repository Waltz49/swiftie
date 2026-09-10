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
