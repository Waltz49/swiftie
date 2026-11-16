#!/usr/bin/env python3
"""Filter a on-disk lora_catalog.json into a portable defaults payload for lorablob."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

REPO = Path(__file__).resolve().parents[1]
IMAGEGEN = REPO / "ImageGenPython"
if str(IMAGEGEN) not in sys.path:
    sys.path.insert(0, str(IMAGEGEN))

from imagegen_plugins.lora_builtin_migration import legacy_lora_catalog  # noqa: E402
from imagegen_plugins.lora_catalog import has_recovery_source  # noqa: E402
from imagegen_plugins.lora_catalog_settings import (  # noqa: E402
    DELETED_IDS_KEY,
    ENTRY_OVERRIDES_KEY,
    PROBE_HISTORY_KEY,
    apply_entry_overrides,
    entry_overrides_from_lc,
    migrate_lora_catalog,
)
from imagegen_plugins.lora_entry import FluxLoraEntry, LORA_MIN_STEPS  # noqa: E402
from imagegen_plugins.lora_user_entries import (  # noqa: E402
    USER_ENTRIES_KEY,
    _entry_to_dict,
    entry_from_dict,
    user_entries_raw,
    user_lora_entries_from_lc,
)

CATALOG_SCHEMA_KEY = "catalog_schema"
BY_HOST_KEY = "by_host"
BY_MODEL_KEY = "by_model"
CROSS_FAMILY_MODELS_KEY = "cross_family_models"
MODEL_SUPPORT_KEY = "model_support"


def _default_catalog_path() -> Path:
    return Path.home() / ".swift-prowser" / "data" / "lora_catalog.json"


def _is_http_url(value: str) -> bool:
    text = (value or "").strip().lower()
    return text.startswith("http://") or text.startswith("https://")


def _sanitize_user_entry(raw: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(raw)
    local = str(out.get("local_path") or "").strip()
    if local and not _is_http_url(local):
        out.pop("local_path", None)
    elif local and _is_http_url(local):
        out["local_path"] = local
    return out


def _flux_from_raw_relaxed(raw: Dict[str, Any]) -> Optional[FluxLoraEntry]:
    """Parse a persisted user_entries blob (export: any lora_id; local_path optional)."""
    if not isinstance(raw, dict):
        return None
    lora_id = str(raw.get("lora_id") or "").strip()
    if not lora_id:
        return None
    host_id = str(raw.get("host_id") or "").strip()
    display_name = str(raw.get("display_name") or lora_id).strip()
    base_hf = str(raw.get("base_hf_model_id") or "").strip()
    if not host_id or not base_hf:
        return None
    local_path = str(raw.get("local_path") or "").strip() or None
    trigger = raw.get("trigger_word")
    trigger_word = str(trigger).strip() if trigger else None
    if trigger_word == "":
        trigger_word = None
    comment_raw = raw.get("comment")
    comment = str(comment_raw).strip() if comment_raw else None
    if comment == "":
        comment = None
    ref_raw = raw.get("reference_prompt")
    reference_prompt = str(ref_raw).strip() if ref_raw else None
    if reference_prompt == "":
        reference_prompt = None
    mflux_raw = raw.get("mflux_compatible")
    mflux_compatible = mflux_raw if isinstance(mflux_raw, bool) else None
    try:
        scale = float(raw.get("scale", 1.0))
    except (TypeError, ValueError):
        scale = 1.0
    try:
        best_guess = float(raw.get("best_guess", 1.0))
    except (TypeError, ValueError):
        best_guess = 1.0
    try:
        min_steps = int(raw.get("min_steps", LORA_MIN_STEPS))
    except (TypeError, ValueError):
        min_steps = LORA_MIN_STEPS
    source_raw = raw.get("source_path")
    source_path = str(source_raw).strip() if source_raw else None
    if source_path == "":
        source_path = None
    origin_raw = raw.get("safetensors_origin")
    safetensors_origin = str(origin_raw).strip() if origin_raw else None
    if safetensors_origin == "":
        safetensors_origin = None
    web_raw = raw.get("web_page_url")
    web_page_url = str(web_raw).strip() if web_raw else None
    if web_page_url == "":
        web_page_url = None
    return FluxLoraEntry(
        host_id=host_id,
        lora_id=lora_id,
        display_name=display_name,
        repo_id=str(raw.get("repo_id") or ""),
        filename=str(raw.get("filename") or ""),
        scale=scale,
        best_guess=best_guess,
        local_path=local_path,
        base_hf_model_id=base_hf,
        min_steps=min_steps,
        mflux_compatible=mflux_compatible,
        trigger_word=trigger_word,
        comment=comment,
        reference_prompt=reference_prompt,
        source_path=source_path,
        safetensors_origin=safetensors_origin,
        web_page_url=web_page_url,
    )


def _collect_referenced_lora_ids(lc: Dict[str, Any]) -> Set[str]:
    ids: Set[str] = {str(k).strip() for k in user_entries_raw(lc).keys() if str(k).strip()}
    for container_key in (BY_HOST_KEY, BY_MODEL_KEY):
        slices = lc.get(container_key)
        if not isinstance(slices, dict):
            continue
        for slice_ in slices.values():
            if not isinstance(slice_, dict):
                continue
            for list_key in ("enabled_ids", DELETED_IDS_KEY):
                raw = slice_.get(list_key)
                if not isinstance(raw, list):
                    continue
                for item in raw:
                    lid = str(item).strip()
                    if lid:
                        ids.add(lid)
    overrides = lc.get(ENTRY_OVERRIDES_KEY)
    if isinstance(overrides, dict):
        ids.update(str(k).strip() for k in overrides if str(k).strip())
    for map_key in (MODEL_SUPPORT_KEY, CROSS_FAMILY_MODELS_KEY):
        raw = lc.get(map_key)
        if isinstance(raw, dict):
            ids.update(str(k).strip() for k in raw if str(k).strip())
    return ids


def _resolve_export_entry(lc: Dict[str, Any], lora_id: str) -> Optional[FluxLoraEntry]:
    lid = str(lora_id).strip()
    if not lid:
        return None
    overrides = entry_overrides_from_lc(lc).get(lid)
    entry: Optional[FluxLoraEntry] = None
    raw = user_entries_raw(lc).get(lid)
    if isinstance(raw, dict):
        entry = entry_from_dict(raw)
        if entry is None:
            entry = _flux_from_raw_relaxed(raw)
    if entry is None:
        entry = user_lora_entries_from_lc(lc).get(lid)
    if entry is None:
        entry = legacy_lora_catalog().get(lid)
    if entry is None:
        return None
    return apply_entry_overrides(entry, overrides)


def _filter_id_list(ids: Any, allowed: Set[str]) -> List[str]:
    if not isinstance(ids, list):
        return []
    out: List[str] = []
    seen: set[str] = set()
    for raw in ids:
        lid = str(raw).strip()
        if not lid or lid not in allowed:
            continue
        if lid in seen:
            continue
        seen.add(lid)
        out.append(lid)
    return out


def _filter_slices(slices: Any, allowed: Set[str]) -> Dict[str, Any]:
    if not isinstance(slices, dict):
        return {}
    out: Dict[str, Any] = {}
    for key, slice_ in slices.items():
        if not isinstance(slice_, dict):
            continue
        out[str(key)] = {
            "enabled_ids": _filter_id_list(slice_.get("enabled_ids"), allowed),
            DELETED_IDS_KEY: _filter_id_list(slice_.get(DELETED_IDS_KEY), allowed),
        }
    return out


def _filter_id_map(raw: Any, allowed: Set[str]) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    return {str(k): v for k, v in raw.items() if str(k) in allowed}


def export_lora_defaults(lc: Dict[str, Any]) -> Dict[str, Any]:
    lc = migrate_lora_catalog(dict(lc))
    user_entries: Dict[str, Any] = {}
    for lid in sorted(_collect_referenced_lora_ids(lc)):
        entry = _resolve_export_entry(lc, lid)
        if entry is None or not has_recovery_source(entry):
            continue
        user_entries[lid] = _sanitize_user_entry(_entry_to_dict(entry))

    allowed = set(user_entries.keys())

    entry_overrides = _filter_id_map(lc.get(ENTRY_OVERRIDES_KEY), allowed)
    cross_family = _filter_id_map(lc.get(CROSS_FAMILY_MODELS_KEY), allowed)
    model_support = _filter_id_map(lc.get(MODEL_SUPPORT_KEY), allowed)

    out: Dict[str, Any] = {}
    if CATALOG_SCHEMA_KEY in lc:
        out[CATALOG_SCHEMA_KEY] = lc[CATALOG_SCHEMA_KEY]
    out[USER_ENTRIES_KEY] = user_entries
    out[BY_HOST_KEY] = _filter_slices(lc.get(BY_HOST_KEY), allowed)
    out[BY_MODEL_KEY] = _filter_slices(lc.get(BY_MODEL_KEY), allowed)
    if entry_overrides:
        out[ENTRY_OVERRIDES_KEY] = entry_overrides
    if cross_family:
        out[CROSS_FAMILY_MODELS_KEY] = cross_family
    if model_support:
        out[MODEL_SUPPORT_KEY] = model_support
    # probe_history intentionally omitted (machine-specific).
    if PROBE_HISTORY_KEY in lc:
        pass
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "catalog",
        nargs="?",
        type=Path,
        default=_default_catalog_path(),
        help="lora_catalog.json (default: ~/.swift-prowser/data/lora_catalog.json)",
    )
    args = parser.parse_args()
    path: Path = args.catalog
    try:
        raw_text = path.read_text(encoding="utf-8")
        data = json.loads(raw_text)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: could not read catalog {path}: {exc}", file=sys.stderr)
        return 1
    if not isinstance(data, dict):
        print("error: catalog root must be a JSON object", file=sys.stderr)
        return 1

    payload = export_lora_defaults(data)
    json.dump(payload, sys.stdout, separators=(",", ":"), ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())