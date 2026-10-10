#!/usr/bin/env python3
"""Canonical Hugging Face model ids for image generation and LoRA settings."""

from __future__ import annotations

FLUX1_SCHNELL = "black-forest-labs/FLUX.1-schnell"
FLUX1_DEV = "black-forest-labs/FLUX.1-dev"
FLUX1_FILL_DEV = "black-forest-labs/FLUX.1-Fill-dev"
FLUX2_KLEIN_4B = "black-forest-labs/FLUX.2-klein-4B"
FLUX2_KLEIN_9B = "black-forest-labs/FLUX.2-klein-9B"
FLUX2_KLEIN_9B_KV = "black-forest-labs/FLUX.2-klein-9b-kv"
SCENEWORKS_FLUX2_KLEIN_9B_KV_MLX = "SceneWorks/flux2-klein-9b-kv-mlx"

REALISTIC_VISION_V4_NOVAE = "SG161222/Realistic_Vision_V4.0_noVAE"
ANYTHING_FURRY = "stablediffusionapi/anythingfurry"
SD15_DEFAULT_VAE = "stabilityai/sd-vae-ft-mse"

SDXL_BASE_1_0 = "stabilityai/stable-diffusion-xl-base-1.0"

# Diffusers-only subset for sdxl_diffusers (~13–14 GB fp32 weights; not the full ~54 GB repo).
SDXL_DIFFUSERS_ALLOW_PATTERNS: tuple[str, ...] = (
    "model_index.json",
    "scheduler/*",
    "tokenizer/*",
    "tokenizer_2/*",
    "unet/config.json",
    "unet/diffusion_pytorch_model.safetensors",
    "text_encoder/config.json",
    "text_encoder/model.safetensors",
    "text_encoder_2/config.json",
    "text_encoder_2/model.safetensors",
    "vae/config.json",
    "vae/diffusion_pytorch_model.safetensors",
)

Z_IMAGE_TURBO = "Tongyi-MAI/Z-Image-Turbo"
# Legacy diffusers/SDNQ repo id (align_z_image_dims + optional SDNQ plugin).
Z_IMAGE_TURBO_SDNQ_INT8 = "Disty0/Z-Image-Turbo-SDNQ-int8"

# SD 1.5 checkpoints that use HOST_SD15 (settings + run dialog LoRA lists).
SD15_LORA_MODEL_KEYS: tuple[str, ...] = (
    REALISTIC_VISION_V4_NOVAE,
    ANYTHING_FURRY,
)

# SDXL 1.0 checkpoints that use HOST_SDXL (settings + run dialog LoRA lists).
SDXL_LORA_MODEL_KEYS: tuple[str, ...] = (
    SDXL_BASE_1_0,
)

LORA_PROBE_MODEL_ORDER: tuple[str, ...] = (
    FLUX1_SCHNELL,
    FLUX1_DEV,
    FLUX1_FILL_DEV,
    FLUX2_KLEIN_4B,
    FLUX2_KLEIN_9B,
    FLUX2_KLEIN_9B_KV,
    SCENEWORKS_FLUX2_KLEIN_9B_KV_MLX,
    Z_IMAGE_TURBO,
    REALISTIC_VISION_V4_NOVAE,
    ANYTHING_FURRY,
    SDXL_BASE_1_0,
)

LORA_MODEL_DISPLAY_NAMES: dict[str, str] = {
    FLUX1_SCHNELL: "FLUX.1 Schnell",
    FLUX1_DEV: "FLUX.1 Dev",
    FLUX1_FILL_DEV: "FLUX.1 Fill",
    FLUX2_KLEIN_4B: "FLUX.2 Klein 4B",
    FLUX2_KLEIN_9B: "FLUX.2 Klein 9B",
    FLUX2_KLEIN_9B_KV: "FLUX.2 Klein 9B KV",
    SCENEWORKS_FLUX2_KLEIN_9B_KV_MLX: "FLUX.2 Klein 9B KV MLX",
    REALISTIC_VISION_V4_NOVAE: "Realistic Vision V4.0",
    ANYTHING_FURRY: "Anything Furry",
    SDXL_BASE_1_0: "SDXL 1.0 Base",
    Z_IMAGE_TURBO: "Z-Image Turbo",
    Z_IMAGE_TURBO_SDNQ_INT8: "Z-Image Turbo (SDNQ)",
}

