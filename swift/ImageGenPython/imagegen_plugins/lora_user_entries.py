#!/usr/bin/env python3
"""User-imported LoRA entries persisted in settings (downloaded .safetensors files)."""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Any, Dict, Optional, Set

from imagegen_plugins.lora_entry import DEFAULT_CACHE, FluxLoraEntry, LORA_MIN_STEPS
from imagegen_plugins.lora_model_registry import host_id_for_lora_model

USER_ENTRIES_KEY = "user_entries"
USER_LORA_ID_PREFIX = "user_"
USER_LORA_CACHE_ROOT = DEFAULT_CACHE / "user"


def is_user_lora_id(lora_id: str) -> bool:
    return str(lora_id or "").startswith(USER_LORA_ID_PREFIX)


def _entry_to_dict(entry: FluxLoraEntry) -> Dict[str, Any]:
    return {
        "host_id": entry.host_id,
        "lora_id": entry.lora_id,
        "display_name": entry.display_name,
        "repo_id": entry.repo_id or "",
        "filename": entry.filename or "",
        "scale": float(entry.scale),
        "best_guess": float(entry.best_guess),
        "local_path": entry.local_path or "",
        "base_hf_model_id": entry.base_hf_model_id,
        "min_steps": int(entry.min_steps),
        "mflux_compatible": entry.mflux_compatible,
        "trigger_word": entry.trigger_word,
        "comment": entry.comment,
        "reference_prompt": entry.reference_prompt,
        "source_path": entry.source_path or "",
    }


def entry_from_dict(raw: Dict[str, Any]) -> Optional[FluxLoraEntry]:
    if not isinstance(raw, dict):
        return None
    lora_id = str(raw.get("lora_id") or "").strip()
    if not lora_id or not is_user_lora_id(lora_id):
        return None
    host_id = str(raw.get("host_id") or "").strip()
    display_name = str(raw.get("display_name") or lora_id).strip()
    local_path = str(raw.get("local_path") or "").strip()
    base_hf = str(raw.get("base_hf_model_id") or "").strip()
    if not host_id or not local_path or not base_hf:
        return None
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
    )


def user_entries_raw(lc: Dict[str, Any]) -> Dict[str, Any]:
    raw = lc.get(USER_ENTRIES_KEY)
    return dict(raw) if isinstance(raw, dict) else {}


def user_lora_entries_from_lc(lc: Dict[str, Any]) -> Dict[str, FluxLoraEntry]:
    out: Dict[str, FluxLoraEntry] = {}
    for lid, raw in user_entries_raw(lc).items():
        entry = entry_from_dict(raw if isinstance(raw, dict) else {})
        if entry is not None:
            out[str(lid)] = entry
    return out


def user_lora_entries_from_settings(
    settings: Optional[Dict[str, Any]] = None,
) -> Dict[str, FluxLoraEntry]:
    from imagegen_plugins.lora_catalog_settings import lora_catalog_from_settings

    lc = lora_catalog_from_settings(settings)
    return user_lora_entries_from_lc(lc)


def merged_lora_catalog(
    settings: Optional[Dict[str, Any]] = None,
) -> Dict[str, FluxLoraEntry]:
    return dict(user_lora_entries_from_settings(settings))


def display_name_from_path(path: Path) -> str:
    name = path.stem.strip()
    return name or "Imported LoRA"


def slugify_lora_id(name: str) -> str:
    slug = re.sub(r"[^\w]+", "_", (name or "").lower()).strip("_")
    if not slug:
        slug = "import"
    lid = f"{USER_LORA_ID_PREFIX}{slug}"
    if len(lid) > 64:
        lid = lid[:64].rstrip("_")
    return lid


def unique_lora_id(base: str, existing: Dict[str, FluxLoraEntry]) -> str:
    lid = base
    n = 2
    while lid in existing:
        suffix = f"_{n}"
        lid = (base[: max(1, 64 - len(suffix))] + suffix) if len(base) + len(suffix) > 64 else base + suffix
        n += 1
    return lid


def same_lora_file(a: Path, b: Path) -> bool:
    """True when two paths refer to the same on-disk LoRA file."""
    try:
        a_res = a.expanduser().resolve()
        b_res = b.expanduser().resolve()
        if a_res == b_res:
            return True
        if a_res.is_file() and b_res.is_file() and os.path.samefile(a_res, b_res):
            return True
    except OSError:
        pass
    return False


