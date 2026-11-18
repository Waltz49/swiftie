#!/usr/bin/env python3
"""Human-readable reports for Check LoRAs runs."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set

from imagegen_plugins.hf_model_ids import Z_IMAGE_TURBO, lora_model_display_name
from imagegen_plugins.lora_compatibility_checker import (
    LORA_SCOPE_SELECTED,
    LoraCheckResult,
    REGISTRATION_ONLY_REGISTERED,
    REGISTRATION_SKIP_REGISTERED,
    CheckLorasOptions,
    discover_check_lora_choices,
    normalize_check_loras_probe_prompt,
    _probe_model_user_sort_key,
)

LAST_REPORT_PATHS: List[str] = []


def check_loras_results_summary_path() -> Path:
    from config import get_config

    logs_dir = get_config().data_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    return logs_dir / "check_loras_last_results.txt"


def persist_check_loras_results_text(text: str) -> None:
    """Save the user-facing results summary for Test LoRAs (Previous report in options)."""
    body = (text or "").strip()
    if not body:
        return
    path = check_loras_results_summary_path()
    try:
        path.write_text(body + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"[Check LoRAs] Could not write results summary to {path}: {exc}")


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


def _registration_mode_label(mode: str) -> str:
    if mode == REGISTRATION_SKIP_REGISTERED:
        return "Skip registered combinations"
    if mode == REGISTRATION_ONLY_REGISTERED:
        return "Only registered combinations"
    return "Ignore previous registrations"


def _list_lines(items: List[str], *, limit: Optional[int] = 40) -> List[str]:
    if not items:
        return ["    (none)"]
    lines: List[str] = []
    shown = items if limit is None else items[:limit]
    for label in shown:
        lines.append(f"    • {label}")
    if limit is not None and len(items) > limit:
        lines.append(f"    … and {len(items) - limit} more")
    return lines


def format_run_scope_lines(
    options: CheckLorasOptions,
    *,
    settings: Optional[dict] = None,
) -> List[str]:
    from config import get_config

    settings = settings or get_config().load_settings()
    choices = discover_check_lora_choices(settings, dedupe_downloads=False)
    choice_labels = {c.key: c.label for c in choices}

    model_keys = options.resolved_model_keys()
    model_keys.sort(key=_probe_model_user_sort_key)
    model_labels = [lora_model_display_name(m) for m in model_keys]

    if options.lora_scope == LORA_SCOPE_SELECTED and options.selected_lora_keys:
        lora_keys = [k for k in options.selected_lora_keys if k in choice_labels]
    else:
        lora_keys = [c.key for c in choices]
    lora_keys.sort(key=lambda k: choice_labels.get(k, k).casefold())
    lora_labels = [choice_labels.get(k, k) for k in lora_keys]

    lines: List[str] = []
    lines.append(f"Models ({len(model_labels)}):")
    lines.extend(_list_lines(model_labels, limit=None))
    lines.append("")
    lines.append(f"LoRAs ({len(lora_labels)}):")
    lines.extend(_list_lines(lora_labels, limit=None))
    lines.append("")
    lines.append("Options:")
    lines.extend(
        [
            f"  Registration: {_registration_mode_label(options.registration_mode)}",
            (
                "  Skip unchanged weights: yes"
                if options.skip_unchanged
                else "  Skip unchanged weights: no"
            ),
            (
                "  Cross-family probes: yes"
                if options.check_cross_families
                else "  Cross-family probes: no"
            ),
            (
                "  Probe prompt: "
                + normalize_check_loras_probe_prompt(options.probe_prompt)
            ),
        ]
    )
    return lines


def format_compact_summary_lines(result: LoraCheckResult) -> List[str]:
    from imagegen_plugins.lora_compatibility_checker import lora_check_work_total

    st = result.stats
    pairs_total = max(1, lora_check_work_total(st))
    pairs_tested = st.passed_probe_count + st.failed_probe_count
    lines = ["Summary"]
    lines.append(f"  LoRA–model pairs tested: {pairs_tested} of {pairs_total}")
    lines.append(f"  Newly enabled: {st.newly_enabled_count}")
    lines.append(f"  Newly compatible: {st.newly_supported_count}")
    lines.append(f"  Passed: {st.passed_probe_count}")
    lines.append(f"  Failed: {st.failed_probe_count}")
    if st.skipped_unchanged_probes:
        lines.append(f"  Skipped unchanged (history): {st.skipped_unchanged_probes}")
    if st.skipped_registered_probes:
        lines.append(f"  Skipped already registered: {st.skipped_registered_probes}")
    if st.downloads_registered:
        lines.append(f"  New LoRAs added from Downloads: {st.downloads_registered}")
    if st.downloads_removed_after_import:
        lines.append(
            f"  Removed from Downloads after import: {st.downloads_removed_after_import}"
        )
    if st.probe_cnn_user_warning:
        lines.append("")
        lines.append("Probe compare environment")
        for part in st.probe_cnn_user_warning.splitlines():
            lines.append(f"  {part}" if part else "")
    if result.elapsed_seconds > 0:
        lines.append(
            f"  Total elapsed: {format_probe_elapsed(result.elapsed_seconds)}"
        )
    return lines


def format_results_text_sections(
    result: LoraCheckResult,
    *,
    options: Optional[CheckLorasOptions] = None,
) -> List[str]:
    """User-facing results summary (Test LoRAs results dialog)."""
    lines = list(format_compact_summary_lines(result))
    if options is not None:
        lines.extend(["", *format_run_scope_lines(options)])
    return lines


def format_check_loras_results_text(
    result: LoraCheckResult,
    report_paths: Optional[List[str]] = None,
    *,
    options: Optional[CheckLorasOptions] = None,
) -> str:
    text = "\n".join(format_results_text_sections(result, options=options))
    if report_paths:
        text = text + "\n\n" + f"Debug report: {report_paths[0]}"
    return text


_check_loras_catalog_backed_up = False


def reset_check_loras_catalog_backup_state() -> None:
    global _check_loras_catalog_backed_up
    _check_loras_catalog_backed_up = False


def _ensure_check_loras_catalog_backup() -> None:
    global _check_loras_catalog_backed_up
    if _check_loras_catalog_backed_up:
        return
    from imagegen_plugins.lora_catalog_store import backup_lora_catalog_for_check_loras

    backup_lora_catalog_for_check_loras()
    _check_loras_catalog_backed_up = True


def _non_empty_mapping_slice(
    raw: Optional[Dict[str, List[str]]],
) -> Optional[Dict[str, List[str]]]:
    if not raw:
        return None
    out = {
        str(k): list(v)
        for k, v in raw.items()
        if v and isinstance(v, (list, tuple))
    }
    return out or None


def persist_lora_check_catalog_slice(
    *,
    model_support: Optional[Dict[str, List[str]]] = None,
    cross_family_models: Optional[Dict[str, List[str]]] = None,
    by_model: Optional[Dict[str, Dict[str, list]]] = None,
    probe_history: Optional[Dict[str, Dict[str, Any]]] = None,
    probed_lora_ids: Optional[Iterable[str]] = None,
    run_cancelled: bool = False,
) -> None:
    """Merge one incremental Test LoRAs slice into ``lora_catalog.json``."""
    if run_cancelled:
        return
    model_support = _non_empty_mapping_slice(model_support)
    cross_family_models = _non_empty_mapping_slice(cross_family_models)
    if not (
        model_support
        or cross_family_models
        or by_model
        or probe_history
    ):
        return
    _ensure_check_loras_catalog_backup()
    from imagegen_plugins.image_gen_persistence import save_lora_catalog_state

    save_lora_catalog_state(
        model_support=model_support,
        cross_family_models=cross_family_models,
        by_model=by_model,
        probe_history=probe_history,
        probed_lora_ids=probed_lora_ids,
    )


def apply_lora_check_result(result: LoraCheckResult) -> List[str]:
    """Persist catalog state and write report (Swift bridge + headless runners)."""
    from config import get_config

    settings_before = get_config().load_settings()
    if result.cancelled:
        print(
            "[Check LoRAs] Cancelled: skipping catalog persist "
            "(model_support, enables, and cross-family left as before this run's final save)."
        )
    elif (
        result.model_support
        or result.cross_family_models
        or result.by_model
        or result.probe_history
    ):
        persist_lora_check_catalog_slice(
            model_support=result.model_support or None,
            cross_family_models=result.cross_family_models or None,
            by_model=result.by_model or None,
            probe_history=result.probe_history or None,
            probed_lora_ids=result.probed_lora_ids or None,
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
    ]
    if result.probe_effect_threshold_lines:
        lines.extend(result.probe_effect_threshold_lines)
    if result.probe_effect_outcome_lines:
        lines.extend(result.probe_effect_outcome_lines)
    if result.probe_cnn_environment_lines:
        lines.extend(result.probe_cnn_environment_lines)
    lines.extend([
        "=== model_support in result (before save) ===",
    ])
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
