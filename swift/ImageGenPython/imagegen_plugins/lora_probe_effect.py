#!/usr/bin/env python3
"""Compare probe renders to detect LoRAs that load but have no visual effect."""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from typing import Any, List, Optional

_retained_probe_temps: List[str] = []
_retained_lock = threading.Lock()

_cnn_sorter = None
_cnn_sorter_lock = threading.Lock()

# ResNet cosine similarity above this => baseline and with-LoRA renders match (no effect).
# Identical copies ~1.0; strong LoRA effects are often <0.9 (e.g. pillory ~0.6).
_DEFAULT_CNN_IDENTICAL_MIN_COSINE = 0.98

# Pass Check LoRAs only when CNN similarity is below this (lower = stronger visible effect).
PROBE_MIN_EFFECT_CNN_COSINE = 0.88

# Cross-family identical checks (strict mode) also use these pixel caps:
_STRICT_IDENTICAL_MEAN_DIFF = 0.12
_STRICT_IDENTICAL_MAX_DIFF = 8
_STRICT_IDENTICAL_TIGHT_MEAN = 0.015
_STRICT_IDENTICAL_TIGHT_MAX = 3


@dataclass(frozen=True)
class ProbeImageDelta:
    mean_diff: float
    max_diff: int
    phash_distance: Optional[int] = None
    cnn_cosine: Optional[float] = None


def _probe_cnn_identical_min_cosine() -> float:
    from config import get_config

    raw = (get_config().load_settings().get("imagegen") or {}).get("check_loras") or {}
    try:
        value = float(raw.get("cnn_identical_min_cosine", _DEFAULT_CNN_IDENTICAL_MIN_COSINE))
    except (TypeError, ValueError):
        value = _DEFAULT_CNN_IDENTICAL_MIN_COSINE
    return max(0.0, min(1.0, value))


def effective_identical_cnn_threshold(*, strict: bool) -> float:
    """CNN cosine at or above this => treated as no LoRA effect (identical)."""
    base = _probe_cnn_identical_min_cosine()
    if strict:
        return max(base, 0.99)
    return base


def build_probe_effect_threshold_lines(*, check_cross_families: bool) -> List[str]:
    """Human-readable threshold summary for console + report."""
    from imagegen_plugins.hf_model_ids import SD15_LORA_MODEL_KEYS

    configured_ident = _probe_cnn_identical_min_cosine()
    cross_ident = effective_identical_cnn_threshold(strict=True)
    sd15_keys = ", ".join(SD15_LORA_MODEL_KEYS)
    return [
        "=== Probe effect thresholds ===",
        (
            "cnn_identical_min_cosine (imagegen.check_loras; "
            f"default {_DEFAULT_CNN_IDENTICAL_MIN_COSINE}): {configured_ident}"
        ),
        (
            f"PROBE_MIN_EFFECT_CNN_COSINE: pass requires cnn_cosine < "
            f"{PROBE_MIN_EFFECT_CNN_COSINE} (SD15 checkpoints + cross-family when enabled)"
        ),
        f"Same-host identical: cnn_cosine >= {configured_ident} => fail (no effect)",
        (
            "Cross-family identical (check_cross_families="
            f"{check_cross_families}): cnn_cosine >= {cross_ident} => fail; "
            f"pixel mean<{_STRICT_IDENTICAL_MEAN_DIFF} max<{_STRICT_IDENTICAL_MAX_DIFF} "
            f"or mean<{_STRICT_IDENTICAL_TIGHT_MEAN} max<{_STRICT_IDENTICAL_TIGHT_MAX} => fail"
        ),
        (
            "Cross-family effect: CNN required; same min_effect cosine gate when CNN runs"
        ),
        (
            f"SD15 min_effect applies to: {sd15_keys}; CNN missing => pixel path may pass "
            "(no min cosine gate)"
        ),
        (
            "Create menu / Map valid: model_support same-host passes only "
            "(cross_family_models excluded)"
        ),
        "",
    ]


