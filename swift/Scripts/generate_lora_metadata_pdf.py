#!/usr/bin/env python3
"""One-off agent utility: PDF report of stored + file-retrieved LoRA metadata (not used by the app)."""

from __future__ import annotations

import json
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
IMAGEGEN = REPO / "ImageGenPython"
if str(IMAGEGEN) not in sys.path:
    sys.path.insert(0, str(IMAGEGEN))

from imagegen_plugins.lora_user_entries import entry_from_dict, user_entries_raw  # noqa: E402


def _catalog_path() -> Path:
    return Path.home() / ".swift-prowser" / "data" / "lora_catalog.json"


def _dash(value: str | None) -> str:
    text = (value or "").strip()
    return text if text else "—"


def _safetensors_trigger(path: Path) -> str | None:
    try:
        from imagegen_plugins.lora_trigger_resolve import _trigger_from_safetensors_metadata

        return _trigger_from_safetensors_metadata(path)
    except Exception:
        return None


def _where_froms(path: Path) -> list[str]:
    try:
        out = subprocess.check_output(
            ["mdls", "-name", "kMDItemWhereFroms", "-raw", str(path)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, OSError):
        return []
    if not out or out == "(null)":
        return []
    if out.startswith("(") and out.endswith(")"):
        inner = out[1:-1].strip()
        if not inner:
            return []
        parts = []
        for chunk in inner.split(","):
            chunk = chunk.strip().strip('"')
            if chunk:
                parts.append(chunk)
        return parts
    return [out]


def _resolved_weights(entry) -> Path | None:
    for raw in (entry.local_path, entry.source_path):
        text = str(raw or "").strip()
        if not text or text.lower().startswith(("http://", "https://")):
            continue
        p = Path(text).expanduser()
        if p.is_file() and p.suffix.lower() == ".safetensors":
            return p
    return None


def build_lines(catalog: dict) -> list[str]:
    raw = user_entries_raw(catalog)
    entries = []
    for lid, blob in raw.items():
        if not isinstance(blob, dict):
            continue
        blob = dict(blob)
        blob.setdefault("lora_id", lid)
        entry = entry_from_dict(blob)
        if entry is not None:
            entries.append(entry)
    entries.sort(key=lambda e: (e.display_name or e.lora_id).lower())

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines: list[str] = [
        "LoRA metadata report",
        f"Generated: {stamp}",
        f"Catalog: {_catalog_path()}",
        f"Entries: {len(entries)}",
        "",
    ]
    if not entries:
        lines.append("No registered user LoRAs in the catalog.")
        return lines

    for index, entry in enumerate(entries):
        if index > 0:
            lines.append("")
        title = (entry.display_name or "").strip() or entry.lora_id
        lines.append(title)
        lines.append("=" * min(72, max(len(title), 8)))
        lines.append(f"LoRA ID: {entry.lora_id}")
        lines.append(f"Host: {_dash(entry.host_id)}")
        lines.append(f"Base model: {_dash(entry.base_hf_model_id)}")
        lines.append(f"Display name: {_dash(entry.display_name)}")
        lines.append(f"Trigger word: {_dash(entry.trigger_word)}")
        lines.append(f"Default weight (best guess): {entry.best_guess:.2f}")
        lines.append(f"Comment: {_dash(entry.comment)}")
        lines.append(f"Reference prompt: {_dash(entry.reference_prompt)}")
        lines.append(f"Safetensors origin: {_dash(getattr(entry, 'safetensors_origin', None))}")
        lines.append(f"Web page: {_dash(getattr(entry, 'web_page_url', None))}")
        lines.append(f"Source path: {_dash(entry.source_path)}")
        lines.append(f"Local weights: {_dash(entry.local_path)}")
        lines.append(f"HF repo: {_dash(entry.repo_id)}")
        lines.append(f"HF filename: {_dash(entry.filename)}")

        weights = _resolved_weights(entry)
        if weights is not None:
            lines.append(f"Resolved weights: {weights}")

        retrieved: list[tuple[str, str]] = []
        if weights is not None:
            trig = _safetensors_trigger(weights)
            if trig:
                retrieved.append(("Safetensors trigger", trig))
            where = _where_froms(weights)
            if where:
                retrieved.append(("macOS download sources (WhereFrom)", "\n".join(where)))
        if retrieved:
            lines.append("")
            lines.append("Retrieved from weights file")
            lines.append("-" * 40)
            for label, value in retrieved:
                lines.append(f"{label}: {value}")
    return lines


def write_pdf(lines: list[str], out_path: Path) -> None:
    from matplotlib.backends.backend_pdf import PdfPages
    import matplotlib.pyplot as plt

    margin_left = 0.08
    margin_top = 0.95
    line_height = 0.028
    lines_per_page = int((margin_top - 0.08) / line_height)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with PdfPages(out_path) as pdf:
        chunk_start = 0
        while chunk_start < len(lines) or chunk_start == 0:
            page_lines = lines[chunk_start : chunk_start + lines_per_page]
            if not page_lines and chunk_start > 0:
                break
            fig = plt.figure(figsize=(8.5, 11))
            fig.patch.set_facecolor("white")
            y = margin_top
            for line in page_lines:
                fig.text(
                    margin_left,
                    y,
                    line,
                    fontsize=9,
                    family="monospace",
                    verticalalignment="top",
                    wrap=True,
                )
                y -= line_height
            pdf.savefig(fig, bbox_inches="tight")
            plt.close(fig)
            chunk_start += lines_per_page
            if chunk_start >= len(lines):
                break


def main() -> int:
    catalog_file = _catalog_path()
    if not catalog_file.is_file():
        print(f"No catalog at {catalog_file}", file=sys.stderr)
        return 1
    catalog = json.loads(catalog_file.read_text(encoding="utf-8"))
    lines = build_lines(catalog)
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd() / "lora_metadata_report.pdf"
    write_pdf(lines, out)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
