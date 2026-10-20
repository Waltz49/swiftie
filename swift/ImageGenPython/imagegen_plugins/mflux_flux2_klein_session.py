#!/usr/bin/env python3
"""In-process FLUX.2 Klein create (txt2img) and edit with model retention."""

from __future__ import annotations

import gc
import os
import time
from argparse import Namespace
from collections import OrderedDict
from pathlib import Path
from typing import Any

import mlx.core as mx

from workers.model_tasks_worker import PerfTimer, perf_log_kv

from imagegen_plugins.sceneworks_klein_mlx_weights import (
    init_flux2_klein_from_sceneworks_tier,
    is_sceneworks_packed_tier_path,
)

_VAE_CACHE_MAX = 10

_session_model: Any = None
_session_key: tuple[Any, ...] | None = None
_create_session_model: Any = None
_create_session_key: tuple[Any, ...] | None = None


def _image_stat_key(path: str) -> tuple[str, int]:
    p = os.path.abspath(path)
    st = os.stat(p)
    return (os.path.basename(p), int(st.st_mtime_ns))


def _reference_cache_key(
    image_paths: list[str],
    batch_size: int,
    session_key: tuple[Any, ...],
) -> tuple[Any, ...]:
    return (
        session_key,
        int(batch_size),
        tuple(_image_stat_key(p) for p in image_paths),
    )


class _VaeEncodeCache:
    def __init__(self, maxsize: int = _VAE_CACHE_MAX) -> None:
        self._maxsize = maxsize
        self._data: OrderedDict[tuple[Any, ...], tuple[mx.array, mx.array]] = OrderedDict()

    def get(self, key: tuple[Any, ...]) -> tuple[mx.array, mx.array] | None:
        if key not in self._data:
            return None
        self._data.move_to_end(key)
        return self._data[key]

    def put(self, key: tuple[Any, ...], value: tuple[mx.array, mx.array]) -> None:
        self._data[key] = value
        self._data.move_to_end(key)
        while len(self._data) > self._maxsize:
            evicted_key, _ = self._data.popitem(last=False)
            perf_log_kv(
                "vae_cache",
                action="evict",
                cache_size=self._maxsize,
                key_basename=str(evicted_key[2])[:120] if len(evicted_key) > 2 else "",
            )

    def clear(self) -> None:
        self._data.clear()


_vae_cache = _VaeEncodeCache()


def _klein_model_config(model_name: str):
    """Klein HF ids inferred by mflux omit text_encoder_overrides (4B defaults break 9B)."""
    from mflux.models.common.config.model_config import ModelConfig

    inferred = ModelConfig.from_name(model_name=model_name)
    if inferred.text_encoder_overrides:
        return inferred

    lowered = model_name.lower()
    if "9b" in lowered:
        canonical = ModelConfig.flux2_klein_9b()
    elif "4b" in lowered:
        canonical = ModelConfig.flux2_klein_4b()
    else:
        return inferred

    return ModelConfig(
        priority=canonical.priority,
        aliases=canonical.aliases,
        model_name=model_name,
        base_model=canonical.model_name,
        controlnet_model=canonical.controlnet_model,
        custom_transformer_model=canonical.custom_transformer_model,
        num_train_steps=canonical.num_train_steps,
        max_sequence_length=canonical.max_sequence_length,
        supports_guidance=canonical.supports_guidance,
        requires_sigma_shift=canonical.requires_sigma_shift,
        transformer_overrides=dict(canonical.transformer_overrides),
        text_encoder_overrides=dict(canonical.text_encoder_overrides),
        sigma_base_shift=canonical.sigma_base_shift,
        sigma_max_shift=canonical.sigma_max_shift,
        sigma_base_seq_len=canonical.sigma_base_seq_len,
        sigma_max_seq_len=canonical.sigma_max_seq_len,
        sigma_shift_terminal=canonical.sigma_shift_terminal,
    )


def _klein_session_key(
    model_name: str,
    quantize: int | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    model_path: str | None = None,
) -> tuple[Any, ...]:
    paths = tuple(str(p) for p in (lora_paths or ()))
    scales = tuple(float(s) for s in (lora_scales or ()))
    quant_key: Any = int(quantize) if quantize is not None else "pre"
    return (model_name, quant_key, str(model_path or ""), paths, scales)


def _klein_model_needs_full_reload(model: Any) -> bool:
    """Transformer evicted or session empty — must cold-load the full stack."""
    return model is None or getattr(model, "transformer", None) is None


