#!/usr/bin/env python3

"""Bash scripts for Tools > Debug download helpers."""
from __future__ import annotations

import os
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

from imagegen_plugins.lora_catalog import _lora_download_local_dir, sample_flux_lora_download_entries
from utils import normalize_path_for_display


@dataclass(frozen=True)
class FluxModelDownloadEntry:
    label: str
    repo_id: str
    usage: str


MFLUX_FLUX_MODEL_DOWNLOAD_ENTRIES: Tuple[FluxModelDownloadEntry, ...] = (
    FluxModelDownloadEntry("FLUX.1 Schnell", "black-forest-labs/FLUX.1-schnell", "Create — MFLUX"),
    FluxModelDownloadEntry("FLUX.1 Dev", "black-forest-labs/FLUX.1-dev", "Create — MFLUX / LoRAs"),
    FluxModelDownloadEntry("FLUX.1 Fill", "black-forest-labs/FLUX.1-Fill-dev", "Expand and Infill"),
    FluxModelDownloadEntry("FLUX.2 Klein 4B", "black-forest-labs/FLUX.2-klein-4B", "Create and Edit"),
    FluxModelDownloadEntry("FLUX.2 Klein 9B", "black-forest-labs/FLUX.2-klein-9B", "Create and Edit"),
    FluxModelDownloadEntry("FLUX.2 Klein 9B KV", "black-forest-labs/FLUX.2-klein-9b-kv", "Create and Edit"),
    FluxModelDownloadEntry(
        "FLUX.2 Klein 9B KV MLX (SceneWorks Q4)",
        "SceneWorks/flux2-klein-9b-kv-mlx",
        "Create, Edit, and Expand — ungated MLX Q4 tier",
    ),
    FluxModelDownloadEntry(
        "Anything Furry",
        "stablediffusionapi/anythingfurry",
        "Create — SD 1.5 anime/furry (bundled VAE)",
    ),
    FluxModelDownloadEntry(
        "Realistic Vision V4.0 noVAE",
        "SG161222/Realistic_Vision_V4.0_noVAE",
        "Create — SD 1.5 photoreal diffusers",
    ),
    FluxModelDownloadEntry(
        "SD 1.5 VAE (ft-mse)",
        "stabilityai/sd-vae-ft-mse",
        "Create — required VAE for Realistic Vision noVAE",
    ),
)


def _is_frozen() -> bool:
    return getattr(sys, "frozen", False)


def _venv_dir() -> str:
    return normalize_path_for_display(str(Path(sys.executable).parent.parent))


def _venv_hf_path() -> Optional[str]:
    if _is_frozen():
        return None
    candidate = Path(sys.executable).parent / "hf"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return normalize_path_for_display(str(candidate.resolve()))
    return None


def hf_cli_path() -> str:
    """Absolute path to the hf CLI for the running Python environment."""
    resolved = _venv_hf_path()
    if resolved:
        return resolved
    return ""


def _hf_download_bash_helper() -> str:
    """Bash function that runs ``hf download`` using venv, PATH, or python -m."""
    venv_hf = _venv_hf_path()
    if venv_hf:
        return (
            "run_hf_download() {\n"
            f'  "{venv_hf}" download "$@"\n'
            "}\n"
        )
    py = normalize_path_for_display(sys.executable) if not _is_frozen() else "python3"
    return (
        "run_hf_download() {\n"
        '  if [ -x "./venv_image_browser/bin/hf" ]; then\n'
        '    ./venv_image_browser/bin/hf download "$@"\n'
        '  elif command -v hf >/dev/null 2>&1; then\n'
        '    hf download "$@"\n'
        f'  elif [ -x "{py}" ] && "{py}" -c "import huggingface_hub" 2>/dev/null; then\n'
        f'    "{py}" -m huggingface_hub.cli.hf download "$@"\n'
        '  elif python3 -c "import huggingface_hub" 2>/dev/null; then\n'
        '    python3 -m huggingface_hub.cli.hf download "$@"\n'
        '  else\n'
        '    echo "hf CLI not found. Install huggingface_hub (pip install -U huggingface_hub)." >&2\n'
        "    return 1\n"
        "  fi\n"
        "}\n"
    )


def _hf_auth_bash_helper() -> str:
    venv_hf = _venv_hf_path()
    if venv_hf:
        return f'"{venv_hf}" auth login --token "$HF_TOKEN"'
    py = normalize_path_for_display(sys.executable) if not _is_frozen() else "python3"
    return (
        'if [ -x "./venv_image_browser/bin/hf" ]; then\n'
        '  ./venv_image_browser/bin/hf auth login --token "$HF_TOKEN"\n'
        'elif command -v hf >/dev/null 2>&1; then\n'
        '  hf auth login --token "$HF_TOKEN"\n'
        f'elif [ -x "{py}" ] && "{py}" -c "import huggingface_hub" 2>/dev/null; then\n'
        f'  "{py}" -m huggingface_hub.cli.hf auth login --token "$HF_TOKEN"\n'
        "else\n"
        '  python3 -m huggingface_hub.cli.hf auth login --token "$HF_TOKEN"\n'
        "fi"
    )


