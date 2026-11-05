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

_headless_resnet = None
_headless_resnet_lock = threading.Lock()


@dataclass
class _ProbeCnnEnvironment:
    """Per Check LoRAs run (see ``reset_probe_cnn_environment``)."""

    compare_mode: str = ""  # full | headless | unavailable
    sorter_error: str = ""
    headless_error: str = ""
    headless_fallback_logged: bool = False
    user_warning: str = ""


_probe_cnn_env = _ProbeCnnEnvironment()
_probe_cnn_env_lock = threading.Lock()

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


def reset_probe_cnn_environment() -> None:
    """Clear probe CNN environment tracking at the start of a Check LoRAs run."""
    global _probe_cnn_env
    with _probe_cnn_env_lock:
        _probe_cnn_env = _ProbeCnnEnvironment()


def _probe_cnn_env_snapshot() -> _ProbeCnnEnvironment:
    with _probe_cnn_env_lock:
        return _ProbeCnnEnvironment(
            compare_mode=_probe_cnn_env.compare_mode,
            sorter_error=_probe_cnn_env.sorter_error,
            headless_error=_probe_cnn_env.headless_error,
            headless_fallback_logged=_probe_cnn_env.headless_fallback_logged,
            user_warning=_probe_cnn_env.user_warning,
        )


def _set_probe_cnn_compare_mode(mode: str) -> None:
    with _probe_cnn_env_lock:
        if mode == "unavailable":
            _probe_cnn_env.compare_mode = "unavailable"
        elif _probe_cnn_env.compare_mode != "unavailable":
            if mode == "full" and not _probe_cnn_env.compare_mode:
                _probe_cnn_env.compare_mode = "full"
            elif mode == "headless":
                _probe_cnn_env.compare_mode = "headless"


def note_probe_cnn_sorter_unavailable(exc: BaseException) -> None:
    msg = f"{type(exc).__name__}: {exc}"
    with _probe_cnn_env_lock:
        if not _probe_cnn_env.sorter_error:
            _probe_cnn_env.sorter_error = msg


def note_probe_cnn_headless_active() -> None:
    _set_probe_cnn_compare_mode("headless")
    with _probe_cnn_env_lock:
        if _probe_cnn_env.headless_fallback_logged:
            return
        _probe_cnn_env.headless_fallback_logged = True
    snap = _probe_cnn_env_snapshot()
    reason = snap.sorter_error or "unknown"
    line = (
        "[Check LoRAs] Probe CNN: using headless ResNet in the imagegen venv "
        f"(full similarity stack unavailable: {reason})."
    )
    print(line)


def note_probe_cnn_fully_unavailable(exc: BaseException) -> None:
    msg = f"{type(exc).__name__}: {exc}"
    with _probe_cnn_env_lock:
        _probe_cnn_env.headless_error = msg
        _probe_cnn_env.compare_mode = "unavailable"
    print(f"[Check LoRAs] Probe CNN unavailable: {msg}")


def note_probe_cnn_full_stack() -> None:
    _set_probe_cnn_compare_mode("full")


def build_probe_cnn_environment_user_warning() -> str:
    """User-facing explanation when CNN compare cannot run (cross-family false negatives)."""
    snap = _probe_cnn_env_snapshot()
    if snap.compare_mode != "unavailable":
        return ""
    parts = [
        "Cross-family LoRA probes need ResNet CNN comparison between baseline and "
        "with-LoRA images. That compare could not run in the image generation "
        "Python environment, so those probes were marked failed even when renders "
        "look different.",
        "",
    ]
    if snap.headless_error:
        parts.append(f"Headless ResNet error: {snap.headless_error}")
    if snap.sorter_error:
        parts.append(f"Full similarity stack error: {snap.sorter_error}")
    parts.extend(
        [
            "",
            "Check that torch and torchvision work in your imagegen venv "
            "(Settings → Image Generation). See the Test LoRAs debug report "
            "(check_loras_last_run.txt in your profile logs) for details.",
        ]
    )
    return "\n".join(parts).strip()


