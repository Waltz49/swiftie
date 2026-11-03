#!/usr/bin/env python3
"""Per-base-model LoRA catalog state (load, migrate, defaults).

User catalog state is persisted in ~/.prowser/data/lora_catalog.json via
lora_catalog_store.py so it can be backed up separately from settings.json.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any, Dict, FrozenSet, Iterable, List, Optional, Tuple

from imagegen_plugins.lora_entry import FluxLoraEntry

from imagegen_plugins.lora_entry import DEFAULT_ENABLED_LORA_IDS_BY_HOST
from imagegen_plugins.lora_host_registry import LORA_HOST_ORDER
from imagegen_plugins.lora_model_registry import (
    LORA_SETTINGS_MODEL_ORDER,
    entry_matches_lora_model,
    lora_models_for_entry,
)

from imagegen_plugins.lora_user_entries import USER_ENTRIES_KEY, user_lora_entries_from_lc

_LEGACY_HIDDEN_KEY = "hidden_ids"
_BY_HOST_KEY = "by_host"
_BY_MODEL_KEY = "by_model"
ENTRY_OVERRIDES_KEY = "entry_overrides"
USER_PRESET_KEY = "lora_user_preset"
DELETED_IDS_KEY = "deleted_ids"
PROBE_HISTORY_KEY = "probe_history"
CROSS_FAMILY_MODELS_KEY = "cross_family_models"


def _empty_slice() -> Dict[str, List[str]]:
    return {"enabled_ids": [], DELETED_IDS_KEY: []}


def _slice_deleted_ids(slice_: Dict[str, Any]) -> List[str]:
    """Read deleted ids from a model/host slice, migrating legacy hidden_ids."""
    deleted = slice_.get(DELETED_IDS_KEY)
    if isinstance(deleted, list) and deleted:
        return [str(x) for x in deleted]
    hidden = slice_.get(_LEGACY_HIDDEN_KEY)
    if isinstance(hidden, list):
        return [str(x) for x in hidden]
    return []


def entry_overrides_from_lc(lc: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    raw = lc.get(ENTRY_OVERRIDES_KEY)
    if not isinstance(raw, dict):
        return {}
    return {
        str(lid): dict(raw_slice)
        for lid, raw_slice in raw.items()
        if isinstance(raw_slice, dict)
    }


def apply_entry_overrides(
    entry: FluxLoraEntry,
    overrides: Optional[Dict[str, Any]],
) -> FluxLoraEntry:
    if not overrides:
        return entry
    kwargs: Dict[str, Any] = {}
    if "display_name" in overrides:
        name = str(overrides.get("display_name") or "").strip()
        if name:
            kwargs["display_name"] = name
    if "trigger_word" in overrides:
        trigger = overrides.get("trigger_word")
        trigger_word = str(trigger).strip() if trigger else None
        kwargs["trigger_word"] = trigger_word or None
    if "scale" in overrides:
        try:
            kwargs["scale"] = float(overrides["scale"])
        except (TypeError, ValueError):
            pass
    if "best_guess" in overrides:
        try:
            kwargs["best_guess"] = float(overrides["best_guess"])
        except (TypeError, ValueError):
            pass
    if "comment" in overrides:
        comment = overrides.get("comment")
        kwargs["comment"] = str(comment).strip() if comment else None
    if "reference_prompt" in overrides:
        ref = overrides.get("reference_prompt")
        kwargs["reference_prompt"] = str(ref).strip() if ref else None
    if not kwargs:
        return entry
    return replace(entry, **kwargs)


def default_enabled_lora_ids_by_model() -> Dict[str, Tuple[str, ...]]:
    return {k: () for k in LORA_SETTINGS_MODEL_ORDER}


DEFAULT_ENABLED_LORA_IDS_BY_MODEL = default_enabled_lora_ids_by_model()


def default_by_host() -> Dict[str, Dict[str, List[str]]]:
    out: Dict[str, Dict[str, List[str]]] = {}
    for host_id in LORA_HOST_ORDER:
        enabled = list(DEFAULT_ENABLED_LORA_IDS_BY_HOST.get(host_id, ()))
        out[host_id] = {
            "enabled_ids": [],
            DELETED_IDS_KEY: [],
        }
    return out


def default_by_model() -> Dict[str, Dict[str, List[str]]]:
    out: Dict[str, Dict[str, List[str]]] = {}
    for model_key in LORA_SETTINGS_MODEL_ORDER:
        enabled = list(DEFAULT_ENABLED_LORA_IDS_BY_MODEL.get(model_key, ()))
        out[model_key] = {
            "enabled_ids": [],
            DELETED_IDS_KEY: [],
        }
    return out


def _catalog_for_lc(lc: Dict[str, Any]) -> Dict[str, FluxLoraEntry]:
    return dict(user_lora_entries_from_lc(lc))


def _normalize_host_slice(
    host_id: str,
    slice_: Dict[str, Any],
    catalog: Dict[str, Any],
) -> Dict[str, List[str]]:
    enabled = slice_.get("enabled_ids")
    return {
        "enabled_ids": [
            str(x)
            for x in (enabled if isinstance(enabled, list) else [])
            if str(x) in catalog and catalog[str(x)].host_id == host_id
        ],
        DELETED_IDS_KEY: _slice_deleted_ids(slice_),
    }


def _normalize_model_slice(
    model_key: str,
    slice_: Dict[str, Any],
    catalog: Dict[str, Any],
    model_support: Optional[Dict[str, Any]] = None,
) -> Dict[str, List[str]]:
    ms = model_support if isinstance(model_support, dict) else {}
    enabled = slice_.get("enabled_ids")
    deleted_raw = _slice_deleted_ids(slice_)
    return {
        "enabled_ids": [
            str(x)
            for x in (enabled if isinstance(enabled, list) else [])
            if str(x) in catalog
            and entry_matches_lora_model(
                catalog[str(x)], model_key, model_support=ms
            )
        ],
        DELETED_IDS_KEY: [
            str(x)
            for x in deleted_raw
            if str(x) in catalog
            and entry_matches_lora_model(
                catalog[str(x)], model_key, model_support=ms
            )
        ],
    }


def _by_model_from_by_host(
    by_host: Dict[str, Dict[str, List[str]]],
    catalog: Dict[str, FluxLoraEntry],
) -> Dict[str, Dict[str, List[str]]]:
    """One-time migration: host enabled/hidden → per-target-model slices."""
    out = default_by_model()
    for host_id, slice_ in by_host.items():
        if not isinstance(slice_, dict):
            continue
        for lid in slice_.get("enabled_ids") or []:
            entry = catalog.get(str(lid))
            if entry is None:
                continue
            for mk in lora_models_for_entry(entry):
                if str(lid) not in out[mk]["enabled_ids"]:
                    out[mk]["enabled_ids"].append(str(lid))
        for lid in _slice_deleted_ids(slice_):
            entry = catalog.get(str(lid))
            if entry is None:
                continue
            for mk in lora_models_for_entry(entry):
                if str(lid) not in out[mk][DELETED_IDS_KEY]:
                    out[mk][DELETED_IDS_KEY].append(str(lid))
    return out


def _ensure_by_model(lc: Dict[str, Any], by_host: Dict[str, Dict[str, List[str]]]) -> None:
    catalog = _catalog_for_lc(lc)
    ms = lc.get("model_support") if isinstance(lc.get("model_support"), dict) else {}
    if _BY_MODEL_KEY not in lc:
        lc[_BY_MODEL_KEY] = _by_model_from_by_host(by_host, catalog)
    by_model = dict(lc.get(_BY_MODEL_KEY) or {})
    for model_key in LORA_SETTINGS_MODEL_ORDER:
        slice_ = by_model.get(model_key)
        if not isinstance(slice_, dict):
            by_model[model_key] = {
                "enabled_ids": [],
                DELETED_IDS_KEY: [],
            }
        else:
            by_model[model_key] = _normalize_model_slice(
                model_key, slice_, catalog, model_support=ms
            )
    lc[_BY_MODEL_KEY] = by_model


def _normalize_probe_history_slice(raw: Dict[str, Any]) -> Dict[str, Any]:
    md5 = str(raw.get("md5") or "").strip().lower()
    if not md5:
        return {}
    try:
        mtime = float(raw.get("mtime"))
    except (TypeError, ValueError):
        return {}
    try:
        size = int(raw.get("size"))
    except (TypeError, ValueError):
        return {}
    path = str(raw.get("path") or "").strip()
    models_raw = raw.get("model_support")
    model_support = (
        [str(m) for m in models_raw if str(m)]
        if isinstance(models_raw, (list, tuple))
        else []
    )
    complete = raw.get("complete")
    models_probed_raw = raw.get("models_probed")
    models_probed = (
        [str(m) for m in models_probed_raw if str(m)]
        if isinstance(models_probed_raw, (list, tuple))
        else []
    )
    return {
        "md5": md5,
        "mtime": mtime,
        "size": size,
        "path": path,
        "model_support": model_support,
        "models_probed": models_probed,
        "complete": complete is True,
    }


def normalize_probe_history(raw: Any) -> Dict[str, Dict[str, Any]]:
    if not isinstance(raw, dict):
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for key, slice_ in raw.items():
        key_s = str(key).strip()
        if not key_s or not isinstance(slice_, dict):
            continue
        normalized = _normalize_probe_history_slice(slice_)
        if normalized:
            out[key_s] = normalized
    return out


def probe_history_from_lc(lc: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return normalize_probe_history(lc.get(PROBE_HISTORY_KEY))


def _merge_model_catalog_slices(into: Dict[str, Any], from_: Dict[str, Any]) -> None:
    for key in ("enabled_ids", DELETED_IDS_KEY):
        merged: List[str] = []
        seen: set[str] = set()
        for x in list(into.get(key) or []) + list(from_.get(key) or []):
            xs = str(x)
            if xs not in seen:
                seen.add(xs)
                merged.append(xs)
        into[key] = merged


def _remap_legacy_z_image_model_id(model_id: str, *, canonical: str, legacy_ids: FrozenSet[str]) -> str:
    mid = str(model_id or "").strip()
    return canonical if mid in legacy_ids else mid


def _remap_legacy_z_image_model_list(
    models: List[str], *, canonical: str, legacy_ids: FrozenSet[str]
) -> List[str]:
    out: List[str] = []
    seen: set[str] = set()
    for m in models:
        mid = _remap_legacy_z_image_model_id(str(m), canonical=canonical, legacy_ids=legacy_ids)
        if mid not in seen:
            seen.add(mid)
            out.append(mid)
    return out


def _migrate_legacy_z_image_lora_catalog(lc: Dict[str, Any]) -> None:
    """Merge per-model LoRA state from removed Z-Image HF repos into Tongyi-MAI/Z-Image-Turbo."""
    from imagegen_plugins.hf_model_ids import LEGACY_Z_IMAGE_MFLUX_HF_IDS, Z_IMAGE_TURBO

    legacy = frozenset(LEGACY_Z_IMAGE_MFLUX_HF_IDS)

    by_model = lc.get(_BY_MODEL_KEY)
    if isinstance(by_model, dict):
        target = by_model.get(Z_IMAGE_TURBO)
        if not isinstance(target, dict):
            target = _empty_slice()
            by_model[Z_IMAGE_TURBO] = target
        for legacy_key in legacy:
            if legacy_key == Z_IMAGE_TURBO:
                continue
            slice_ = by_model.pop(legacy_key, None)
            if isinstance(slice_, dict):
                _merge_model_catalog_slices(target, slice_)
        lc[_BY_MODEL_KEY] = by_model

    raw_ms = lc.get("model_support")
    if isinstance(raw_ms, dict):
        for lid, models in list(raw_ms.items()):
            if isinstance(models, list):
                raw_ms[lid] = _remap_legacy_z_image_model_list(
                    [str(m) for m in models],
                    canonical=Z_IMAGE_TURBO,
                    legacy_ids=legacy,
                )

    cfm = lc.get(CROSS_FAMILY_MODELS_KEY)
    if isinstance(cfm, dict):
        for lid, models in list(cfm.items()):
            if isinstance(models, list):
                cfm[lid] = _remap_legacy_z_image_model_list(
                    [str(m) for m in models],
                    canonical=Z_IMAGE_TURBO,
                    legacy_ids=legacy,
                )

    ph = lc.get(PROBE_HISTORY_KEY)
    if isinstance(ph, dict):
        for entry in ph.values():
            if not isinstance(entry, dict):
                continue
            for key in ("model_support", "models_probed"):
                raw = entry.get(key)
                if isinstance(raw, list):
                    entry[key] = _remap_legacy_z_image_model_list(
                        [str(m) for m in raw],
                        canonical=Z_IMAGE_TURBO,
                        legacy_ids=legacy,
                    )



def _entry_from_lc(lc: Dict[str, Any], lora_id: str) -> Optional[FluxLoraEntry]:
    """Resolve a catalog entry from ``lc`` without re-running migrate (avoids recursion)."""
    entry = _catalog_for_lc(lc).get(str(lora_id))
    if entry is None:
        return None
    overrides = entry_overrides_from_lc(lc).get(str(lora_id))
    return apply_entry_overrides(entry, overrides)


def _split_model_support_cross_family(lc: Dict[str, Any]) -> None:
    """
    Keep only same-host probe passes in model_support.

    Legacy catalogs stored cross-host passes in model_support. Cross-host keys
    are removed from model_support; matching cross_family_models entries from
    that legacy data are dropped (fresh cross passes come from Test LoRAs only).
    """
    raw_ms = lc.get("model_support")
    if not isinstance(raw_ms, dict) or not raw_ms:
        return
    from imagegen_plugins.lora_model_registry import (
        is_cross_family_lora_model,
        same_host_supported_models,
    )

    cf = lc.get(CROSS_FAMILY_MODELS_KEY)
    if not isinstance(cf, dict):
        cf = {}
        lc[CROSS_FAMILY_MODELS_KEY] = cf

    new_ms: Dict[str, Any] = {}
    for lid, models in raw_ms.items():
        lid_s = str(lid)
        if not isinstance(models, list):
            continue
        supported = [str(m) for m in models]
        entry = _entry_from_lc(lc, lid_s)
        if entry is None:
            new_ms[lid_s] = supported
            continue
        same_host = list(same_host_supported_models(entry, supported))
        new_ms[lid_s] = same_host
        if set(supported) != set(same_host):
            cf.pop(lid_s, None)
    lc["model_support"] = new_ms

    for lid_s, cross_list in list(cf.items()):
        entry = _entry_from_lc(lc, str(lid_s))
        raw_list = raw_ms.get(lid_s) or raw_ms.get(str(lid_s))
        raw_supported = (
            [str(m) for m in raw_list] if isinstance(raw_list, list) else []
        )
        ms_list = new_ms.get(str(lid_s), [])
        if entry is None or not isinstance(cross_list, list):
            cf.pop(lid_s, None)
            continue
        kept: List[str] = []
        for model_key in cross_list:
            mk = str(model_key)
            if not is_cross_family_lora_model(entry, mk):
                continue
            if mk in raw_supported and mk not in ms_list:
                continue
            kept.append(mk)
        if kept:
            cf[lid_s] = kept
        else:
            cf.pop(lid_s, None)


def _probe_history_probed_keys(
    history_slice: Dict[str, Any],
    *,
    allowed: Optional[Iterable[str]] = None,
) -> FrozenSet[str]:
    """Model keys recorded as probed in a probe_history slice."""
    allowed_set = {str(m) for m in allowed} if allowed is not None else None
    raw = history_slice.get("models_probed")
    if isinstance(raw, list) and raw:
        out = {str(m) for m in raw if str(m)}
        if allowed_set is not None:
            out &= allowed_set
        return frozenset(out)
    return frozenset()


def _sanitize_probe_history_model_support(lc: Dict[str, Any]) -> None:
    """Strip cross-host keys from probe_history model_support (skip-unchanged cache)."""
    ph = lc.get(PROBE_HISTORY_KEY)
    if not isinstance(ph, dict) or not ph:
        return
    from imagegen_plugins.lora_model_registry import same_host_supported_models

    for hist_key, slice_ in ph.items():
        if not isinstance(slice_, dict):
            continue
        raw = slice_.get("model_support")
        if not isinstance(raw, list):
            continue
        lid_s = str(hist_key)
        if lid_s.startswith("md5:"):
            continue
        entry = _entry_from_lc(lc, lid_s)
        if entry is None:
            continue
        same_host = list(
            same_host_supported_models(entry, [str(m) for m in raw])
        )
        probed = _probe_history_probed_keys(slice_)
        if probed:
            same_host = [m for m in same_host if m in probed]
        slice_["model_support"] = same_host


def _trim_model_support_to_probe_history(lc: Dict[str, Any]) -> None:
    """Drop model_support keys that probe_history never probed on this LoRA file."""
    ph = lc.get(PROBE_HISTORY_KEY)
    ms = lc.get("model_support")
    if not isinstance(ph, dict) or not ph or not isinstance(ms, dict):
        return
    for lid_s, models in list(ms.items()):
        if not isinstance(models, list):
            continue
        hist = ph.get(lid_s) or ph.get(str(lid_s))
        if not isinstance(hist, dict):
            continue
        probed = _probe_history_probed_keys(hist)
        if not probed:
            continue
        ms[lid_s] = [str(m) for m in models if str(m) in probed]


def _prune_by_model_enabled_to_probe_support(lc: Dict[str, Any]) -> None:
    raw_ms = lc.get("model_support")
    if not isinstance(raw_ms, dict):
        return
    cf = lc.get(CROSS_FAMILY_MODELS_KEY)
    if not isinstance(cf, dict):
        cf = {}
    by_model = lc.get(_BY_MODEL_KEY)
    if not isinstance(by_model, dict):
        return
    for mk, slice_ in by_model.items():
        if not isinstance(slice_, dict):
            continue
        enabled = slice_.get("enabled_ids")
        if not isinstance(enabled, list):
            continue
        kept = [
            str(lid)
            for lid in enabled
            if mk in raw_ms.get(str(lid), ())
            or mk in cf.get(str(lid), ())
        ]
        slice_["enabled_ids"] = kept


def migrate_lora_catalog(lc: Dict[str, Any]) -> Dict[str, Any]:
    """Ensure by_host + by_model exist with normalized slices."""
    if not isinstance(lc, dict):
        lc = {}

    from imagegen_plugins.lora_disk_first_migration import migrate_disk_first_catalog_if_needed

    lc, _disk_migrated = migrate_disk_first_catalog_if_needed(lc)

    had_by_host = _BY_HOST_KEY in lc and isinstance(lc.get(_BY_HOST_KEY), dict)
    if had_by_host:
        by_host = dict(lc[_BY_HOST_KEY])
    else:
        by_host = default_by_host()

    for host_id in LORA_HOST_ORDER:
        slice_ = by_host.get(host_id)
        if not isinstance(slice_, dict):
            by_host[host_id] = dict(default_by_host().get(host_id, _empty_slice()))
        else:
            by_host[host_id] = _normalize_host_slice(host_id, slice_, _catalog_for_lc(lc))

    lc[_BY_HOST_KEY] = by_host
    _migrate_legacy_z_image_lora_catalog(lc)
    _ensure_by_model(lc, by_host)
    if USER_ENTRIES_KEY not in lc:
        lc[USER_ENTRIES_KEY] = {}
    elif not isinstance(lc.get(USER_ENTRIES_KEY), dict):
        lc[USER_ENTRIES_KEY] = {}
    if CROSS_FAMILY_MODELS_KEY not in lc:
        lc[CROSS_FAMILY_MODELS_KEY] = {}
    elif not isinstance(lc.get(CROSS_FAMILY_MODELS_KEY), dict):
        lc[CROSS_FAMILY_MODELS_KEY] = {}
    if ENTRY_OVERRIDES_KEY not in lc:
        lc[ENTRY_OVERRIDES_KEY] = {}
    elif not isinstance(lc.get(ENTRY_OVERRIDES_KEY), dict):
        lc[ENTRY_OVERRIDES_KEY] = {}
    lc[PROBE_HISTORY_KEY] = probe_history_from_lc(lc)
    _split_model_support_cross_family(lc)
    _sanitize_probe_history_model_support(lc)
    _trim_model_support_to_probe_history(lc)
    _prune_by_model_enabled_to_probe_support(lc)
    return lc


def lora_catalog_from_settings(settings: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if settings is not None:
        imagegen = settings.get("imagegen") or {}
        lc = imagegen.get("lora_catalog")
        if isinstance(lc, dict) and lc:
            return migrate_lora_catalog(dict(lc))
    from imagegen_plugins.lora_catalog_store import load_lora_catalog_file

    return load_lora_catalog_file()


def model_state(
    settings: Optional[Dict[str, Any]] = None,
    model_key: str = "",
) -> Dict[str, List[str]]:
    lc = lora_catalog_from_settings(settings)
    by_model = lc.get(_BY_MODEL_KEY) or {}
    slice_ = by_model.get(model_key)
    if not isinstance(slice_, dict):
        return _empty_slice()
    return {
        "enabled_ids": list(slice_.get("enabled_ids") or []),
        DELETED_IDS_KEY: list(_slice_deleted_ids(slice_)),
    }


def deleted_lora_ids_for_model(
    model_key: str,
    settings: Optional[Dict[str, Any]] = None,
    *,
    draft_by_model: Optional[Dict[str, Any]] = None,
) -> FrozenSet[str]:
    if isinstance(draft_by_model, dict) and model_key in draft_by_model:
        slice_ = draft_by_model.get(model_key)
        if isinstance(slice_, dict):
            return frozenset(_slice_deleted_ids(slice_))
    return frozenset(model_state(settings, model_key)[DELETED_IDS_KEY])


def hidden_lora_ids_for_model(
    model_key: str,
    settings: Optional[Dict[str, Any]] = None,
) -> FrozenSet[str]:
    """Back-compat alias for deleted_lora_ids_for_model."""
    return deleted_lora_ids_for_model(model_key, settings)


def enabled_lora_ids_for_model(
    model_key: str,
    settings: Optional[Dict[str, Any]] = None,
) -> Tuple[str, ...]:
    lc = lora_catalog_from_settings(settings)
    by_model = lc.get(_BY_MODEL_KEY) or {}
    slice_ = by_model.get(model_key)
    if not isinstance(slice_, dict):
        return ()
    catalog = _catalog_for_lc(lc)
    ms = lc.get("model_support") if isinstance(lc.get("model_support"), dict) else {}
    return tuple(
        str(x)
        for x in (slice_.get("enabled_ids") or [])
        if str(x) in catalog
        and entry_matches_lora_model(
            catalog[str(x)], model_key, model_support=ms
        )
    )




