#!/usr/bin/env python3
"""In-process Z-Image Turbo (MFLUX, runtime quantize) with model retention."""

from __future__ import annotations

import gc
import os
import time
from argparse import Namespace
from typing import Any

from workers.model_tasks_worker import PerfTimer, perf_log_kv

_z_image_model: Any = None
_z_image_loaded_key: tuple[Any, ...] | None = None


def compute_z_image_model_key(
    model_path: str,
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    *,
    bake_lora: bool = True,
) -> tuple[Any, ...]:
    paths = tuple(os.path.abspath(str(p)) for p in (lora_paths or ()))
    scales = tuple(float(s) for s in (lora_scales or ()))
    return (model_path, int(quantize), paths, scales, bool(bake_lora))


def resolve_z_image_bake_lora(
    *,
    mode: str,
    scale_count: int,
    seed_count: int,
    has_lora: bool,
) -> bool:
    """Pick bake_lora for batch runs (auto mode considers scale and seed sweep shape)."""
    choice = (mode or "auto").strip().lower()
    if choice == "yes":
        return True
    if choice == "no":
        return False
    if not has_lora:
        return True
    scales = max(1, int(scale_count))
    seeds = max(1, int(seed_count))
    if scales > 1 and seeds <= 1:
        return False
    return True


def _model_unusable_after_low_ram(model: Any) -> bool:
    if model is None or getattr(model, "transformer", None) is None:
        return True
    if getattr(model, "text_encoder", None) is None:
        return True
    return False


def _register_run_callbacks(
    model: Any,
    *,
    stepwise_dir: str | None,
    low_ram: bool,
    seed: int,
    latent_creator: Any,
    num_seeds: int = 1,
) -> None:
    from mflux.callbacks.callback_manager import CallbackManager
    from mflux.callbacks.callback_registry import CallbackRegistry

    model.callbacks = CallbackRegistry()
    seed_count = max(1, int(num_seeds))
    seed_arg: list[int] = [int(seed)] * seed_count
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


def get_z_image(
    *,
    model_path: str,
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    bake_lora: bool = True,
) -> Any:
    global _z_image_model, _z_image_loaded_key
    paths = [os.path.abspath(str(p)) for p in (lora_paths or [])]
    scales = [float(s) for s in (lora_scales or [])]
    lora_paths_arg = paths if paths else None
    lora_scales_arg = scales if scales else None
    key = compute_z_image_model_key(
        model_path,
        int(quantize),
        lora_paths_arg,
        lora_scales_arg,
        bake_lora=bake_lora,
    )
    if _z_image_model is not None and _z_image_loaded_key == key:
        if _model_unusable_after_low_ram(_z_image_model):
            perf_log_kv("model_load", kind="z_image_turbo", cache="stale", model=model_path)
            _z_image_model = None
            _z_image_loaded_key = None
            gc.collect()
        else:
            perf_log_kv("model_load", kind="z_image_turbo", cache="warm", model=model_path)
            return _z_image_model

    if _z_image_model is not None:
        _z_image_model = None
        _z_image_loaded_key = None
        gc.collect()

    from mflux.models.common.config import ModelConfig
    from mflux.models.z_image.variants.z_image import ZImage

    t0 = time.perf_counter()
    _z_image_model = ZImage(
        quantize=int(quantize),
        model_config=ModelConfig.z_image_turbo(),
        model_path=model_path,
        lora_paths=lora_paths_arg,
        lora_scales=lora_scales_arg,
        bake_lora=bake_lora,
    )
    _z_image_loaded_key = key
    perf_log_kv(
        "model_load",
        kind="z_image_turbo",
        cache="cold",
        model=model_path,
        elapsed=time.perf_counter() - t0,
    )
    return _z_image_model


def release_z_image_session(*, reason: str = "explicit") -> None:
    global _z_image_model, _z_image_loaded_key
    if _z_image_model is not None:
        perf_log_kv("z_image_session_release", reason=reason)
    try:
        from imagegen_plugins.conditioning_cache import clear_mlx_text_conditioning_cache

        clear_mlx_text_conditioning_cache()
    except Exception:
        pass
    _z_image_model = None
    _z_image_loaded_key = None
    gc.collect()


def z_image_applied_lora_count(model: Any) -> int:
    """Count LoRA layers attached to a loaded Z-Image model."""
    from mflux.models.common.lora.layer.fused_linear_lora_layer import FusedLoRALinear
    from mflux.models.common.lora.layer.linear_lora_layer import LoRALinear

    count = 0
    modules = getattr(model, "modules", None)
    if not callable(modules):
        return 0
    for module in model.modules():
        if isinstance(module, LoRALinear):
            count += 1
        elif isinstance(module, FusedLoRALinear):
            count += len(getattr(module, "loras", None) or [])
    return count