def _entry_path_candidates(entry: FluxLoraEntry) -> list[Path]:
    paths: list[Path] = []
    for raw in (entry.local_path, entry.source_path):
        text = str(raw or "").strip()
        if not text:
            continue
        paths.append(Path(text).expanduser())
    return paths


def lora_weights_content_digest(
    path: Path,
    *,
    digest_cache: Optional[Dict[Path, str]] = None,
    hash_sizes: Optional[Set[int]] = None,
) -> Optional[str]:
    """Stable digest for deduplicating the same .safetensors on disk.

    By default only byte size is used (fast). Pass ``hash_sizes`` from
    ``_size_conflict_set`` to MD5 files that share a size with another candidate.
    """
    from imagegen_plugins.lora_catalog import lora_weights_file_is_valid

    try:
        resolved = path.expanduser().resolve()
    except OSError:
        resolved = path.expanduser()
    if not lora_weights_file_is_valid(resolved):
        return None
    try:
        from imagegen_plugins.lora_compatibility_checker import _content_digest_for_path

        cache = digest_cache if digest_cache is not None else {}
        effective_sizes = hash_sizes if hash_sizes is not None else set()
        digest = _content_digest_for_path(
            resolved, cache, hash_sizes=effective_sizes
        )
    except Exception:
        return None
    if not digest:
        return None
    if digest.startswith("size:"):
        return digest
    return f"md5:{digest}"


def entry_weights_identity_key(
    entry: FluxLoraEntry,
    *,
    digest_cache: Optional[Dict[Path, str]] = None,
    hash_sizes: Optional[Set[int]] = None,
) -> str:
    """Dedup key for catalog rows (content hash when weights exist, else lora id)."""
    for candidate in _entry_path_candidates(entry):
        digest = lora_weights_content_digest(
            candidate, digest_cache=digest_cache, hash_sizes=hash_sizes
        )
        if digest:
            return digest
    return f"id:{entry.lora_id}"


def user_lora_weight_paths(
    settings: Optional[Dict[str, Any]] = None,
) -> list[Path]:
    paths: list[Path] = []
    for entry in user_lora_entries_from_settings(settings).values():
        for candidate in _entry_path_candidates(entry):
            paths.append(candidate)
    return paths


def discovered_path_matches_saved_user_lora(
    weight_path: Path,
    settings: Optional[Dict[str, Any]] = None,
    *,
    digest_cache: Optional[Dict[Path, str]] = None,
) -> bool:
    """True when a disk-discovered file is already a saved user LoRA (path or same bytes)."""
    cache = digest_cache if digest_cache is not None else {}
    same_size: list[Path] = []
    try:
        weight_size = int(weight_path.stat().st_size)
    except OSError:
        weight_size = None
    for entry in user_lora_entries_from_settings(settings).values():
        for candidate in _entry_path_candidates(entry):
            if same_lora_file(weight_path, candidate):
                return True
            if weight_size is not None:
                try:
                    if int(candidate.stat().st_size) == weight_size:
                        same_size.append(candidate)
                except OSError:
                    continue
    if not same_size:
        return False
    hash_sizes = {weight_size} if weight_size is not None else set()
    weight_digest = lora_weights_content_digest(
        weight_path, digest_cache=cache, hash_sizes=hash_sizes
    )
    if not weight_digest:
        return False
    for candidate in same_size:
        other = lora_weights_content_digest(
            candidate, digest_cache=cache, hash_sizes=hash_sizes
        )
        if other and other == weight_digest:
            return True
    return False


def find_user_lora_for_source(
    path: Path,
    *,
    host_id: str,
    settings: Optional[Dict[str, Any]] = None,
) -> Optional[FluxLoraEntry]:
    """Return an existing user LoRA entry that refers to the same weights file."""
    host = str(host_id or "").strip()
    if not host:
        return None
    try:
        source = path.expanduser().resolve()
    except OSError:
        source = path.expanduser()
    if not source.is_file():
        return None
    from imagegen_plugins.lora_compatibility_checker import _size_conflict_set

    compare_paths = [source]
    for entry in user_lora_entries_from_settings(settings).values():
        if entry.host_id != host:
            continue
        compare_paths.extend(_entry_path_candidates(entry))
    hash_sizes = _size_conflict_set(compare_paths)
    digest_cache: Dict[Path, str] = {}
    source_digest = lora_weights_content_digest(
        source, digest_cache=digest_cache, hash_sizes=hash_sizes
    )
    for entry in user_lora_entries_from_settings(settings).values():
        if entry.host_id != host:
            continue
        for candidate in _entry_path_candidates(entry):
            if same_lora_file(source, candidate):
                return entry
        if source_digest:
            for candidate in _entry_path_candidates(entry):
                other = lora_weights_content_digest(
                    candidate, digest_cache=digest_cache, hash_sizes=hash_sizes
                )
                if other and other == source_digest:
                    return entry
    return None