def build_probe_effect_outcome_lines(stats: Any) -> List[str]:
    """Effect decision counts from a finished run (for report footer)."""
    return [
        "=== Probe effect outcomes (GPU compare) ===",
        f"effect OK (pass): {getattr(stats, 'probe_effect_pass', 0)}",
        f"no effect (identical): {getattr(stats, 'probe_effect_no_effect', 0)}",
        f"weak effect (below min cosine): {getattr(stats, 'probe_effect_weak', 0)}",
        (
            "CNN required but missing (cross-family): "
            f"{getattr(stats, 'probe_effect_cnn_required_fail', 0)}"
        ),
        (
            "SD15 pass without CNN (pixel path only): "
            f"{getattr(stats, 'probe_effect_cnn_missing_pass', 0)}"
        ),
        "",
    ]


def format_probe_effect_metrics(delta: ProbeImageDelta) -> str:
    return (
        f"mean={delta.mean_diff:.3f} max={delta.max_diff} "
        f"phash={delta.phash_distance} cnn_cosine={delta.cnn_cosine}"
    )


def _probe_cnn_sorter():
    """Lazy ResNet feature extractor (same stack as ⌘K similarity search)."""
    global _cnn_sorter
    with _cnn_sorter_lock:
        if _cnn_sorter is not None:
            return _cnn_sorter
        from config import get_config

        settings = get_config().load_settings()
        resnet_model = str(settings.get("resnet_model") or "resnet18")
        cache_dir = str(get_config().image_recognition_cache_dir)
        from search.cnn_image_similarity_sorter import CNNImageSimilaritySorter

        _cnn_sorter = CNNImageSimilaritySorter(
            similarity_metric="cosine",
            cache_dir=cache_dir,
            resnet_model=resnet_model,
        )
        return _cnn_sorter


def measure_probe_cnn_cosine(path_a: str, path_b: str) -> Optional[float]:
    """
    Cosine similarity of ResNet features (0–1, higher = more alike).

    Returns None when CNN/torch cannot load or either image fails to encode.
    """
    if not path_a or not path_b:
        return None
    if not os.path.isfile(path_a) or not os.path.isfile(path_b):
        return None
    try:
        sorter = _probe_cnn_sorter()
        feat_a = sorter._get_feature(path_a)
        feat_b = sorter._get_feature(path_b)
        if feat_a is None or feat_b is None:
            return None
        return float(sorter._compute_similarity(feat_a, feat_b))
    except Exception as exc:
        print(f"[Check LoRAs] CNN probe compare failed: {exc}")
        return None


def measure_probe_image_delta(
    path_a: str,
    path_b: str,
    *,
    use_cnn: bool = True,
) -> ProbeImageDelta:
    """Pixel/phash delta plus optional CNN cosine (ResNet, same as ⌘K search)."""
    from PIL import Image, ImageChops, ImageStat

    with Image.open(path_a) as img_a, Image.open(path_b) as img_b:
        a = img_a.convert("RGB")
        b = img_b.convert("RGB")
        if a.size != b.size:
            b = b.resize(a.size, Image.Resampling.BILINEAR)
        diff = ImageChops.difference(a, b)
        stat = ImageStat.Stat(diff)
        mean_diff = sum(stat.mean) / max(1, len(stat.mean))
        max_diff = max(ext[1] for ext in stat.extrema)

    phash_distance: Optional[int] = None
    try:
        import imagehash

        with Image.open(path_a) as img_a, Image.open(path_b) as img_b:
            phash_distance = int(imagehash.phash(img_a) - imagehash.phash(img_b))
    except ImportError:
        pass

    cnn_cosine: Optional[float] = None
    if use_cnn:
        cnn_cosine = measure_probe_cnn_cosine(path_a, path_b)

    return ProbeImageDelta(
        mean_diff=float(mean_diff),
        max_diff=int(max_diff),
        phash_distance=phash_distance,
        cnn_cosine=cnn_cosine,
    )


