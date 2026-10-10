#!/usr/bin/env python3
"""Human-readable reports for Check LoRAs runs."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from imagegen_plugins.hf_model_ids import Z_IMAGE_TURBO, lora_model_display_name
from imagegen_plugins.lora_compatibility_checker import LoraCheckChange, LoraCheckResult

LAST_REPORT_PATHS: List[str] = []


def format_probe_elapsed(seconds: float) -> str:
    total = max(0, int(seconds))
    if total >= 3600:
        return f"{total // 3600}h {(total % 3600) // 60}m"
    if total >= 60:
        return f"{total // 60}m {total % 60}s"
    return f"{total}s"


def probe_elapsed_footer_lines(result: LoraCheckResult) -> List[str]:
    if result.elapsed_seconds <= 0:
        return []
    return ["", f"Total elapsed: {format_probe_elapsed(result.elapsed_seconds)}"]


def _changes_of(result: LoraCheckResult, kind: str) -> List[LoraCheckChange]:
    return [c for c in result.changes if c.kind == kind]


def format_results_text_sections(result: LoraCheckResult) -> List[str]:
    """User-facing results summary (Test LoRAs results dialog)."""
    st = result.stats
    lines = [
        (
            "Test LoRAs cancelled (partial results saved)."
            if result.cancelled
            else "Test LoRAs finished."
        ),
        "",
        "Summary",
        f"  On-disk LoRAs tested: {st.loras_done}/{st.loras_total}",
        f"  Installed models: {st.models_total}",
        f"  GPU renders: {st.gpu_probes_done}/{st.probes_total}",
        f"  Passed probes this run: {st.passed_probe_count}",
        f"  LoRAs with at least one pass: {st.supported_loras}",
        f"  LoRAs with no pass: {st.removed_loras}",
        f"  Newly compatible pairs: {st.newly_supported_count}",
        f"  Newly enabled in Settings: {st.newly_enabled_count}",
        f"  Failed probes: {st.failed_probe_count}",
        f"  Skipped (not on disk): {st.skipped_not_on_disk}",
        f"  Skipped (hidden — not enabled): {st.skipped_hidden_count}",
    ]
    if st.skipped_registered_probes:
        lines.append(f"  Skipped (already registered): {st.skipped_registered_probes}")
    if st.files_discovered:
        lines.append(f"  Weight files discovered: {st.files_discovered}")
        lines.append(f"  MD5 duplicates skipped: {st.files_deduped}")
    if st.skipped_unchanged:
        lines.append(f"  Unchanged (history reused): {st.skipped_unchanged}")
    if st.skipped_unchanged_probes:
        lines.append(f"  Skipped unchanged renders: {st.skipped_unchanged_probes}")
    if st.downloads_scanned:
        lines.append(f"  Downloads scanned: {st.downloads_scanned}")
        lines.append(f"  Downloads duplicates removed: {st.downloads_deduped}")
        lines.append(f"  New LoRAs added: {st.downloads_registered}")
        lines.append(f"  LoRA files with no passing model: {st.downloads_failed}")
    if st.skipped_model_probes:
        lines.append(
            f"  Base models not installed (not probed): {st.skipped_model_probes}"
        )

    newly_enabled = _changes_of(result, "newly_enabled")
    newly_supported = _changes_of(result, "newly_supported")
    passed = _changes_of(result, "passed")
    failed = _changes_of(result, "failed")
    lost = _changes_of(result, "lost_support")
    hidden = _changes_of(result, "skipped_hidden")
    not_disk = _changes_of(result, "skipped_not_on_disk")
    downloads_registered = _changes_of(result, "downloads_registered")
    downloads_deduped = _changes_of(result, "downloads_deduped")
    downloads_failed = _changes_of(result, "downloads_failed")
    enabled_keys = {(c.lora_id, c.model_key) for c in newly_enabled}
    hidden_keys = {(c.lora_id, c.model_key) for c in hidden}
    compat_only = [
        c
        for c in newly_supported
        if (c.lora_id, c.model_key) not in enabled_keys
        and (c.lora_id, c.model_key) not in hidden_keys
    ]

    def add_section(
        title: str,
        items: List[LoraCheckChange],
        *,
        with_model: bool = True,
        limit: int = 250,
    ) -> None:
        if not items:
            return
        lines.append("")
        lines.append(f"{title} ({len(items)})")
        for c in items[:limit]:
            if with_model and c.model_label:
                lines.append(f"  • {c.model_label} → {c.lora_label}")
            else:
                lines.append(f"  • {c.lora_label}")
        if len(items) > limit:
            lines.append(f"  … and {len(items) - limit} more")

    add_section("Passed probes", passed)
    add_section("Newly enabled", newly_enabled)
    add_section("New LoRAs added", downloads_registered)
    add_section("Newly compatible (not newly enabled)", compat_only)
    add_section("Failed probes", failed)
    add_section("Lost prior compatibility", lost)
    add_section("Passed but hidden (left disabled)", hidden)
    add_section("Downloads duplicates removed", downloads_deduped, with_model=False)
    add_section("LoRA files with no passing model", downloads_failed, with_model=False)
    add_section("Skipped — weights not on disk", not_disk, with_model=False, limit=80)

    lines.extend(
        [
            "",
            "Each on-disk LoRA is probed against every installed base model. Passing "
            "pairs are recorded and enabled in Settings → LoRA (unless previously Hidden).",
            "Weights are discovered under ~/.cache/image_browser/mflux_loras, "
            "~/.cache/mflux_loras (recursive), and top-level ~/Downloads "
            "*.safetensors. Duplicate files (same md5) are probed once. "
            "Unchanged files reuse prior probe history.",
            "Re-run after downloading new LoRA weights. Use Hide in Settings to "
            "keep a LoRA out of the menus.",
        ]
    )
    lines.extend(probe_elapsed_footer_lines(result))
    return lines


def format_check_loras_results_text(
    result: LoraCheckResult,
    report_paths: Optional[List[str]] = None,
) -> str:
    paths = report_paths if report_paths is not None else list(LAST_REPORT_PATHS)
    text = "\n".join(format_results_text_sections(result))
    if paths:
        text = (
            "Report file(s):\n"
            + "\n".join(f"  {p}" for p in paths)
            + "\n\n"
            + text
        )
    return text


def apply_lora_check_result(result: LoraCheckResult) -> List[str]:
    """Persist catalog state and write report (Swift bridge + headless runners)."""
    from config import get_config
    from imagegen_plugins.image_gen_persistence import save_lora_catalog_state

    settings_before = get_config().load_settings()
    if (
        result.model_support
        or result.cross_family_models
        or result.by_model
        or result.probe_history
    ):
        save_lora_catalog_state(
            model_support=result.model_support or None,
            cross_family_models=result.cross_family_models or None,
            by_model=result.by_model or None,
            probe_history=result.probe_history or None,
        )
    settings_after = get_config().load_settings()
    report_paths: List[str] = []
    try:
        primary = write_check_loras_report(
            result,
            settings_before=settings_before,
            settings_after=settings_after,
        )
        report_paths = list(LAST_REPORT_PATHS) or [str(primary)]
    except OSError as exc:
        print(f"[Check LoRAs] Report write failed: {exc}")
    return report_paths


def _report_paths() -> List[Path]:
    from config import get_config

    paths: List[Path] = []
    logs_dir = get_config().data_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    paths.append(logs_dir / "check_loras_last_run.txt")
    workspace = Path(__file__).resolve().parents[1] / ".cursor"
    workspace.mkdir(parents=True, exist_ok=True)
    paths.append(workspace / "check_loras_last_run.txt")
    return paths


def _models_with_passes(result: LoraCheckResult) -> Dict[str, Set[str]]:
    by_model: Dict[str, Set[str]] = {}
    for lora_id, models in (result.model_support or {}).items():
        for model_key in models or []:
            by_model.setdefault(str(model_key), set()).add(str(lora_id))
    for change in result.changes:
        if change.model_key and change.kind in (
            "newly_supported",
            "newly_enabled",
            "failed",
            "lost_support",
        ):
            by_model.setdefault(str(change.model_key), set()).add(str(change.lora_id))
    return by_model


def audit_settings_visibility(
    result: LoraCheckResult,
    *,
    settings: Optional[dict] = None,
) -> Dict[str, Any]:
    from config import get_config
    from imagegen_plugins.lora_catalog import (
        catalog_entries_for_model,
        get_lora_entry,
        lora_model_support,
        lora_probe_passed_for_model,
    )
    from imagegen_plugins.lora_catalog_settings import enabled_lora_ids_for_model
    from imagegen_plugins.lora_model_registry import entry_matches_lora_model

    if settings is None:
        settings = get_config().load_settings()

    ms = lora_model_support(settings)
    audits: Dict[str, Any] = {}
    models_to_audit = _models_with_passes(result)
    if Z_IMAGE_TURBO not in models_to_audit:
        z_passes = [
            lid
            for lid, models in (result.model_support or {}).items()
            if Z_IMAGE_TURBO in (models or [])
        ]
        if z_passes:
            models_to_audit[Z_IMAGE_TURBO] = set(z_passes)

    for model_key, lora_ids in sorted(models_to_audit.items()):
        grid_ids = {e.lora_id for e in catalog_entries_for_model(settings, model_key)}
        enabled_ids = list(enabled_lora_ids_for_model(model_key, settings))
        by_model_slice = (result.by_model or {}).get(model_key, {})
        pending_enabled = list(by_model_slice.get("enabled_ids") or [])

        rows: List[Dict[str, Any]] = []
        for lora_id in sorted(lora_ids):
            entry = get_lora_entry(lora_id, settings)
            probe_passed = lora_probe_passed_for_model(lora_id, model_key, settings)
            matches_model = (
                entry_matches_lora_model(entry, model_key, settings=settings)
                if entry is not None
                else False
            )
            in_grid = lora_id in grid_ids
            rows.append(
                {
                    "lora_id": lora_id,
                    "display_name": entry.display_name if entry else None,
                    "host_id": entry.host_id if entry else None,
                    "mflux_compatible": entry.mflux_compatible if entry else None,
                    "model_support": list(ms.get(lora_id, ())),
                    "probe_passed": probe_passed,
                    "entry_matches_model": matches_model,
                    "in_settings_grid": in_grid,
                    "enabled_after_save": lora_id in enabled_ids,
                    "pending_enable_in_result": lora_id in pending_enabled,
                }
            )

        audits[model_key] = {
            "model_label": lora_model_display_name(model_key),
            "passed_lora_count": len(lora_ids),
            "settings_grid_count": len(grid_ids),
            "enabled_count": len(enabled_ids),
            "pending_enabled_count": len(pending_enabled),
            "loras": rows,
        }

    return audits


def write_check_loras_report(
    result: LoraCheckResult,
    *,
    settings_before: Optional[dict] = None,
    settings_after: Optional[dict] = None,
) -> Path:
    from imagegen_plugins.lora_catalog import lora_model_support

    report_paths = _report_paths()
    primary_report = report_paths[0]
    audits = audit_settings_visibility(
        result,
        settings=settings_after,
    )
    ms_before = lora_model_support(settings_before) if settings_before else {}
    ms_after = lora_model_support(settings_after) if settings_after else {}

    lines: List[str] = [
        f"Check LoRAs report — {datetime.now().isoformat(timespec='seconds')}",
        f"Profile report: {primary_report}",
        f"Workspace copy: {report_paths[1] if len(report_paths) > 1 else primary_report}",
        "",
        "=== Summary ===",
        f"Cancelled: {result.cancelled}",
        f"GPU renders: {result.stats.gpu_probes_done}/{result.stats.probes_total}",
        f"History reused: {result.stats.skipped_unchanged_probes}",
        f"LoRAs with pass: {result.stats.supported_loras}",
        f"Newly enabled: {result.stats.newly_enabled_count}",
        f"Failed probes: {result.stats.failed_probe_count}",
        f"Skipped registered: {result.stats.skipped_registered_probes}",
        "",
        "=== model_support in result (before save) ===",
    ]
    for lid, models in sorted((result.model_support or {}).items()):
        lines.append(f"  {lid}: {list(models)}")

    lines.extend(["", "=== by_model enabled_ids in result (before save) ==="])
    for model_key, slice_ in sorted((result.by_model or {}).items()):
        enabled = slice_.get("enabled_ids") or []
        lines.append(
            f"  {lora_model_display_name(model_key)} ({model_key}): "
            f"{len(enabled)} enabled"
        )
        for lid in enabled[:50]:
            lines.append(f"    • {lid}")
        if len(enabled) > 50:
            lines.append(f"    … and {len(enabled) - 50} more")

    lines.extend(["", "=== model_support persisted (after save) ==="])
    for lid, models in sorted(ms_after.items()):
        before = list(ms_before.get(lid, ()))
        marker = " (changed)" if list(models) != before else ""
        lines.append(f"  {lid}: {list(models)}{marker}")

    lines.extend(["", "=== Settings grid visibility audit ==="])
    for model_key, audit in audits.items():
        lines.append(
            f"\n--- {audit['model_label']} ({model_key}) ---"
        )
        lines.append(
            f"Passed in run: {audit['passed_lora_count']} · "
            f"In settings grid: {audit['settings_grid_count']} · "
            f"Enabled: {audit['enabled_count']}"
        )
        missing = [
            row
            for row in audit["loras"]
            if not row["in_settings_grid"]
        ]
        if missing:
            lines.append(f"NOT in settings grid ({len(missing)}):")
            for row in missing[:80]:
                lines.append(
                    f"  • {row['lora_id']} ({row.get('display_name') or '?'}) "
                    f"probe_passed={row['probe_passed']} "
                    f"entry_matches={row['entry_matches_model']} "
                    f"host={row.get('host_id')} "
                    f"mflux_compatible={row.get('mflux_compatible')}"
                )
            if len(missing) > 80:
                lines.append(f"  … and {len(missing) - 80} more")

    lines.extend(["", "=== Changes ==="])
    for change in result.changes:
        if change.model_label:
            lines.append(
                f"  [{change.kind}] {change.model_label} → {change.lora_label}"
            )
        else:
            lines.append(f"  [{change.kind}] {change.lora_label}")

    lines.extend(probe_elapsed_footer_lines(result))

    text = "\n".join(lines) + "\n"
    written: List[str] = []
    for path in report_paths:
        try:
            path.write_text(text, encoding="utf-8")
            written.append(str(path))
        except OSError as exc:
            print(f"[Check LoRAs] Could not write report to {path}: {exc}")
    if not written:
        raise OSError(f"could not write Check LoRAs report to {report_paths}")

    global LAST_REPORT_PATHS
    LAST_REPORT_PATHS = list(written)
    print(f"[Check LoRAs] Report written to:\n  " + "\n  ".join(written))
    return Path(written[0])