def run_z_image_on_model(
    model: Any,
    *,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    low_ram: bool,
    stepwise_dir: str | None,
    num_seeds: int = 1,
    model_path: str = "",
    quantize: int = 8,
    lora_paths: list[str] | None = None,
    lora_scales: list[float] | None = None,
    bake_lora: bool = True,
    negative_prompt: str | None = None,
) -> Any:
    import mlx.core as mx
    from mflux.models.common.config.config import Config
    from mflux.models.common.latent_creator.latent_creator import Img2Img, LatentCreator
    from mflux.models.z_image.latent_creator import ZImageLatentCreator
    from mflux.utils.exceptions import StopImageGenerationException
    from mflux.utils.image_util import ImageUtil

    from imagegen_plugins.mflux_conditioning import encode_z_image_cached

    _register_run_callbacks(
        model,
        stepwise_dir=stepwise_dir,
        low_ram=low_ram,
        seed=seed,
        latent_creator=ZImageLatentCreator,
        num_seeds=num_seeds,
    )
    session_key = compute_z_image_model_key(
        model_path,
        int(quantize),
        lora_paths,
        lora_scales,
        bake_lora=bake_lora,
    )
    guidance = 0.0
    scheduler = "linear"
    config = Config(
        width=int(width),
        height=int(height),
        guidance=guidance,
        scheduler=scheduler,
        image_path=None,
        image_strength=None,
        model_config=model.model_config,
        num_inference_steps=int(steps),
    )
    from workers.model_tasks_worker import abort_if_generation_cancelled

    abort_if_generation_cancelled()
    with PerfTimer("prompt_encode", pipeline="mflux_z_image_turbo"):
        enc = encode_z_image_cached(
            model,
            pipeline_id="mflux_z_image_turbo",
            session_key=session_key,
            prompt=prompt,
            negative_prompt=negative_prompt,
            guidance=guidance,
        )
    with PerfTimer("z_image_generate_image", seed=seed):
        latents = LatentCreator.create_for_txt2img_or_img2img(
            seed=int(seed),
            width=config.width,
            height=config.height,
            img2img=Img2Img(
                vae=model.vae,
                latent_creator=ZImageLatentCreator,
                image_path=config.image_path,
                sigmas=config.scheduler.sigmas,
                init_time_step=config.init_time_step,
                tiling_config=model.tiling_config,
            ),
        )
        ctx = model.callbacks.start(seed=seed, prompt=prompt, config=config)
        ctx.before_loop(latents)
        predict = model._predict(model.transformer)
        from workers.model_tasks_worker import GenerationCancelledError

        for t in config.time_steps:
            try:
                sigma_t = config.scheduler.sigmas[t].reshape((1,))
                timestep = mx.ones_like(sigma_t) - sigma_t
                noise = predict(
                    latents=latents,
                    timestep=timestep,
                    sigmas=config.scheduler.sigmas,
                    text_encodings=enc.text_encodings,
                    negative_encodings=enc.negative_encodings,
                    guidance=config.guidance,
                )
                latents = config.scheduler.step(
                    noise=noise, timestep=t, latents=latents
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
        ctx.after_loop(latents)
        decoded = model._decode_latents(
            latents=latents,
            config=config,
            prompt=prompt,
            seed=int(seed),
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
            negative_prompt=negative_prompt,
        )


def generate_z_image(
    *,
    model_path: str,
    quantize: int,
    lora_paths: list[str] | None,
    lora_scales: list[float] | None,
    prompt: str,
    seed: int,
    steps: int,
    width: int,
    height: int,
    low_ram: bool,
    stepwise_dir: str | None,
    require_lora_layers: bool = False,
    bake_lora: bool = True,
) -> Any | None:
    paths = [os.path.abspath(str(p)) for p in (lora_paths or [])]
    scales = [float(s) for s in (lora_scales or [])]
    if paths and len(scales) != len(paths):
        raise ValueError(
            f"Z-Image LoRA path/scale mismatch: {len(paths)} paths vs {len(scales)} scales"
        )
    lora_paths_arg = paths if paths else None
    lora_scales_arg = scales if scales else None

    with PerfTimer("z_image_generate", seed=seed, steps=steps, width=width, height=height):
        model = get_z_image(
            model_path=model_path,
            quantize=int(quantize),
            lora_paths=lora_paths_arg,
            lora_scales=lora_scales_arg,
            bake_lora=bake_lora,
        )
        if require_lora_layers and lora_paths_arg:
            if z_image_applied_lora_count(model) <= 0:
                perf_log_kv(
                    "z_image_generate_skip",
                    reason="no_lora_layers",
                    model=model_path,
                    lora_paths=len(lora_paths_arg),
                )
                return None
        return run_z_image_on_model(
            model,
            prompt=prompt,
            seed=seed,
            steps=steps,
            width=width,
            height=height,
            low_ram=low_ram,
            stepwise_dir=stepwise_dir,
            model_path=model_path,
            quantize=int(quantize),
            lora_paths=lora_paths_arg,
            lora_scales=lora_scales_arg,
            bake_lora=bake_lora,
        )
