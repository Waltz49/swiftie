#!/usr/bin/env python3
"""Discover on-disk LoRA .safetensors under LoRA-specific cache roots (not HF hub)."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional, Set

from imagegen_plugins.lora_catalog import lora_weights_file_is_valid
from imagegen_plugins.lora_entry import DEFAULT_CACHE, _ALT_CACHE

DOWNLOADS_LORA_DIR = Path.home() / "Downloads"


def lora_weights_search_roots() -> List[Path]:
    """Directories scanned recursively for LoRA weight files."""
    roots: List[Path] = [
        DEFAULT_CACHE.expanduser(),
        _ALT_CACHE.expanduser(),
    ]
    try:
        from config import get_config

        profile_loras = get_config().cache_dir / "loras"
        roots.append(profile_loras.expanduser())
    except Exception:
        pass
    return roots


def lora_weights_search_roots_display() -> List[str]:
    """Human-readable search locations for UI / help text."""
    lines = [
        str(DEFAULT_CACHE.expanduser()),
        str(_ALT_CACHE.expanduser()),
    ]
    try:
        from config import get_config

        lines.append(str((get_config().cache_dir / "loras").expanduser()))
    except Exception:
        pass
    lines.append(f"{DOWNLOADS_LORA_DIR.expanduser()} (top-level *.safetensors only)")
    return lines


def downloads_safetensors_paths() -> List[Path]:
    """Top-level ~/Downloads/*.safetensors only (not recursive)."""
    root = DOWNLOADS_LORA_DIR.expanduser()
    if not root.is_dir():
        return []
    paths: List[Path] = []
    for child in sorted(root.iterdir()):
        if not child.is_file() or child.suffix.lower() != ".safetensors":
            continue
        try:
            paths.append(child.resolve())
        except OSError:
            paths.append(child)
    return paths


def _cache_safetensors_paths(root: Path) -> List[Path]:
    expanded = root.expanduser()
    if not expanded.is_dir():
        return []
    paths: List[Path] = []
    for path in sorted(expanded.rglob("*.safetensors")):
        if not path.is_file():
            continue
        if not lora_weights_file_is_valid(path):
            continue
        try:
            paths.append(path.resolve())
        except OSError:
            paths.append(path)
    return paths


def discover_lora_weight_paths(
    settings: Optional[dict] = None,
) -> List[Path]:
    """
    All valid LoRA .safetensors under LoRA cache roots and top-level Downloads.
    ``settings`` is reserved for future filtering; currently unused.
    """
    del settings
    paths: List[Path] = []
    seen: Set[Path] = set()
    for root in lora_weights_search_roots():
        for path in _cache_safetensors_paths(root):
            if path in seen:
                continue
            seen.add(path)
            paths.append(path)
    for path in downloads_safetensors_paths():
        if not lora_weights_file_is_valid(path):
            continue
        if path in seen:
            continue
        seen.add(path)
        paths.append(path)
    return paths