def probe_images_effectively_identical(
    delta: ProbeImageDelta,
    *,
    strict: bool = False,
) -> bool:
    """
    True when two renders are effectively the same (LoRA had no effect).

    Prefers ResNet CNN cosine (⌘K stack) so color-matched but structurally
    different images are not treated as identical. Falls back to pixel/phash
    only when CNN is unavailable.

    ``strict`` tightens thresholds for cross-family probes (wrong architecture
    often produces decode noise that CNN treats as a weak effect).
    """
    threshold = effective_identical_cnn_threshold(strict=strict)
    if strict:
        if delta.mean_diff < _STRICT_IDENTICAL_MEAN_DIFF and delta.max_diff < _STRICT_IDENTICAL_MAX_DIFF:
            return True
        if (
            delta.mean_diff < _STRICT_IDENTICAL_TIGHT_MEAN
            and delta.max_diff < _STRICT_IDENTICAL_TIGHT_MAX
        ):
            return True
    if delta.cnn_cosine is not None:
        return delta.cnn_cosine >= threshold

    if delta.mean_diff < 0.01 and delta.max_diff < 1:
        return True
    if (
        delta.phash_distance is not None
        and delta.phash_distance == 0
        and delta.mean_diff < 0.1
        and delta.max_diff < 2
    ):
        return True
    return False


def probe_lora_effect_is_strong_enough(
    delta: ProbeImageDelta,
    *,
    require_cnn_if_missing: bool = False,
    apply_min_cnn: bool = True,
) -> bool:
    """
    True when the with-LoRA image differs enough to count as a real effect.

    Call only after ``probe_images_effectively_identical`` returned False.
    """
    if delta.cnn_cosine is None:
        return not require_cnn_if_missing
    if not apply_min_cnn:
        return True
    return float(delta.cnn_cosine) < PROBE_MIN_EFFECT_CNN_COSINE


def retain_lora_probe_temp(path: Optional[str]) -> None:
    """Keep a probe render until app quit (for manual inspection)."""
    if not path or not str(path).strip():
        return
    ap = os.path.abspath(str(path))
    with _retained_lock:
        if ap not in _retained_probe_temps:
            _retained_probe_temps.append(ap)


def cleanup_lora_probe_temps() -> None:
    """Remove retained Check LoRAs probe images (call on app quit)."""
    with _retained_lock:
        paths = list(_retained_probe_temps)
        _retained_probe_temps.clear()
    for path in paths:
        try:
            if os.path.isfile(path):
                os.unlink(path)
        except OSError:
            pass


@dataclass
class LoraProbeBaselineCache:
    """One shared no-LoRA baseline render per model + probe prompt per Check LoRAs run."""

    model_key: str = ""
    prompt: str = ""
    width: int = 0
    height: int = 0
    steps: int = 0
    path: str = ""

    def lookup(
        self,
        *,
        model_key: str,
        prompt: str,
        width: int,
        height: int,
        steps: int,
    ) -> Optional[str]:
        if (
            self.path
            and self.model_key == model_key
            and self.prompt == prompt
            and self.width == width
            and self.height == height
            and self.steps == steps
            and os.path.isfile(self.path)
        ):
            return self.path
        return None

    def store(
        self,
        *,
        model_key: str,
        prompt: str,
        width: int,
        height: int,
        steps: int,
        path: str,
    ) -> None:
        self.model_key = model_key
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.path = path
        retain_lora_probe_temp(path)

    def reset_for_model(self, model_key: str) -> None:
        if self.model_key != model_key:
            self.model_key = ""
            self.prompt = ""
            self.width = 0
            self.height = 0
            self.steps = 0
            self.path = ""


# Back-compat alias (Z-Image was the first consumer).
ZImageBaselineCache = LoraProbeBaselineCache
