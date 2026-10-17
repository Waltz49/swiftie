"""EXIF user comment on diffusers VAE progressive previews (SD15/SDXL)."""

from __future__ import annotations

import sys
from typing import Any, Dict, Optional


def stamp_progressive_preview_exif(
    image_path: str,
    payload: Dict[str, Any],
    *,
    hf_model_id: str,
    completed_step: int,
    total_steps: int,
    elapsed_seconds: Optional[float],
    seed: Optional[int],
) -> None:
    """Write Image Model / Prompt EXIF on an in-progress preview PNG."""
    if not image_path or completed_step >= total_steps:
        return
    try:
        from imagegen_plugins.image_gen_naming import (
            make_readable_user_comment_before_browse,
            menu_label_for_hf_model_id,
        )

        model_name = menu_label_for_hf_model_id(hf_model_id, payload)
        make_readable_user_comment_before_browse(
            image_path,
            model_name=model_name,
            values=payload,
            elapsed_seconds=elapsed_seconds,
            completed_step=completed_step,
            total_steps=total_steps,
            seed=seed,
            force_refresh=True,
        )
    except Exception as exc:
        print(
            f"[diffusers_progressive_exif] failed step {completed_step}/{total_steps}: {exc}",
            file=sys.stderr,
        )