def _script_header_lines() -> list[str]:
    lines = ["#!/usr/bin/env bash", "set -e", ""]
    if not _is_frozen():
        lines.extend([f'VENV={_venv_dir()}', ""])
    lines.extend(
        [
            "# EXPORT HF_TOKEN=<your_huggingface_token>",
            "",
            _pip_python_snippet(),
            "",
            '"$PYTHON" -m pip install -U huggingface_hub',
            "",
            _hf_download_bash_helper().rstrip(),
            "",
        ]
    )
    return lines


def build_sample_flux_lora_download_script() -> str:
    """Plain bash script: pip install huggingface_hub + hf download per sample LoRA."""
    lines = list(_script_header_lines())
    for entry in sample_flux_lora_download_entries():
        local_dir = normalize_path_for_display(str(_lora_download_local_dir(entry)))
        lines.append(f'run_hf_download {entry.repo_id} {entry.filename} --local-dir {local_dir}')
    return "\n".join(lines) + "\n"


def _hf_download_include_suffix(repo_id: str) -> str:
    """``--include`` flags for hf download when the repo has redundant formats."""
    from imagegen_plugins.hf_model_ids import SDXL_BASE_1_0, SDXL_DIFFUSERS_ALLOW_PATTERNS

    if repo_id == SDXL_BASE_1_0:
        patterns = " ".join(shlex.quote(p) for p in SDXL_DIFFUSERS_ALLOW_PATTERNS)
        return f" --include {patterns}"
    return ""


def build_single_model_download_script(
    repo_id: str,
    *,
    hf_token: Optional[str] = None,
    force_download: bool = False,
) -> str:
    """Bash script to download one Hugging Face model repo."""
    from imagegen_plugins.sceneworks_klein_mlx import (
        DEFAULT_MLX_TIER,
        is_sceneworks_klein_mlx_repo,
        sceneworks_download_script_lines,
    )

    token = (hf_token or os.environ.get("HF_TOKEN") or "").strip()
    lines = list(_script_header_lines())
    lines.append(f'REPO_ID="{repo_id}"')
    lines.append("")
    if token:
        lines.extend(
            [
                f"export HF_TOKEN={shlex.quote(token)}",
                _hf_auth_bash_helper(),
                "",
            ]
        )
    else:
        lines.extend(
            [
                "# export HF_TOKEN=<your_huggingface_token>",
                "# run_hf_download requires HF auth for gated models",
                "",
            ]
        )
    if is_sceneworks_klein_mlx_repo(repo_id):
        sceneworks_lines = list(sceneworks_download_script_lines(repo_id, tier=DEFAULT_MLX_TIER))
        if force_download and sceneworks_lines:
            sceneworks_lines[-1] += " --force-download"
        lines.extend(sceneworks_lines)
    else:
        download_cmd = 'run_hf_download "$REPO_ID"'
        download_cmd += _hf_download_include_suffix(repo_id)
        if force_download:
            download_cmd += " --force-download"
        lines.append(download_cmd)
    lines.append("")
    return "\n".join(lines)


def _pip_python_snippet() -> str:
    if _is_frozen():
        return 'PYTHON="python3"'
    venv = _venv_dir()
    return f'PYTHON="{venv}/bin/python"\n[ -x "$PYTHON" ] || PYTHON="python3"'


def build_terminal_download_command(
    repo_id: str,
    *,
    hf_token: Optional[str] = None,
    force_download: bool = False,
) -> str:
    """Shell one-liner for Terminal.app (keeps window open after completion)."""
    from imagegen_plugins.sceneworks_klein_mlx import (
        DEFAULT_MLX_TIER,
        is_sceneworks_klein_mlx_repo,
        tier_allow_patterns,
    )

    token = (hf_token or "").strip()
    parts = ["set -e", _hf_download_bash_helper().rstrip()]
    if token:
        parts.append(f"export HF_TOKEN={_shell_quote(token)}")
        parts.append(_hf_auth_bash_helper())
    download = f'run_hf_download {_shell_quote(repo_id)}'
    if is_sceneworks_klein_mlx_repo(repo_id):
        patterns = " ".join(_shell_quote(p) for p in tier_allow_patterns(DEFAULT_MLX_TIER))
        download += f" --include {patterns}"
    else:
        include_suffix = _hf_download_include_suffix(repo_id)
        if include_suffix:
            download += include_suffix
    if force_download:
        download += " --force-download"
    parts.append(download)
    parts.append("echo")
    parts.append(f"echo Done: {_shell_quote(repo_id)}")
    parts.append("read -r -p 'Press Enter to close…' _")
    return "; ".join(parts)


def _shell_quote(value: str) -> str:
    if not value:
        return "''"
    return "'" + value.replace("'", '\'"\'"\'') + "'"