# Queued-job / settings migration from removed SDNQ plugin.
LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID = "z_image_turbo_sdnq_int8"
LEGACY_Z_IMAGE_SDNQ_PIPELINE_ID = "z_image_turbo_sdnq"
LEGACY_Z_IMAGE_MFLUX_HF_IDS: frozenset[str] = frozenset(
    {
        "Disty0/Z-Image-Turbo-SDNQ-int8",
        "filipstrand/Z-Image-Turbo-mflux-4bit",
    }
)


Z_IMAGE_TURBO_PLUGIN_ID = "z_image_turbo_mflux_4bit"
Z_IMAGE_TURBO_DEFAULT_QUANTIZE = 8


def migrate_legacy_z_image_plugin_id(plugin_id: str) -> str:
    if plugin_id == LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID:
        return Z_IMAGE_TURBO_PLUGIN_ID
    return plugin_id


def migrate_legacy_imagegen_block(imagegen: dict) -> bool:
    """Rewrite removed SDNQ plugin keys in persisted imagegen settings. Returns True if changed."""
    if not isinstance(imagegen, dict):
        return False
    changed = False
    by_fn = imagegen.get("active_plugin_by_function")
    if isinstance(by_fn, dict):
        for fn, pid in list(by_fn.items()):
            if pid == LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID:
                by_fn[fn] = Z_IMAGE_TURBO_PLUGIN_ID
                changed = True
    dialogs = imagegen.get("dialogs")
    if not isinstance(dialogs, dict):
        return changed
    for entry in dialogs.values():
        if not isinstance(entry, dict):
            continue
        plugin_settings = entry.get("plugin_settings")
        if isinstance(plugin_settings, dict) and LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID in plugin_settings:
            legacy = dict(plugin_settings.pop(LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID))
            if "mflux_quantize" not in legacy:
                legacy["mflux_quantize"] = Z_IMAGE_TURBO_DEFAULT_QUANTIZE
            target = plugin_settings.get(Z_IMAGE_TURBO_PLUGIN_ID)
            if not isinstance(target, dict) or not target:
                plugin_settings[Z_IMAGE_TURBO_PLUGIN_ID] = legacy
            changed = True
        stacks = entry.get("lora_stacks")
        if isinstance(stacks, dict) and LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID in stacks:
            if Z_IMAGE_TURBO_PLUGIN_ID not in stacks:
                stacks[Z_IMAGE_TURBO_PLUGIN_ID] = stacks[LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID]
            stacks.pop(LEGACY_Z_IMAGE_SDNQ_PLUGIN_ID, None)
            changed = True
    return changed


def migrate_legacy_z_image_job_values(values: dict) -> dict:
    """Rewrite removed SDNQ pipeline fields for MFLUX Z-Image restore."""
    out = dict(values)
    pipeline_id = str(out.get("pipeline_id") or "")
    if pipeline_id == LEGACY_Z_IMAGE_SDNQ_PIPELINE_ID:
        out["pipeline_id"] = "mflux_z_image_turbo"
    hf = str(out.get("hf_model_id") or "").strip()
    is_legacy_z_image = (
        pipeline_id == LEGACY_Z_IMAGE_SDNQ_PIPELINE_ID
        or hf in LEGACY_Z_IMAGE_MFLUX_HF_IDS
    )
    if is_legacy_z_image and (hf in LEGACY_Z_IMAGE_MFLUX_HF_IDS or not hf):
        out["hf_model_id"] = Z_IMAGE_TURBO
    if "mflux_quantize" not in out and pipeline_id == LEGACY_Z_IMAGE_SDNQ_PIPELINE_ID:
        out["mflux_quantize"] = 8
    return out


def lora_model_display_name(hf_model_id: str) -> str:
    return LORA_MODEL_DISPLAY_NAMES.get(hf_model_id, hf_model_id)


def hf_repo_snapshot_allow_patterns(
    pipeline_id: str, repo_id: str
) -> tuple[str, ...] | None:
    """Subset of HF repo files to download for a pipeline (None = full repo)."""
    if pipeline_id == "sdxl_diffusers" and repo_id == SDXL_BASE_1_0:
        return SDXL_DIFFUSERS_ALLOW_PATTERNS
    return None
