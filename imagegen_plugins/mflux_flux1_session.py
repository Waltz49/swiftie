#!/usr/bin/env python3
"""In-process FLUX.1 Schnell and Fill with model retention."""

from __future__ import annotations

import gc
import time
from argparse import Namespace
from typing import Any

from workers.model_tasks_worker import PerfTimer, perf_log_kv

_flux1_model: Any = None
_flux1_loaded_key: tuple[Any, ...] | None = None
_flux1_fill_model: Any = None
_flux1_fill_loaded_key: tuple[Any, ...] | None = None


def compute_flux1_model_key(
    model_name: str,
    quantize: int,
    base_model: str | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
) -> tuple[Any, ...]:
    paths = tuple(str(p) for p in (lora_paths or ()))
    scales = tuple(float(s) for s in (lora_scales or ()))
    return (model_name, int(quantize), str(base_model or ""), paths, scales)


def compute_flux1_fill_model_key(
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
) -> tuple[Any, ...]:
    paths = tuple(str(p) for p in (lora_paths or ()))
    scales = tuple(float(s) for s in (lora_scales or ()))
    return (int(quantize), paths, scales)


def _model_unusable_after_low_ram(model: Any) -> bool:
    """MemorySaver can drop encoders after a run; do not reuse a hollow shell."""
    if model is None or getattr(model, "transformer", None) is None:
        return True
    if getattr(model, "t5_text_encoder", None) is None:
        return True
    if getattr(model, "clip_text_encoder", None) is None:
        return True
    return False


def _register_run_callbacks(
    model: Any,
    *,
    stepwise_dir: str | None,
    low_ram: bool,
    seed: int,
    latent_creator: Any,
) -> None:
    from mflux.callbacks.callback_manager import CallbackManager
    from mflux.callbacks.callback_registry import CallbackRegistry

    model.callbacks = CallbackRegistry()
    # MemorySaver keeps the transformer only when len(seed) > 1; series jobs need that.
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
        latent_creator=latent_creator,
    )


def get_flux1(
    *,
    model_name: str,
    quantize: int,
    base_model: str | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
) -> Any:
    global _flux1_model, _flux1_loaded_key
    key = compute_flux1_model_key(
        model_name, quantize, base_model, lora_paths, lora_scales
    )
    if _flux1_model is not None and _flux1_loaded_key == key:
        if _model_unusable_after_low_ram(_flux1_model):
            perf_log_kv("model_load", kind="flux1", cache="stale", model=model_name)
            _flux1_model = None
            _flux1_loaded_key = None
            gc.collect()
        else:
            perf_log_kv("model_load", kind="flux1", cache="warm", model=model_name)
            return _flux1_model

    if _flux1_model is not None:
        _flux1_model = None
        _flux1_loaded_key = None
        gc.collect()

    from mflux.models.common.config import ModelConfig
    from mflux.models.flux.variants.txt2img.flux import Flux1

    t0 = time.perf_counter()
    model_config = ModelConfig.from_name(
        model_name=model_name,
        base_model=base_model,
    )
    _flux1_model = Flux1(
        model_config=model_config,
        quantize=int(quantize),
        lora_paths=lora_paths,
        lora_scales=lora_scales,
    )
    _flux1_loaded_key = key
    perf_log_kv(
        "model_load",
        kind="flux1",
        cache="cold",
        model=model_name,
        quantize=quantize,
        elapsed=time.perf_counter() - t0,
    )
    return _flux1_model


def get_flux1_fill(
    *,
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
) -> Any:
    global _flux1_fill_model, _flux1_fill_loaded_key
    key = compute_flux1_fill_model_key(quantize, lora_paths, lora_scales)
    if _flux1_fill_model is not None and _flux1_fill_loaded_key == key:
        if _model_unusable_after_low_ram(_flux1_fill_model):
            perf_log_kv("model_load", kind="flux1_fill", cache="stale")
            _flux1_fill_model = None
            _flux1_fill_loaded_key = None
            gc.collect()
        else:
            perf_log_kv("model_load", kind="flux1_fill", cache="warm")
            return _flux1_fill_model

    if _flux1_fill_model is not None:
        _flux1_fill_model = None
        _flux1_fill_loaded_key = None
        gc.collect()

    from mflux.models.flux.variants.fill.flux_fill import Flux1Fill

    t0 = time.perf_counter()
    _flux1_fill_model = Flux1Fill(
        quantize=int(quantize),
        lora_paths=lora_paths,
        lora_scales=lora_scales,
    )
    _flux1_fill_loaded_key = key
    perf_log_kv(
        "model_load",
        kind="flux1_fill",
        cache="cold",
        quantize=quantize,
        elapsed=time.perf_counter() - t0,
    )
    return _flux1_fill_model