def _klein_model_needs_text_encoder_rehydrate(model: Any) -> bool:
    """MemorySaver drops text_encoder before denoise; transformer may still be warm."""
    if _klein_model_needs_full_reload(model):
        return False
    return getattr(model, "text_encoder", None) is None


def _rehydrate_flux2_klein_text_encoder(
    model: Any,
    *,
    quantize: int | None,
    model_path: str | None,
) -> None:
    """Reload text_encoder weights onto a warm Klein shell (skip transformer/vae)."""
    from mflux.models.common.weights.loading.weight_applier import WeightApplier
    from mflux.models.flux2.model.flux2_text_encoder.qwen3_text_encoder import Qwen3TextEncoder
    from mflux.models.flux2.weights.flux2_weight_definition import Flux2KleinWeightDefinition

    model.text_encoder = Qwen3TextEncoder(**model.model_config.text_encoder_overrides)
    components = {c.name: c for c in Flux2KleinWeightDefinition.get_components()}
    text_component = components["text_encoder"]

    if is_sceneworks_packed_tier_path(model_path):
        from mflux.models.common.weights.loading.loaded_weights import LoadedWeights, MetaData
        from mflux.models.flux2.weights.flux2_weight_mapping import Flux2WeightMapping

        from imagegen_plugins.sceneworks_klein_mlx_weights import (
            load_sceneworks_klein_text_encoder_weights,
            sceneworks_tier_quant_bits,
        )

        tier_path = Path(str(model_path)).expanduser()
        bits = sceneworks_tier_quant_bits(tier_path)
        te_weights = load_sceneworks_klein_text_encoder_weights(tier_path)
        weights = LoadedWeights(
            components={"text_encoder": te_weights},
            meta_data=MetaData(quantization_level=bits, mflux_version=None),
        )
        WeightApplier.apply_and_quantize_single(
            weights,
            model.text_encoder,
            text_component,
            quantize_arg=None,
        )
    else:
        from mflux.models.common.weights.loading.weight_loader import WeightLoader

        path = model_path if model_path else model.model_config.model_name
        weights = WeightLoader.load(
            weight_definition=Flux2KleinWeightDefinition,
            model_path=path,
        )
        quant = quantize if quantize is not None else getattr(model, "bits", None)
        WeightApplier.apply_and_quantize_single(
            weights,
            model.text_encoder,
            text_component,
            quantize_arg=quant,
        )
    gc.collect()


def _try_rehydrate_klein_session_model(
    model: Any,
    *,
    kind: str,
    model_name: str,
    quantize: int | None,
    model_path: str | None,
) -> Any | None:
    if not _klein_model_needs_text_encoder_rehydrate(model):
        return None
    perf_log_kv("model_load", kind=kind, cache="stale", model=model_name)
    t0 = time.perf_counter()
    _rehydrate_flux2_klein_text_encoder(model, quantize=quantize, model_path=model_path)
    perf_log_kv(
        "model_load",
        kind=kind,
        cache="rehydrate",
        model=model_name,
        quantize=quantize,
        elapsed=time.perf_counter() - t0,
    )
    return model


def _register_run_callbacks(
    model: Any,
    *,
    stepwise_dir: str | None,
    low_ram: bool,
    seed: int,
) -> None:
    from mflux.callbacks.callback_manager import CallbackManager
    from mflux.callbacks.callback_registry import CallbackRegistry
    from mflux.models.flux2.latent_creator.flux2_latent_creator import Flux2LatentCreator

    model.callbacks = CallbackRegistry()
    seed_arg: list[int] = [int(seed)]
    if low_ram:
        seed_arg = [int(seed), int(seed)]
    args = Namespace(
        stepwise_image_output_dir=stepwise_dir,
        low_ram=low_ram,
        seed=seed_arg,
        battery_percentage_stop_limit=None,
        output=None,
        mlx_cache_limit_gb=None,
    )
    CallbackManager.register_callbacks(
        args=args,
        model=model,
        latent_creator=Flux2LatentCreator,
    )


