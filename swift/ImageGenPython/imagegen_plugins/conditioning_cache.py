#!/usr/bin/env python3
"""LRU cache for text encoder outputs reused across similar generation jobs."""

from __future__ import annotations

from collections import OrderedDict
from typing import Any, Callable, TypeVar

_TEXT_CACHE_MAX = 16

_T = TypeVar("_T")


def _perf_log_kv(*args: Any, **kwargs: Any) -> None:
    try:
        from workers.model_tasks_worker import perf_log_kv

        perf_log_kv(*args, **kwargs)
    except Exception:
        pass


def normalize_prompt_text(text: str | None) -> str:
    return (text or "").strip()


class _TextConditioningLRU:
    def __init__(self, maxsize: int = _TEXT_CACHE_MAX) -> None:
        self._maxsize = maxsize
        self._data: OrderedDict[tuple[Any, ...], Any] = OrderedDict()

    def get(self, key: tuple[Any, ...]) -> Any | None:
        if key not in self._data:
            return None
        self._data.move_to_end(key)
        return self._data[key]

    def put(self, key: tuple[Any, ...], value: Any) -> None:
        self._data[key] = value
        self._data.move_to_end(key)
        while len(self._data) > self._maxsize:
            evicted_key, _ = self._data.popitem(last=False)
            _perf_log_kv(
                "prompt_conditioning",
                cache="evict",
                cache_size=self._maxsize,
                key_head=str(evicted_key[:3])[:120],
            )

    def clear(self) -> None:
        self._data.clear()


_mlx_cache = _TextConditioningLRU()
_torch_cache = _TextConditioningLRU()


def clear_mlx_text_conditioning_cache() -> None:
    """Drop cached MFLUX prompt embeddings (call when MLX model sessions release)."""
    _mlx_cache.clear()


def clear_torch_text_conditioning_cache() -> None:
    """Drop cached Diffusers prompt embeddings (call when torch pipelines unload)."""
    _torch_cache.clear()


def clear_text_conditioning_cache() -> None:
    """Drop all cached prompt embeddings (call on full image-model unload)."""
    clear_mlx_text_conditioning_cache()
    clear_torch_text_conditioning_cache()


def get_or_compute_mlx(
    key: tuple[Any, ...],
    compute: Callable[[], _T],
    *,
    pipeline: str = "",
) -> _T:
    cached = _mlx_cache.get(key)
    if cached is not None:
        _perf_log_kv("prompt_conditioning", cache="hit", backend="mlx", pipeline=pipeline)
        return cached
    _perf_log_kv("prompt_conditioning", cache="miss", backend="mlx", pipeline=pipeline)
    value = compute()
    _mlx_cache.put(key, value)
    return value


def get_or_compute_torch(
    key: tuple[Any, ...],
    compute: Callable[[], _T],
    *,
    pipeline: str = "",
) -> _T:
    cached = _torch_cache.get(key)
    if cached is not None:
        _perf_log_kv("prompt_conditioning", cache="hit", backend="torch", pipeline=pipeline)
        return cached
    _perf_log_kv("prompt_conditioning", cache="miss", backend="torch", pipeline=pipeline)
    value = compute()
    _torch_cache.put(key, value)
    return value


def klein_text_key(
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str,
    guidance: float,
) -> tuple[Any, ...]:
    return (
        "klein",
        str(pipeline_id),
        session_key,
        normalize_prompt_text(prompt),
        normalize_prompt_text(negative_prompt),
        round(float(guidance), 6),
    )


def flux1_text_key(
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str,
) -> tuple[Any, ...]:
    return (
        "flux1",
        str(pipeline_id),
        session_key,
        normalize_prompt_text(prompt),
        normalize_prompt_text(negative_prompt),
    )


def z_image_text_key(
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str | None,
    guidance: float,
) -> tuple[Any, ...]:
    return (
        "z_image",
        str(pipeline_id),
        session_key,
        normalize_prompt_text(prompt),
        normalize_prompt_text(negative_prompt),
        round(float(guidance), 6),
    )


def diffusers_text_key(
    pipeline_kind: str,
    model_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str,
    guidance: float,
    *,
    lora_key: tuple[Any, ...] | None = None,
    extras: tuple[Any, ...] = (),
) -> tuple[Any, ...]:
    return (
        "diffusers",
        str(pipeline_kind),
        model_key,
        lora_key or (),
        normalize_prompt_text(prompt),
        normalize_prompt_text(negative_prompt),
        round(float(guidance), 6),
        extras,
    )


def stash_torch_tensor(tensor: Any) -> Any:
    if tensor is None:
        return None
    return tensor.detach().cpu().clone()
