#!/usr/bin/env python3
"""One-time migration from built-in LoRA catalog to disk-first user entries."""

from __future__ import annotations

from dataclasses import replace
from typing import Any, Dict, List, Tuple

from imagegen_plugins.lora_builtin_migration import legacy_lora_catalog
from imagegen_plugins.lora_catalog import local_lora_weights_path
from imagegen_plugins.lora_catalog_settings import (
    ENTRY_OVERRIDES_KEY,
    PROBE_HISTORY_KEY,
    apply_entry_overrides,
    entry_overrides_from_lc,
)
from imagegen_plugins.lora_model_registry import lora_models_for_entry
from imagegen_plugins.lora_user_entries import (
    USER_ENTRIES_KEY,
    _entry_to_dict,
    slugify_lora_id,
    unique_lora_id,
    user_lora_entries_from_lc,
)

CATALOG_SCHEMA_KEY = "catalog_schema"
DISK_FIRST_SCHEMA = "disk_first_v1"


def _remap_id_lists(ids: List[str], id_map: Dict[str, str], catalog_ids: set[str]) -> List[str]:
    out: List[str] = []
    seen: set[str] = set()
    for raw in ids:
        lid = str(raw)
        new_id = id_map.get(lid, lid)
        if new_id not in catalog_ids:
            continue
        if new_id in seen:
            continue
        seen.add(new_id)
        out.append(new_id)
    return out


def migrate_disk_first_catalog_if_needed(lc: Dict[str, Any]) -> Tuple[Dict[str, Any], bool]:
    """
    Migrate built-in catalog IDs and entry_overrides into user_entries for on-disk weights.
    Returns (lc, changed).
    """
    if not isinstance(lc, dict):
        lc = {}
    if lc.get(CATALOG_SCHEMA_KEY) == DISK_FIRST_SCHEMA:
        return lc, False

    changed = False
    legacy = legacy_lora_catalog()
    overrides = entry_overrides_from_lc(lc)
    raw_user = dict(lc.get(USER_ENTRIES_KEY) or {})
    existing_entries: Dict[str, Dict[str, Any]] = {
        k: dict(v) for k, v in raw_user.items() if isinstance(v, dict)
    }
    id_map: Dict[str, str] = {}

    existing_flux = user_lora_entries_from_lc({USER_ENTRIES_KEY: existing_entries})

    for old_id, entry in legacy.items():
        path = local_lora_weights_path(old_id, entry=entry)
        if path is None:
            continue
        merged_entry = apply_entry_overrides(entry, overrides.get(old_id))
        base_id = slugify_lora_id(merged_entry.display_name or old_id)
        new_id = unique_lora_id(base_id, existing_flux)
        models = list(lora_models_for_entry(merged_entry))
        base_hf = models[0] if models else merged_entry.base_hf_model_id
        user_entry = replace(
            merged_entry,
            lora_id=new_id,
            local_path=str(path),
            source_path=str(path),
            base_hf_model_id=base_hf,
        )
        existing_entries[new_id] = _entry_to_dict(user_entry)
        existing_flux[new_id] = user_entry
        id_map[old_id] = new_id
        changed = True

    lc[CATALOG_SCHEMA_KEY] = DISK_FIRST_SCHEMA
    changed = True

    if id_map:
        lc[USER_ENTRIES_KEY] = existing_entries
        new_overrides = {
            k: v for k, v in overrides.items() if k not in id_map and k not in legacy
        }
        lc[ENTRY_OVERRIDES_KEY] = new_overrides

        catalog_id_set = set(existing_entries.keys())

        for key in ("by_host", "by_model"):
            slices = lc.get(key)
            if not isinstance(slices, dict):
                continue
            new_slices: Dict[str, Any] = {}
            for slice_key, slice_ in slices.items():
                if not isinstance(slice_, dict):
                    continue
                enabled = _remap_id_lists(
                    list(slice_.get("enabled_ids") or []),
                    id_map,
                    catalog_id_set,
                )
                deleted = _remap_id_lists(
                    list(slice_.get("deleted_ids") or slice_.get("hidden_ids") or []),
                    id_map,
                    catalog_id_set,
                )
                new_slices[slice_key] = {
                    "enabled_ids": enabled,
                    "deleted_ids": deleted,
                }
            lc[key] = new_slices

        ms = lc.get("model_support")
        if isinstance(ms, dict):
            lc["model_support"] = {
                id_map.get(str(lid), str(lid)): models
                for lid, models in ms.items()
                if id_map.get(str(lid), str(lid)) in catalog_id_set
            }

        hist = lc.get(PROBE_HISTORY_KEY)
        if isinstance(hist, dict):
            new_hist: Dict[str, Any] = {}
            for key, slice_ in hist.items():
                if not isinstance(slice_, dict):
                    continue
                text = str(key)
                new_key = id_map.get(text, text)
                if new_key in catalog_id_set or text.startswith("md5:"):
                    new_hist[new_key] = slice_
            lc[PROBE_HISTORY_KEY] = new_hist

    return lc, changed
