#!/usr/bin/env python3
"""Legacy built-in LoRA catalog (migration source only; not merged at runtime)."""

from __future__ import annotations

from typing import Dict

from imagegen_plugins.lora_catalogs.flux1_fill import FLUX1_FILL_LORAS
from imagegen_plugins.lora_catalogs.flux1_t2i import FLUX1_T2I_LORAS
from imagegen_plugins.lora_catalogs.flux2_klein import FLUX2_KLEIN_LORAS
from imagegen_plugins.lora_catalogs.sd15 import SD15_LORAS
from imagegen_plugins.lora_catalogs.sdxl import SDXL_LORAS
from imagegen_plugins.lora_catalogs.z_image_turbo import Z_IMAGE_TURBO_LORAS
from imagegen_plugins.lora_entry import FluxLoraEntry

LEGACY_LORA_CATALOG: Dict[str, FluxLoraEntry] = {
    **FLUX1_T2I_LORAS,
    **FLUX1_FILL_LORAS,
    **FLUX2_KLEIN_LORAS,
    **SD15_LORAS,
    **SDXL_LORAS,
    **Z_IMAGE_TURBO_LORAS,
}


def legacy_lora_catalog() -> Dict[str, FluxLoraEntry]:
    return dict(LEGACY_LORA_CATALOG)
