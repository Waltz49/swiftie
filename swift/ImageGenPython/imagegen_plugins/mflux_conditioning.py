#!/usr/bin/env python3
"""Cached MFLUX text encoding (Klein, Flux1, Z-Image)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import mlx.core as mx

from imagegen_plugins.conditioning_cache import (
    flux1_text_key,
    get_or_compute_mlx,
    klein_text_key,
    z_image_text_key,
)


@dataclass(frozen=True)
class KleinPromptConditioning:
    prompt_embeds: mx.array
    text_ids: mx.array
    negative_prompt_embeds: mx.array | None
    negative_text_ids: mx.array | None


@dataclass(frozen=True)
class Flux1PromptConditioning:
    prompt_embeds: mx.array
    pooled_prompt_embeds: mx.array


@dataclass(frozen=True)
class ZImagePromptConditioning:
    text_encodings: mx.array
    negative_encodings: mx.array | None


def encode_klein_pair_cached(
    model: Any,
    *,
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str = " ",
    guidance: float,
) -> KleinPromptConditioning:
    cache_key = klein_text_key(
        pipeline_id, session_key, prompt, negative_prompt, guidance
    )

    def _compute() -> KleinPromptConditioning:
        prompt_embeds, text_ids, negative_prompt_embeds, negative_text_ids = (
            model._encode_prompt_pair(
                prompt=prompt,
                negative_prompt=negative_prompt,
                guidance=guidance,
            )
        )
        mx.eval(
            prompt_embeds,
            text_ids,
            negative_prompt_embeds,
            negative_text_ids,
        )
        return KleinPromptConditioning(
            prompt_embeds=prompt_embeds,
            text_ids=text_ids,
            negative_prompt_embeds=negative_prompt_embeds,
            negative_text_ids=negative_text_ids,
        )

    return get_or_compute_mlx(cache_key, _compute, pipeline=pipeline_id)


def encode_flux1_cached(
    model: Any,
    *,
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str = "",
) -> Flux1PromptConditioning:
    from mflux.models.flux.model.flux_text_encoder.prompt_encoder import PromptEncoder

    cache_key = flux1_text_key(
        pipeline_id, session_key, prompt, negative_prompt
    )

    def _compute() -> Flux1PromptConditioning:
        prompt_embeds, pooled_prompt_embeds = PromptEncoder.encode_prompt(
            prompt=prompt,
            prompt_cache=model.prompt_cache,
            t5_tokenizer=model.tokenizers["t5"],
            clip_tokenizer=model.tokenizers["clip"],
            t5_text_encoder=model.t5_text_encoder,
            clip_text_encoder=model.clip_text_encoder,
        )
        mx.eval(prompt_embeds, pooled_prompt_embeds)
        return Flux1PromptConditioning(
            prompt_embeds=prompt_embeds,
            pooled_prompt_embeds=pooled_prompt_embeds,
        )

    return get_or_compute_mlx(cache_key, _compute, pipeline=pipeline_id)


def encode_z_image_cached(
    model: Any,
    *,
    pipeline_id: str,
    session_key: tuple[Any, ...],
    prompt: str,
    negative_prompt: str | None,
    guidance: float,
) -> ZImagePromptConditioning:
    cache_key = z_image_text_key(
        pipeline_id, session_key, prompt, negative_prompt, guidance
    )

    def _compute() -> ZImagePromptConditioning:
        text_encodings, negative_encodings = model._encode_prompts(
            prompt=prompt,
            negative_prompt=negative_prompt,
            guidance=guidance,
        )
        mx.eval(text_encodings)
        if negative_encodings is not None:
            mx.eval(negative_encodings)
        return ZImagePromptConditioning(
            text_encodings=text_encodings,
            negative_encodings=negative_encodings,
        )

    return get_or_compute_mlx(cache_key, _compute, pipeline=pipeline_id)
