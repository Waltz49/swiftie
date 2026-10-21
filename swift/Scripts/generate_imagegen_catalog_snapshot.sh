#!/usr/bin/env bash
# Regenerate Prowser/Resources/ImageGenPluginCatalogSnapshot.json from ImageGenPython.
set -euo pipefail

usage() {
    cat <<EOF
$(basename "$0") — write ImageGenPluginCatalogSnapshot.json from vendored Python plugins.

Runs discover_plugins() under swift/ImageGenPython and overwrites
Prowser/Resources/ImageGenPluginCatalogSnapshot.json (field layouts, defaults, availability).

Usage: $(basename "$0")

Options:
  -h, --help    Show this help

Prereq: sync_imagegen_python.sh (ImageGenPython bundle populated).
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ImageGenPython"
PYTHONPATH=. python3 <<'PY'
import json
from imagegen_plugins import discover_plugins
from imagegen_plugins.image_gen_dim_limits import effective_max_for_plugin
from imagegen_plugins.image_gen_fields import FieldGroup, FieldSpec, FieldNode


def field_spec_to_dict(spec: FieldSpec) -> dict:
    out = {
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


def field_node_to_dict(node: FieldNode) -> dict:
    if isinstance(node, FieldSpec):
        return {"type": "field", "spec": field_spec_to_dict(node)}
    return {
        "type": "group",
        "layout": node.layout,
        "label": node.label,
        "children": [field_node_to_dict(child) for child in node.children],
    }


def plugin_to_dict(plugin, saved=None):
    values = plugin.merged_values(saved)
    layout = ()
    if plugin.field_layout_builder:
        layout = plugin.field_layout_builder(
            plugin, values, effective_max_for_plugin(plugin)
        )
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
        "field_layout": [field_node_to_dict(node) for node in layout],
    }


plugins = [plugin_to_dict(p) for p in discover_plugins()]
out_path = "../Prowser/Resources/ImageGenPluginCatalogSnapshot.json"
with open(out_path, "w") as f:
    json.dump({"plugins": plugins}, f, indent=2, sort_keys=True)
print(f"Wrote {out_path} ({len(plugins)} plugins)")
PY
