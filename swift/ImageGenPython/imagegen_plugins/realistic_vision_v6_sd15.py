#!/usr/bin/env python3
"""Realistic Vision V6.0 B1 noVAE (diffusers Stable Diffusion 1.5)."""

from __future__ import annotations

from imagegen_plugins.hf_model_ids import (
    REALISTIC_VISION_V6_DEFAULT_CHECKPOINT,
    REALISTIC_VISION_V6_NOVAE,
    SD15_DEFAULT_VAE,
)
from imagegen_plugins.image_gen_registry import ImageGenModelPlugin
from imagegen_plugins.lora_host_registry import HOST_SD15
from imagegen_plugins.sd15_plugin_shared import sd15_create_field_layout

# Civitai version 245598 showcase negative prompt.
_CIVITAI_V6_NEGATIVE = (
    "(deformed iris, deformed pupils, semi-realistic, cgi, 3d, render, sketch, "
    "cartoon, drawing, anime), text, cropped, out of frame, worst quality, low "
    "quality, jpeg artifacts, ugly, duplicate, morbid, mutilated, extra fingers, "
    "mutated hands, poorly drawn hands, poorly drawn face, mutation, deformed, "
    "blurry, dehydrated, bad anatomy, bad proportions, extra limbs, cloned face, "
    "disfigured, gross proportions, malformed limbs, missing arms, missing legs, "
    "extra arms, extra legs, fused fingers, too many fingers, long neck"
)

REALISTIC_VISION_V6_SD15_PLUGIN = ImageGenModelPlugin(
    plugin_id="realistic_vision_v6_sd15",
    pipeline_id="sd15_diffusers",
    display_name="Realistic Vision V6.0 B1",
    hf_model_id=REALISTIC_VISION_V6_NOVAE,
    lora_host_id=HOST_SD15,
    model_comment="SD 1.5 photorealistic V6 B1 noVAE; sd-vae-ft-mse; SD 1.5 LoRAs",
    max_generation_dimension=1024,
    field_layout_builder=sd15_create_field_layout,
    model_defaults={
        "prompt": "",
        "negative_prompt": _CIVITAI_V6_NEGATIVE,
        "width": 768,
        "height": 1024,
        "steps": 36,
        "guidance_scale": 1.7,
        "seed": 0,
        "random_seed": True,
        "copies": 1,
        "vae_hf_model_id": SD15_DEFAULT_VAE,
        "checkpoint_path": REALISTIC_VISION_V6_DEFAULT_CHECKPOINT,
        "mflux_lora": "none",
    },
)