def get_flux2_klein_edit(
    *,
    model_name: str,
    quantize: int | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    model_path: str | None = None,
) -> Any:
    global _session_model, _session_key
    key = _klein_session_key(
        model_name, quantize, lora_paths, lora_scales, model_path=model_path
    )
    if _session_model is not None and _session_key == key:
        rehydrated = _try_rehydrate_klein_session_model(
            _session_model,
            kind="flux2_klein_edit",
            model_name=model_name,
            quantize=quantize,
            model_path=model_path,
        )
        if rehydrated is not None:
            return rehydrated
        if _klein_model_needs_full_reload(_session_model):
            perf_log_kv("model_load", kind="flux2_klein_edit", cache="stale", model=model_name)
            release_flux2_klein_session(reason="stale_low_ram")
        else:
            perf_log_kv("model_load", kind="flux2_klein_edit", cache="warm", model=model_name)
            return _session_model

    release_flux2_klein_session(reason="reload")
    from mflux.models.flux2.variants.edit.flux2_klein_edit import Flux2KleinEdit

    t0 = time.perf_counter()
    model_config = _klein_model_config(model_name)
    if is_sceneworks_packed_tier_path(model_path):
        _session_model = init_flux2_klein_from_sceneworks_tier(
            "edit",
            model_config=model_config,
            model_path=str(model_path),
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
    else:
        _session_model = Flux2KleinEdit(
            model_config=model_config,
            quantize=quantize,
            model_path=model_path,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
    _session_key = key
    perf_log_kv(
        "model_load",
        kind="flux2_klein_edit",
        cache="cold",
        model=model_name,
        quantize=quantize,
        elapsed=time.perf_counter() - t0,
    )
    return _session_model


def release_flux2_klein_session(*, reason: str = "explicit") -> None:
    global _session_model, _session_key, _create_session_model, _create_session_key
    if _session_model is not None or _create_session_model is not None:
        perf_log_kv("klein_session_release", reason=reason)
    try:
        from imagegen_plugins.conditioning_cache import clear_mlx_text_conditioning_cache

        clear_mlx_text_conditioning_cache()
    except Exception:
        pass
    _session_model = None
    _session_key = None
    _create_session_model = None
    _create_session_key = None
    _vae_cache.clear()
    gc.collect()


def get_flux2_klein_create(
    *,
    model_name: str,
    quantize: int | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    model_path: str | None = None,
) -> Any:
    global _create_session_model, _create_session_key
    key = _klein_session_key(
        model_name, quantize, lora_paths, lora_scales, model_path=model_path
    )
    if _create_session_model is not None and _create_session_key == key:
        rehydrated = _try_rehydrate_klein_session_model(
            _create_session_model,
            kind="flux2_klein_create",
            model_name=model_name,
            quantize=quantize,
            model_path=model_path,
        )
        if rehydrated is not None:
            return rehydrated
        if _klein_model_needs_full_reload(_create_session_model):
            perf_log_kv(
                "model_load", kind="flux2_klein_create", cache="stale", model=model_name
            )
            _create_session_model = None
            _create_session_key = None
            gc.collect()
        else:
            perf_log_kv(
                "model_load", kind="flux2_klein_create", cache="warm", model=model_name
            )
            return _create_session_model

    if _create_session_model is not None:
        _create_session_model = None
        _create_session_key = None
        gc.collect()

    from mflux.models.flux2.variants.txt2img.flux2_klein import Flux2Klein

    t0 = time.perf_counter()
    model_config = _klein_model_config(model_name)
    if is_sceneworks_packed_tier_path(model_path):
        _create_session_model = init_flux2_klein_from_sceneworks_tier(
            "create",
            model_config=model_config,
            model_path=str(model_path),
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
    else:
        _create_session_model = Flux2Klein(
            model_config=model_config,
            quantize=quantize,
            model_path=model_path,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
    _create_session_key = key
    perf_log_kv(
        "model_load",
        kind="flux2_klein_create",
        cache="cold",
        model=model_name,
        quantize=quantize,
        elapsed=time.perf_counter() - t0,
    )
    return _create_session_model


def _klein_create_denoise_loop(
    model: Any,
    *,
    prompt: str,
    seed: int,
    config: Any,
    guidance: float,
    session_key: tuple[Any, ...],
    pipeline_id: str = "mflux_flux2_klein_create",
) -> Any:
    from mflux.utils.exceptions import StopImageGenerationException
    from mflux.utils.image_util import ImageUtil
    from workers.model_tasks_worker import GenerationCancelledError

    from imagegen_plugins.mflux_conditioning import encode_klein_pair_cached

    with PerfTimer("prompt_encode", pipeline=pipeline_id):
        cond = encode_klein_pair_cached(
            model,
            pipeline_id=pipeline_id,
            session_key=session_key,
            prompt=prompt,
            negative_prompt=" ",
            guidance=guidance,
        )

    with PerfTimer("latents_init", seed=seed):
        latents, latent_ids, latent_height, latent_width = (
            model._prepare_generation_latents(
                seed=int(seed),
                config=config,
            )
        )

    ctx = model.callbacks.start(seed=seed, prompt=prompt, config=config)
    ctx.before_loop(latents)
    predict = model._predict(model.transformer)
    total_steps = len(config.time_steps)
    denoise_t0 = time.perf_counter()
    for step_idx, t in enumerate(config.time_steps):
        step_t0 = time.perf_counter()
        try:
            noise = predict(
                latents=latents,
                latent_ids=latent_ids,
                prompt_embeds=cond.prompt_embeds,
                text_ids=cond.text_ids,
                negative_prompt_embeds=cond.negative_prompt_embeds,
                negative_text_ids=cond.negative_text_ids,
                guidance=guidance,
                timestep=config.scheduler.timesteps[t],
            )
            latents = config.scheduler.step(
                noise=noise,
                timestep=t,
                latents=latents,
                sigmas=config.scheduler.sigmas,
            )
            ctx.in_loop(t, latents)
            mx.eval(latents)
        except GenerationCancelledError:
            raise
        except KeyboardInterrupt:
            ctx.interruption(t, latents)
            raise StopImageGenerationException(
                f"Stopping image generation at step {t + 1}/{config.num_inference_steps}"
            ) from None
        perf_log_kv(
            "denoise_step",
            step=step_idx + 1,
            total=total_steps,
            elapsed=time.perf_counter() - step_t0,
        )

    perf_log_kv("denoise_total", steps=total_steps, elapsed=time.perf_counter() - denoise_t0)
    ctx.after_loop(latents)

    with PerfTimer("vae_decode", pipeline=pipeline_id):
        packed_latents = latents.reshape(
            latents.shape[0], latent_height, latent_width, latents.shape[-1]
        ).transpose(0, 3, 1, 2)
        decoded = model.vae.decode_packed_latents(packed_latents)
    return ImageUtil.to_image(
        decoded_latents=decoded,
        config=config,
        seed=seed,
        prompt=prompt,
        negative_prompt=None,
        quantization=model.bits,
        lora_paths=model.lora_paths,
        lora_scales=model.lora_scales,
        image_path=config.image_path,
        image_strength=config.image_strength,
        generation_time=config.time_steps.format_dict["elapsed"],
    )


def generate_flux2_klein_create(
    *,
    model_name: str,
    quantize: int | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    model_path: str | None = None,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    guidance: float,
    low_ram: bool,
    stepwise_dir: str | None,
) -> Any:
    """Run one Klein txt2img; returns mflux GeneratedImage."""
    with PerfTimer("klein_create_generate", seed=seed, steps=steps):
        model = get_flux2_klein_create(
            model_name=model_name,
            quantize=quantize,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
            model_path=model_path,
        )
        _register_run_callbacks(
            model,
            stepwise_dir=stepwise_dir,
            low_ram=low_ram,
            seed=seed,
        )
        from mflux.models.common.config.config import Config

        config = Config(
            model_config=model.model_config,
            num_inference_steps=int(steps),
            height=int(height),
            width=int(width),
            guidance=float(guidance),
            image_path=None,
            image_strength=None,
            scheduler="flow_match_euler_discrete",
        )
        session_key = _klein_session_key(
            model_name, quantize, lora_paths, lora_scales, model_path=model_path
        )
        with PerfTimer("klein_create_generate_image", seed=seed):
            return _klein_create_denoise_loop(
                model,
                prompt=prompt,
                seed=int(seed),
                config=config,
                guidance=float(guidance),
                session_key=session_key,
            )


def _reference_conditioning(
    model: Any,
    image_paths: list[str],
    *,
    batch_size: int,
    session_key: tuple[Any, ...],
) -> tuple[mx.array | None, mx.array | None]:
    if not image_paths:
        return None, None

    cache_key = _reference_cache_key(image_paths, batch_size, session_key)
    cached = _vae_cache.get(cache_key)
    if cached is not None:
        perf_log_kv(
            "vae_reference",
            cache="hit",
            num_images=len(image_paths),
            batch_size=batch_size,
        )
        return cached

    from mflux.models.flux2.variants.edit.flux2_klein_edit_helpers import (
        _Flux2KleinEditHelpers,
    )

    t0 = time.perf_counter()
    image_latents, image_latent_ids = _Flux2KleinEditHelpers.prepare_reference_image_conditioning(
        vae=model.vae,
        tiling_config=model.tiling_config,
        image_paths=[Path(p) for p in image_paths],
        batch_size=batch_size,
    )
    elapsed = time.perf_counter() - t0
    _vae_cache.put(cache_key, (image_latents, image_latent_ids))
    perf_log_kv(
        "vae_reference",
        cache="miss",
        num_images=len(image_paths),
        batch_size=batch_size,
        elapsed=elapsed,
    )
    return image_latents, image_latent_ids


def generate_flux2_klein_edit(
    *,
    model_name: str,
    quantize: int | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    model_path: str | None = None,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    guidance: float,
    image_paths: list[str],
    low_ram: bool,
    stepwise_dir: str | None,
) -> Any:
    """Run one Klein edit; returns mflux GeneratedImage."""
    from mflux.models.common.config.config import Config
    from mflux.models.flux2.variants.edit.flux2_klein_edit_helpers import (
        _Flux2KleinEditHelpers,
    )
    from mflux.utils.exceptions import StopImageGenerationException
    from mflux.utils.image_util import ImageUtil

    with PerfTimer("klein_generate", seed=seed, steps=steps):
        model = get_flux2_klein_edit(
            model_name=model_name,
            quantize=quantize,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
            model_path=model_path,
        )
        _register_run_callbacks(
            model,
            stepwise_dir=stepwise_dir,
            low_ram=low_ram,
            seed=seed,
        )

        primary_image_path = image_paths[0] if image_paths else None
        config = Config(
            model_config=model.model_config,
            num_inference_steps=int(steps),
            height=int(height),
            width=int(width),
            guidance=float(guidance),
            image_path=primary_image_path,
            image_strength=None,
            scheduler="flow_match_euler_discrete",
        )

        session_key = _klein_session_key(
            model_name, quantize, lora_paths, lora_scales, model_path=model_path
        )
        from imagegen_plugins.mflux_conditioning import encode_klein_pair_cached

        with PerfTimer("prompt_encode", pipeline="flux2_klein_edit"):
            cond = encode_klein_pair_cached(
                model,
                pipeline_id="mflux_flux2_klein_edit",
                session_key=session_key,
                prompt=prompt,
                negative_prompt=" ",
                guidance=guidance,
            )

        with PerfTimer("latents_init", seed=seed):
            latents, latent_ids, latent_height, latent_width = (
                _Flux2KleinEditHelpers.prepare_generation_latents(
                    seed=int(seed),
                    height=config.height,
                    width=config.width,
                )
            )

        image_latents, image_latent_ids = _reference_conditioning(
            model,
            image_paths,
            batch_size=latents.shape[0],
            session_key=session_key,
        )

        ctx = model.callbacks.start(seed=seed, prompt=prompt, config=config)
        ctx.before_loop(latents)
        predict = model._predict(model.transformer)
        total_steps = len(config.time_steps)
        denoise_t0 = time.perf_counter()
        for step_idx, t in enumerate(config.time_steps):
            step_t0 = time.perf_counter()
            try:
                noise = predict(
                    latents=latents,
                    image_latents=image_latents,
                    latent_ids=latent_ids,
                    image_latent_ids=image_latent_ids,
                    prompt_embeds=cond.prompt_embeds,
                    text_ids=cond.text_ids,
                    negative_prompt_embeds=cond.negative_prompt_embeds,
                    negative_text_ids=cond.negative_text_ids,
                    guidance=guidance,
                    timestep=config.scheduler.timesteps[t],
                )
                latents = config.scheduler.step(
                    noise=noise,
                    timestep=t,
                    latents=latents,
                    sigmas=config.scheduler.sigmas,
                )
                ctx.in_loop(t, latents)
                mx.eval(latents)
            except GenerationCancelledError:
                raise
            except KeyboardInterrupt:
                ctx.interruption(t, latents)
                raise StopImageGenerationException(
                    f"Stopping image generation at step {t + 1}/{config.num_inference_steps}"
                ) from None
            perf_log_kv(
                "denoise_step",
                step=step_idx + 1,
                total=total_steps,
                elapsed=time.perf_counter() - step_t0,
            )

        perf_log_kv("denoise_total", steps=total_steps, elapsed=time.perf_counter() - denoise_t0)
        ctx.after_loop(latents)

        with PerfTimer("vae_decode", pipeline="flux2_klein_edit"):
            packed_latents = latents.reshape(
                latents.shape[0], latent_height, latent_width, latents.shape[-1]
            ).transpose(0, 3, 1, 2)
            decoded = model.vae.decode_packed_latents(packed_latents)
        return ImageUtil.to_image(
            decoded_latents=decoded,
            config=config,
            seed=seed,
            prompt=prompt,
            negative_prompt=None,
            quantization=model.bits,
            image_paths=[Path(p) for p in image_paths],
            image_path=config.image_path,
            generation_time=config.time_steps.format_dict["elapsed"],
        )
