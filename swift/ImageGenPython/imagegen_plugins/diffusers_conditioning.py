#!/usr/bin/env python3
"""Cached Diffusers prompt encoding for SD15, SDXL, and Sana Sprint."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Tuple

from imagegen_plugins.conditioning_cache import (
    diffusers_text_key,
    get_or_compute_torch,
    stash_torch_tensor,
)


@dataclass(frozen=True)
class DiffusersPromptConditioning:
    prompt_embeds: Any
    negative_prompt_embeds: Any | None = None
    pooled_prompt_embeds: Any | None = None
    negative_pooled_prompt_embeds: Any | None = None
    prompt_attention_mask: Any | None = None


def _stash_conditioning(cond: DiffusersPromptConditioning) -> DiffusersPromptConditioning:
    return DiffusersPromptConditioning(
        prompt_embeds=stash_torch_tensor(cond.prompt_embeds),
        negative_prompt_embeds=stash_torch_tensor(cond.negative_prompt_embeds),
        pooled_prompt_embeds=stash_torch_tensor(cond.pooled_prompt_embeds),
        negative_pooled_prompt_embeds=stash_torch_tensor(
            cond.negative_pooled_prompt_embeds
        ),
        prompt_attention_mask=stash_torch_tensor(cond.prompt_attention_mask),
    )


def encode_sd15_cached(
    pipe: Any,
    *,
    pipeline_kind: str,
    model_key: Tuple[str, ...],
    lora_key: tuple[Any, ...] | None,
    prompt: str,
    negative_prompt: str,
    guidance: float,
    device: Any,
) -> DiffusersPromptConditioning:
    do_cfg = float(guidance) > 1.0
    cache_key = diffusers_text_key(
        pipeline_kind,
        model_key,
        prompt,
        negative_prompt,
        guidance,
        lora_key=lora_key,
    )

    def _compute() -> DiffusersPromptConditioning:
        neg = negative_prompt if do_cfg and negative_prompt else None
        embeds = pipe.encode_prompt(
            prompt=prompt,
            device=device,
            num_images_per_prompt=1,
            do_classifier_free_guidance=do_cfg,
            negative_prompt=neg,
        )
        if isinstance(embeds, tuple):
            prompt_embeds = embeds[0]
            negative_prompt_embeds = embeds[1] if len(embeds) > 1 else None
        else:
            prompt_embeds = embeds
            negative_prompt_embeds = None
        return _stash_conditioning(
            DiffusersPromptConditioning(
                prompt_embeds=prompt_embeds,
                negative_prompt_embeds=negative_prompt_embeds,
            )
        )

    return get_or_compute_torch(
        cache_key, _compute, pipeline=pipeline_kind
    )


def encode_sdxl_cached(
    pipe: Any,
    *,
    pipeline_kind: str,
    model_key: Tuple[str, ...],
    lora_key: tuple[Any, ...] | None,
    prompt: str,
    negative_prompt: str,
    guidance: float,
    device: Any,
) -> DiffusersPromptConditioning:
    do_cfg = float(guidance) > 1.0
    cache_key = diffusers_text_key(
        pipeline_kind,
        model_key,
        prompt,
        negative_prompt,
        guidance,
        lora_key=lora_key,
    )

    def _compute() -> DiffusersPromptConditioning:
        neg = negative_prompt if do_cfg and negative_prompt else None
        (
            prompt_embeds,
            negative_prompt_embeds,
            pooled_prompt_embeds,
            negative_pooled_prompt_embeds,
        ) = pipe.encode_prompt(
            prompt=prompt,
            device=device,
            num_images_per_prompt=1,
            do_classifier_free_guidance=do_cfg,
            negative_prompt=neg,
        )
        return _stash_conditioning(
            DiffusersPromptConditioning(
                prompt_embeds=prompt_embeds,
                negative_prompt_embeds=negative_prompt_embeds,
                pooled_prompt_embeds=pooled_prompt_embeds,
                negative_pooled_prompt_embeds=negative_pooled_prompt_embeds,
            )
        )

    return get_or_compute_torch(
        cache_key, _compute, pipeline=pipeline_kind
    )


def encode_sana_cached(
    pipe: Any,
    *,
    pipeline_kind: str,
    model_key: Tuple[str, ...],
    prompt: str,
    guidance: float,
    device: Any,
    clean_caption: bool = False,
    max_sequence_length: int = 300,
) -> DiffusersPromptConditioning:
    cache_key = diffusers_text_key(
        pipeline_kind,
        model_key,
        prompt,
        "",
        guidance,
        extras=(bool(clean_caption), int(max_sequence_length)),
    )

    def _compute() -> DiffusersPromptConditioning:
        (
            prompt_embeds,
            prompt_attention_mask,
        ) = pipe.encode_prompt(
            prompt=prompt,
            device=device,
            num_images_per_prompt=1,
            clean_caption=clean_caption,
            max_sequence_length=max_sequence_length,
        )
        return _stash_conditioning(
            DiffusersPromptConditioning(
                prompt_embeds=prompt_embeds,
                prompt_attention_mask=prompt_attention_mask,
            )
        )

    return get_or_compute_torch(
        cache_key, _compute, pipeline=pipeline_kind
    )


def apply_conditioning_to_pipe_kwargs(
    conditioning: DiffusersPromptConditioning,
    pipe_kwargs: Dict[str, Any],
) -> None:
    pipe_kwargs.pop("prompt", None)
    pipe_kwargs.pop("negative_prompt", None)
    pipe_kwargs["prompt_embeds"] = conditioning.prompt_embeds
    if conditioning.negative_prompt_embeds is not None:
        pipe_kwargs["negative_prompt_embeds"] = conditioning.negative_prompt_embeds
    if conditioning.pooled_prompt_embeds is not None:
        pipe_kwargs["pooled_prompt_embeds"] = conditioning.pooled_prompt_embeds
    if conditioning.negative_pooled_prompt_embeds is not None:
        pipe_kwargs["negative_pooled_prompt_embeds"] = (
            conditioning.negative_pooled_prompt_embeds
        )
    if conditioning.prompt_attention_mask is not None:
        pipe_kwargs["prompt_attention_mask"] = conditioning.prompt_attention_mask