def build_probe_cnn_environment_report_lines() -> List[str]:
    snap = _probe_cnn_env_snapshot()
    if not snap.compare_mode:
        return []
    lines = ["=== Probe CNN environment ==="]
    if snap.compare_mode == "full":
        lines.append("Mode: full (search.cnn_image_similarity_sorter)")
    elif snap.compare_mode == "headless":
        lines.append("Mode: headless ResNet (imagegen venv)")
        if snap.sorter_error:
            lines.append(f"Full stack unavailable: {snap.sorter_error}")
    else:
        lines.append("Mode: unavailable — CNN compare did not run")
        if snap.sorter_error:
            lines.append(f"Full stack error: {snap.sorter_error}")
        if snap.headless_error:
            lines.append(f"Headless ResNet error: {snap.headless_error}")
    warning = build_probe_cnn_environment_user_warning()
    if warning:
        lines.append("")
        lines.extend(warning.splitlines())
    lines.append("")
    return lines


def build_probe_cnn_environment_summary_line() -> str:
    snap = _probe_cnn_env_snapshot()
    if snap.compare_mode == "full":
        return "Probe CNN: full similarity stack"
    if snap.compare_mode == "headless":
        return (
            "Probe CNN: headless ResNet (full stack unavailable"
            + (f": {snap.sorter_error}" if snap.sorter_error else "")
            + ")"
        )
    if snap.compare_mode == "unavailable":
        detail = snap.headless_error or snap.sorter_error or "unknown error"
        return f"Probe CNN: unavailable ({detail})"
    return ""


def record_probe_cnn_incompatible_probe_failure(*, lora_label: str, model_label: str) -> None:
    """
    Call when a cross-family (or CNN-required) probe fails because cnn_cosine is missing.
    Sets a one-shot user warning for the UI and log/report.
    """
    warning = build_probe_cnn_environment_user_warning()
    if not warning:
        with _probe_cnn_env_lock:
            if not _probe_cnn_env.user_warning:
                _probe_cnn_env.user_warning = (
                    "Cross-family LoRA probes require ResNet CNN comparison, but CNN "
                    "similarity was unavailable for this run. See the debug report "
                    "(check_loras_last_run.txt) for details."
                )
    else:
        with _probe_cnn_env_lock:
            if not _probe_cnn_env.user_warning:
                _probe_cnn_env.user_warning = warning
    sync_probe_cnn_environment_to_run_stats()
    print(
        f"[Check LoRAs] Probe CNN required but missing for {lora_label!r} on "
        f"{model_label} — {build_probe_cnn_environment_summary_line()}"
    )


def sync_probe_cnn_environment_to_run_stats() -> None:
    """Mirror environment state onto ``LoraCheckStats`` for progress + final result."""
    try:
        from imagegen_plugins.lora_compatibility_checker import _probe_run_context
    except ImportError:
        return
    stats = getattr(_probe_run_context, "check_stats", None)
    if stats is None:
        return
    snap = _probe_cnn_env_snapshot()
    stats.probe_cnn_compare_mode = snap.compare_mode
    stats.probe_cnn_environment_summary = build_probe_cnn_environment_summary_line()
    log_lines = build_probe_cnn_environment_report_lines()
    stats.probe_cnn_environment_log = "\n".join(log_lines).strip()
    if snap.user_warning:
        stats.probe_cnn_user_warning = snap.user_warning


def finalize_probe_cnn_environment_on_result(result: Any) -> None:
    """Attach report lines and sync stats at end of a Check LoRAs run."""
    sync_probe_cnn_environment_to_run_stats()
    lines = build_probe_cnn_environment_report_lines()
    if lines:
        result.probe_cnn_environment_lines = lines
    snap = _probe_cnn_env_snapshot()
    stats = getattr(result, "stats", None)
    if stats is None:
        return
    if snap.user_warning:
        stats.probe_cnn_user_warning = snap.user_warning
    elif int(getattr(stats, "probe_effect_cnn_required_fail", 0) or 0) > 0:
        stats.probe_cnn_user_warning = (
            "Cross-family LoRA probes require ResNet CNN comparison, but CNN "
            "similarity was unavailable for this run. See the debug report "
            "(check_loras_last_run.txt) for details."
        )


def _configured_resnet_model_name() -> str:
    from config import get_config

    settings = get_config().load_settings()
    return str(settings.get("resnet_model") or "resnet18")