def copy_lora_to_user_cache(source: Path, lora_id: str) -> Path:
    dest_dir = USER_LORA_CACHE_ROOT / lora_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / source.name
    src = source.resolve()
    dst = dest.resolve()
    if src == dst:
        return dst
    shutil.copy2(source, dest)
    return dst


def build_user_lora_entry(
    *,
    source_path: Path,
    display_name: str,
    model_key: str,
    trigger_word: Optional[str] = None,
    scale: float = 1.0,
    best_guess: float = 1.0,
    comment: Optional[str] = None,
    reference_prompt: Optional[str] = None,
    repo_id: str = "",
    filename: str = "",
    settings: Optional[Dict[str, Any]] = None,
) -> FluxLoraEntry:
    host_id = host_id_for_lora_model(model_key)
    if not host_id:
        raise ValueError(f"LoRAs are not supported for model {model_key!r}.")
    existing = merged_lora_catalog(settings)
    base_id = slugify_lora_id(display_name or source_path.stem)
    lora_id = unique_lora_id(base_id, existing)
    resolved_source = source_path.resolve()
    dest = copy_lora_to_user_cache(source_path, lora_id)
    guess = float(best_guess)
    return FluxLoraEntry(
        host_id=host_id,
        lora_id=lora_id,
        display_name=(display_name or display_name_from_path(source_path)).strip(),
        repo_id=(repo_id or "").strip(),
        filename=(filename or "").strip(),
        local_path=str(dest),
        scale=float(scale),
        best_guess=guess,
        base_hf_model_id=model_key,
        min_steps=LORA_MIN_STEPS,
        mflux_compatible=None,
        trigger_word=(trigger_word or "").strip() or None,
        comment=(comment or "").strip() or None,
        reference_prompt=(reference_prompt or "").strip() or None,
        source_path=str(resolved_source),
    )


def reinstall_user_lora(entry: FluxLoraEntry) -> Path:
    """Re-copy or download weights for a user LoRA entry."""
    from imagegen_plugins.mflux_lora_presets import resolve_lora_path

    if (entry.repo_id or "").strip() and (entry.filename or "").strip():
        return Path(resolve_lora_path(entry.lora_id))
    source_text = (entry.source_path or "").strip()
    if not source_text:
        raise ValueError("No recovery source is configured for this LoRA.")
    if source_text.lower().startswith(("http://", "https://")):
        return _download_lora_from_url(source_text, entry)
    source = validate_safetensors_source(source_text)
    dest = copy_lora_to_user_cache(source, entry.lora_id)
    return dest


def _download_lora_from_url(url: str, entry: FluxLoraEntry) -> Path:
    from imagegen_plugins.civitai_client import download_url_to_path

    dest_dir = USER_LORA_CACHE_ROOT / entry.lora_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    filename = (entry.filename or "").strip()
    placeholder = dest_dir / (filename or f"{entry.lora_id}.safetensors")
    return download_url_to_path(
        url,
        placeholder,
        filename_hint=filename,
    )


def remove_user_lora_files(entry: FluxLoraEntry) -> None:
    path = Path(entry.local_path or "").expanduser()
    if path.is_file():
        try:
            path.unlink()
        except OSError:
            pass
    parent = path.parent
    if parent.is_dir() and parent.name == entry.lora_id:
        try:
            if not any(parent.iterdir()):
                parent.rmdir()
        except OSError:
            pass


def validate_safetensors_source(path: str) -> Path:
    from utils import display_to_path

    p = Path(display_to_path(str(path or "").strip()))
    if not p.is_file():
        raise FileNotFoundError(f"LoRA file not found: {path}")
    if p.suffix.lower() != ".safetensors":
        raise ValueError("Only .safetensors LoRA files are supported.")
    if p.stat().st_size < 1024:
        raise ValueError("LoRA file is too small to be valid.")
    return p.resolve()
