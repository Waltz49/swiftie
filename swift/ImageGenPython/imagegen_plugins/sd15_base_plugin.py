#!/usr/bin/env python3
"""Stable Diffusion 1.5 base (diffusers StableDiffusionPipeline)."""

from __future__ import annotations

from imagegen_plugins.hf_model_ids import SD15_BASE_V1_5
from imagegen_plugins.image_gen_registry import ImageGenModelPlugin
from imagegen_plugins.lora_host_registry import HOST_SD15
from imagegen_plugins.sd15_plugin_shared import sd15_create_field_layout

SD15_BASE_V1_5_PLUGIN = ImageGenModelPlugin(
    plugin_id="sd15_base_v1_5",
    pipeline_id="sd15_diffusers",
    display_name="SD 1.5 Base",
    hf_model_id=SD15_BASE_V1_5,
    lora_host_id=HOST_SD15,
    model_comment="Original SD 1.5; bundled VAE; general-purpose SD 1.5 LoRAs",
    max_generation_dimension=768,
    field_layout_builder=sd15_create_field_layout,
    model_defaults={
        "prompt": "",
        "negative_prompt": "",
        "width": 512,
        "height": 512,
        "steps": 25,
        "guidance_scale": 7.5,
        "seed": 0,
        "random_seed": True,
        "copies": 1,
        "vae_hf_model_id": "",
        "mflux_lora": "none",
    },
)