def _probe_cnn_sorter():
    """Lazy ResNet feature extractor (same stack as ⌘K similarity search)."""
    global _cnn_sorter
    with _cnn_sorter_lock:
        if _cnn_sorter is not None:
            return _cnn_sorter
        from config import get_config

        resnet_model = _configured_resnet_model_name()
        cache_dir = str(get_config().image_recognition_cache_dir)
        from search.cnn_image_similarity_sorter import CNNImageSimilaritySorter

        _cnn_sorter = CNNImageSimilaritySorter(
            similarity_metric="cosine",
            cache_dir=cache_dir,
            resnet_model=resnet_model,
        )
        return _cnn_sorter


def _headless_probe_resnet():
    """
    Headless ResNet features for Check LoRAs (imagegen venv: no PySide6 / search package).

    Uses the same torchvision ResNet + preprocessing as ``CNNImageSimilaritySorter``.
    """
    global _headless_resnet
    with _headless_resnet_lock:
        if _headless_resnet is not None:
            return _headless_resnet
        import torch
        import torch.nn.functional as F
        from PIL import Image
        from torchvision import models, transforms
        from torchvision.models import ResNet101_Weights, ResNet18_Weights, ResNet50_Weights

        from pil_image_io import register_heif_opener

        register_heif_opener()

        model_name = _configured_resnet_model_name().lower()
        if model_name == "resnet50":
            model = models.resnet50(weights=ResNet50_Weights.DEFAULT)
        elif model_name == "resnet101":
            model = models.resnet101(weights=ResNet101_Weights.DEFAULT)
        else:
            model = models.resnet18(weights=ResNet18_Weights.DEFAULT)

        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"

        model = model.to(device)
        model.eval()
        feature_extractor = torch.nn.Sequential(*(list(model.children())[:-1]))
        feature_extractor.eval()
        for param in feature_extractor.parameters():
            param.requires_grad = False

        transform = transforms.Compose(
            [
                transforms.Resize(256),
                transforms.CenterCrop(224),
                transforms.Lambda(lambda img: img.convert("RGB")),
                transforms.ToTensor(),
                transforms.Normalize(
                    mean=[0.485, 0.456, 0.406],
                    std=[0.229, 0.224, 0.225],
                ),
            ]
        )

        bundle = {
            "device": device,
            "feature_extractor": feature_extractor,
            "transform": transform,
            "F": F,
            "torch": torch,
            "Image": Image,
        }
        _headless_resnet = bundle
        return bundle


def _headless_probe_feature(path: str):
    bundle = _headless_probe_resnet()
    torch = bundle["torch"]
    Image = bundle["Image"]
    try:
        with Image.open(path) as img:
            tensor = bundle["transform"](img)
    except OSError:
        return None
    tensor = tensor.unsqueeze(0).to(bundle["device"])
    with torch.no_grad():
        feat = bundle["feature_extractor"](tensor)
        feat = feat.view(feat.size(0), -1).squeeze(0)
    return feat


def _measure_probe_cnn_cosine_via_sorter(path_a: str, path_b: str) -> Optional[float]:
    sorter = _probe_cnn_sorter()
    feat_a = sorter._get_feature(path_a)
    feat_b = sorter._get_feature(path_b)
    if feat_a is None or feat_b is None:
        return None
    return float(sorter._compute_similarity(feat_a, feat_b))


def _measure_probe_cnn_cosine_headless(path_a: str, path_b: str) -> Optional[float]:
    feat_a = _headless_probe_feature(path_a)
    feat_b = _headless_probe_feature(path_b)
    if feat_a is None or feat_b is None:
        return None
    bundle = _headless_probe_resnet()
    F = bundle["F"]
    if feat_a.device != feat_b.device:
        feat_b = feat_b.to(feat_a.device)
    return float(F.cosine_similarity(feat_a, feat_b, dim=0).item())


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
        value = _measure_probe_cnn_cosine_via_sorter(path_a, path_b)
        note_probe_cnn_full_stack()
        sync_probe_cnn_environment_to_run_stats()
        return value
    except Exception as exc:
        note_probe_cnn_sorter_unavailable(exc)
        print(
            f"[Check LoRAs] CNN probe compare (similarity sorter) unavailable: {exc}; "
            "using headless ResNet"
        )
    try:
        value = _measure_probe_cnn_cosine_headless(path_a, path_b)
        note_probe_cnn_headless_active()
        sync_probe_cnn_environment_to_run_stats()
        return value
    except Exception as exc:
        note_probe_cnn_fully_unavailable(exc)
        sync_probe_cnn_environment_to_run_stats()
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
