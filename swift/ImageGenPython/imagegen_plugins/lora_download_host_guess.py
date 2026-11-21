#!/usr/bin/env python3
"""Infer LoRA host family for unregistered Downloads files (Check LoRAs probes)."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple

from imagegen_plugins.hf_model_ids import (
    FLUX1_DEV,
    FLUX2_KLEIN_4B,
    FLUX2_KLEIN_9B_KV,
    SD15_BASE_V1_5,
    SDXL_BASE_1_0,
    Z_IMAGE_TURBO,
)
from imagegen_plugins.lora_host_registry import (
    HOST_FLUX1_T2I,
    HOST_FLUX2_KLEIN,
    HOST_SD15,
    HOST_SDXL,
    HOST_Z_IMAGE_TURBO,
)

_METADATA_HOST_KEYS = (
    "ss_base_model_version",
    "ss_base_model",
    "base_model",
    "ss_output_name",
    "modelspec.architecture",
    "modelspec.implementation",
)

_DEFAULT_FLUX1 = (HOST_FLUX1_T2I, FLUX1_DEV)


def _normalize_hint(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", (text or "").lower()).strip("_")


def classify_lora_host_from_hints(hints: Iterable[str]) -> Tuple[str, str]:
    """
    Map metadata/filename tokens to (host_id, base_hf_model_id).

    Each hint is classified on its own so hashes/training JSON cannot bridge
    9b vs 4b across tokens. Used so Check LoRAs applies same-host probe rules.
    """
    normalized = [_normalize_hint(h) for h in hints if str(h or "").strip()]
    normalized = [n for n in normalized if n]
    if not normalized:
        return _DEFAULT_FLUX1

    # More specific Klein variants first (per token, not one concatenated blob).
    for norm in normalized:
        if _hint_is_klein_9b(norm):
            return HOST_FLUX2_KLEIN, FLUX2_KLEIN_9B_KV
    for norm in normalized:
        if _hint_is_klein_4b(norm):
            return HOST_FLUX2_KLEIN, FLUX2_KLEIN_4B
    for norm in normalized:
        if _hint_is_klein_family(norm):
            return HOST_FLUX2_KLEIN, FLUX2_KLEIN_9B_KV

    for norm in normalized:
        if _hint_is_z_image(norm):
            return HOST_Z_IMAGE_TURBO, Z_IMAGE_TURBO
    for norm in normalized:
        if _hint_is_sdxl(norm):
            return HOST_SDXL, SDXL_BASE_1_0
    for norm in normalized:
        if _hint_is_sd15(norm):
            return HOST_SD15, SD15_BASE_V1_5
    for norm in normalized:
        if _hint_is_flux1(norm):
            return _DEFAULT_FLUX1

    return _DEFAULT_FLUX1


def _hint_is_klein_9b(norm: str) -> bool:
    return bool(
        re.search(r"flux2_klein_9|flux2klein9|klein_9b|f2k9b|(?:^|_)k9b(?:_|$)", norm)
    )


def _hint_is_klein_4b(norm: str) -> bool:
    return bool(
        re.search(r"flux2_klein_4|flux2klein4|klein_4b|f2k4b|(?:^|_)k4b(?:_|$)", norm)
    )


def _hint_is_klein_family(norm: str) -> bool:
    return "flux2_klein" in norm or norm == "klein" or norm.startswith("klein_")


def _hint_is_z_image(norm: str) -> bool:
    return bool(re.search(r"z_image|zimage|tongyi", norm))


def _hint_is_sdxl(norm: str) -> bool:
    return bool(re.search(r"sdxl|stable_diffusion_xl", norm))


def _hint_is_sd15(norm: str) -> bool:
    return bool(
        re.search(r"sd_?1[_.-]?5|sd15|stable_diffusion_v1|stable_diffusion_1", norm)
    )


def _hint_is_flux1(norm: str) -> bool:
    return bool(
        re.search(r"flux[_.-]?1|flux1|black[-_]?forest", norm)
        and "flux2" not in norm
        and "klein" not in norm
    )


def _safetensors_metadata(path: Path) -> Dict[str, str]:
    try:
        from safetensors import safe_open
    except ImportError:
        return {}
    try:
        with safe_open(str(path), framework="pt") as handle:
            raw = handle.metadata() or {}
    except (OSError, RuntimeError, ValueError):
        return {}
    if not isinstance(raw, dict):
        return {}
    out: Dict[str, str] = {}
    for key, value in raw.items():
        if value is None:
            continue
        text = str(value).strip()
        if text:
            out[str(key)] = text
    return out


def _host_from_tensor_key_prefix(path: Path) -> Optional[Tuple[str, str]]:
    """Fallback when metadata is empty (FLUX.2 Klein uses transformer.* keys)."""
    try:
        from safetensors import safe_open
    except ImportError:
        return None
    try:
        with safe_open(str(path), framework="pt") as handle:
            for index, key in enumerate(handle.keys()):
                if index > 200:
                    break
                if key.startswith("transformer."):
                    return HOST_FLUX2_KLEIN, FLUX2_KLEIN_9B_KV
    except (OSError, RuntimeError, ValueError):
        return None
    return None


def guess_host_and_base_model_for_download(path: Path) -> Tuple[str, str]:
    """Best-effort host family for a Downloads .safetensors before catalog import."""
    resolved = path.expanduser()
    hints: list[str] = [resolved.stem]
    metadata = _safetensors_metadata(resolved)
    for key in _METADATA_HOST_KEYS:
        value = metadata.get(key)
        if value:
            hints.append(value)

    host_base = classify_lora_host_from_hints(hints)
    if host_base != _DEFAULT_FLUX1:
        return host_base

    from_tensor = _host_from_tensor_key_prefix(resolved)
    if from_tensor is not None:
        return from_tensor
    return _DEFAULT_FLUX1