def release_flux1_sessions(*, reason: str = "explicit") -> None:
    global _flux1_model, _flux1_loaded_key, _flux1_fill_model, _flux1_fill_loaded_key
    if _flux1_model is not None or _flux1_fill_model is not None:
        perf_log_kv("flux1_session_release", reason=reason)
    try:
        from imagegen_plugins.conditioning_cache import clear_mlx_text_conditioning_cache

        clear_mlx_text_conditioning_cache()
    except Exception:
        pass
    _flux1_model = None
    _flux1_loaded_key = None
    _flux1_fill_model = None
    _flux1_fill_loaded_key = None
    gc.collect()


def generate_flux1(
    *,
    model_name: str,
    quantize: int,
    base_model: str | None,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    guidance: float,
    scheduler: str,
    low_ram: bool,
    stepwise_dir: str | None,
    image_path: str | None = None,
    image_strength: float | None = None,
    negative_prompt: str = "",
    pipeline_id: str = "flux_schnell_mflux_play",
) -> Any:
    import mlx.core as mx
    from mflux.models.common.config.config import Config
    from mflux.models.common.latent_creator.latent_creator import Img2Img, LatentCreator
    from mflux.models.common.vae.vae_util import VAEUtil
    from mflux.models.flux.latent_creator.flux_latent_creator import FluxLatentCreator
    from mflux.utils.exceptions import StopImageGenerationException
    from mflux.utils.image_util import ImageUtil

    from imagegen_plugins.mflux_conditioning import encode_flux1_cached

    with PerfTimer("flux1_generate", seed=seed, steps=steps, width=width, height=height):
        model = get_flux1(
            model_name=model_name,
            quantize=quantize,
            base_model=base_model,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
        _register_run_callbacks(
            model,
            stepwise_dir=stepwise_dir,
            low_ram=low_ram,
            seed=seed,
            latent_creator=FluxLatentCreator,
        )
        session_key = compute_flux1_model_key(
            model_name, quantize, base_model, lora_paths, lora_scales
        )
        config = Config(
            width=int(width),
            height=int(height),
            guidance=float(guidance),
            scheduler=scheduler,
            image_path=image_path,
            image_strength=image_strength,
            model_config=model.model_config,
            num_inference_steps=int(steps),
        )
        with PerfTimer("prompt_encode", pipeline=pipeline_id):
            cond = encode_flux1_cached(
                model,
                pipeline_id=pipeline_id,
                session_key=session_key,
                prompt=prompt,
                negative_prompt=negative_prompt or "",
            )
        with PerfTimer("flux1_generate_image", seed=seed):
            latents = LatentCreator.create_for_txt2img_or_img2img(
                seed=int(seed),
                width=config.width,
                height=config.height,
                img2img=Img2Img(
                    vae=model.vae,
                    latent_creator=FluxLatentCreator,
                    image_path=config.image_path,
                    sigmas=config.scheduler.sigmas,
                    init_time_step=config.init_time_step,
                ),
            )
            ctx = model.callbacks.start(seed=seed, prompt=prompt, config=config)
            ctx.before_loop(latents)
            for t in config.time_steps:
                try:
                    latents = config.scheduler.scale_model_input(latents, t)
                    noise = model.transformer(
                        t=t,
                        config=config,
                        hidden_states=latents,
                        prompt_embeds=cond.prompt_embeds,
                        pooled_prompt_embeds=cond.pooled_prompt_embeds,
                    )
                    latents = config.scheduler.step(
                        noise=noise, timestep=t, latents=latents
                    )
                    ctx.in_loop(t, latents)
                    mx.eval(latents)
                except KeyboardInterrupt:
                    ctx.interruption(t, latents)
                    raise StopImageGenerationException(
                        f"Stopping image generation at step {t + 1}/{config.num_inference_steps}"
                    ) from None
            ctx.after_loop(latents)
            latents = FluxLatentCreator.unpack_latents(
                latents=latents, height=config.height, width=config.width
            )
            decoded = VAEUtil.decode(
                vae=model.vae, latent=latents, tiling_config=model.tiling_config
            )
            return ImageUtil.to_image(
                decoded_latents=decoded,
                config=config,
                seed=seed,
                prompt=prompt,
                quantization=model.bits,
                lora_paths=model.lora_paths,
                lora_scales=model.lora_scales,
                image_path=config.image_path,
                image_strength=config.image_strength,
                generation_time=config.time_steps.format_dict["elapsed"],
            )


def generate_flux1_fill(
    *,
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    guidance: float,
    scheduler: str,
    low_ram: bool,
    stepwise_dir: str | None,
    image_path: str,
    masked_image_path: str,
    pipeline_id: str = "mflux_fill_expand",
) -> Any:
    import mlx.core as mx
    from mflux.models.common.config.config import Config
    from mflux.models.flux.latent_creator.flux_latent_creator import FluxLatentCreator
    from mflux.models.flux.variants.fill.mask_util import MaskUtil
    from mflux.models.common.vae.vae_util import VAEUtil
    from mflux.utils.exceptions import StopImageGenerationException
    from mflux.utils.image_util import ImageUtil

    from imagegen_plugins.mflux_conditioning import encode_flux1_cached

    with PerfTimer("flux1_fill_generate", seed=seed, steps=steps):
        model = get_flux1_fill(
            quantize=quantize,
            lora_paths=lora_paths,
            lora_scales=lora_scales,
        )
        _register_run_callbacks(
            model,
            stepwise_dir=stepwise_dir,
            low_ram=low_ram,
            seed=seed,
            latent_creator=FluxLatentCreator,
        )
        session_key = compute_flux1_fill_model_key(quantize, lora_paths, lora_scales)
        config = Config(
            width=int(width),
            height=int(height),
            guidance=float(guidance),
            scheduler=scheduler,
            image_path=image_path,
            image_strength=None,
            model_config=model.model_config,
            masked_image_path=masked_image_path,
            num_inference_steps=int(steps),
        )
        with PerfTimer("prompt_encode", pipeline=pipeline_id):
            cond = encode_flux1_cached(
                model,
                pipeline_id=pipeline_id,
                session_key=session_key,
                prompt=prompt,
                negative_prompt="",
            )
        with PerfTimer("flux1_fill_generate_image", seed=seed):
            latents = FluxLatentCreator.create_noise(
                seed=int(seed),
                width=config.width,
                height=config.height,
            )
            static_masked_latents = MaskUtil.create_masked_latents(
                vae=model.vae,
                width=config.width,
                height=config.height,
                img_path=config.image_path,
                mask_path=config.masked_image_path,
            )
            ctx = model.callbacks.start(seed=seed, prompt=prompt, config=config)
            ctx.before_loop(latents)
            for t in config.time_steps:
                try:
                    latents = config.scheduler.scale_model_input(latents, t)
                    hidden_states = mx.concatenate(
                        [latents, static_masked_latents], axis=-1
                    )
                    noise = model.transformer(
                        t=t,
                        config=config,
                        hidden_states=hidden_states,
                        prompt_embeds=cond.prompt_embeds,
                        pooled_prompt_embeds=cond.pooled_prompt_embeds,
                    )
                    latents = config.scheduler.step(
                        noise=noise, timestep=t, latents=latents
                    )
                    ctx.in_loop(t, latents)
                    mx.eval(latents)
                except KeyboardInterrupt:
                    ctx.interruption(t, latents)
                    raise StopImageGenerationException(
                        f"Stopping image generation at step {t + 1}/{config.num_inference_steps}"
                    ) from None
            ctx.after_loop(latents)
            latents = FluxLatentCreator.unpack_latents(
                latents=latents, height=config.height, width=config.width
            )
            decoded = VAEUtil.decode(
                vae=model.vae, latent=latents, tiling_config=model.tiling_config
            )
            return ImageUtil.to_image(
                decoded_latents=decoded,
                config=config,
                seed=seed,
                prompt=prompt,
                quantization=model.bits,
                lora_paths=model.lora_paths,
                lora_scales=model.lora_scales,
                image_path=config.image_path,
                generation_time=config.time_steps.format_dict["elapsed"],
            )
