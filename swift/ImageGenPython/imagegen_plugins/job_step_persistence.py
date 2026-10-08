#!/usr/bin/env python3
"""Atomic JSON persistence for per-copy job step queues (~/.prowser/*.json)."""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

from config import get_config

_JOB_STEP_LOCK = threading.Lock()
_JOB_QUEUE_VERSION = 1


def job_active_running_path() -> Path:
    return get_config().prowsers_home / "job_active_running.json"


def job_active_pending_path() -> Path:
    return get_config().prowsers_home / "job_active_pending.json"


def job_queue_json_path() -> Path:
    return get_config().prowsers_home / "job_queue.json"


def _atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def _read_json_file(path: Path) -> Any:
    if not path.is_file():
        return None
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def clear_job_active_running_file() -> None:
    with _JOB_STEP_LOCK:
        path = job_active_running_path()
        if path.is_file():
            try:
                path.unlink()
            except OSError:
                pass


def save_job_active_running(doc: Dict[str, Any] | None) -> None:
    with _JOB_STEP_LOCK:
        path = job_active_running_path()
        if not doc:
            if path.is_file():
                try:
                    path.unlink()
                except OSError:
                    pass
            return
        _atomic_write_json(path, doc)


def load_job_active_running() -> Dict[str, Any] | None:
    with _JOB_STEP_LOCK:
        raw = _read_json_file(job_active_running_path())
        return dict(raw) if isinstance(raw, dict) else None


def save_job_active_pending(doc: Dict[str, Any] | None) -> None:
    with _JOB_STEP_LOCK:
        path = job_active_pending_path()
        if not doc:
            if path.is_file():
                try:
                    path.unlink()
                except OSError:
                    pass
            return
        _atomic_write_json(path, doc)


def load_job_active_pending() -> Dict[str, Any] | None:
    with _JOB_STEP_LOCK:
        raw = _read_json_file(job_active_pending_path())
        return dict(raw) if isinstance(raw, dict) else None


def save_job_queue_json(
    jobs: List[Dict[str, Any]], *, active_display_index: int = 0
) -> None:
    with _JOB_STEP_LOCK:
        payload = {
            "version": _JOB_QUEUE_VERSION,
            "jobs": list(jobs),
            "active_display_index": max(0, int(active_display_index)),
        }
        _atomic_write_json(job_queue_json_path(), payload)


def load_job_queue_json() -> List[Dict[str, Any]]:
    with _JOB_STEP_LOCK:
        raw = _read_json_file(job_queue_json_path())
        if not isinstance(raw, dict):
            return []
        jobs = raw.get("jobs")
        if not isinstance(jobs, list):
            return []
        out: List[Dict[str, Any]] = []
        for item in jobs:
            if isinstance(item, dict):
                out.append(dict(item))
        return out


def load_job_queue_active_display_index() -> int:
    with _JOB_STEP_LOCK:
        raw = _read_json_file(job_queue_json_path())
        if not isinstance(raw, dict):
            return 0
        try:
            return max(0, int(raw.get("active_display_index", 0)))
        except (TypeError, ValueError):
            return 0


def clear_all_step_job_files() -> None:
    with _JOB_STEP_LOCK:
        for path in (
            job_active_running_path(),
            job_active_pending_path(),
            job_queue_json_path(),
        ):
            if path.is_file():
                try:
                    path.unlink()
                except OSError:
                    pass


def persist_step_job_files(
    *,
    running_doc: dict | None,
    pending_doc: dict | None,
    queued_job_docs: list,
    active_display_index: int = 0,
) -> None:
    """Write ~/.prowser job_active_*.json and job_queue.json atomically."""
    save_job_active_running(running_doc)
    save_job_active_pending(pending_doc)
    save_job_queue_json(
        list(queued_job_docs), active_display_index=active_display_index
    )


def _is_step_job_doc(doc: Dict[str, Any]) -> bool:
    if not isinstance(doc, dict):
        return False
    steps = doc.get("steps")
    if not isinstance(steps, list):
        return False
    if doc.get("version") is not None:
        return True
    for step in steps:
        if isinstance(step, dict) and step.get("step_id"):
            return True
    return False


def _is_legacy_job_record(doc: Dict[str, Any]) -> bool:
    """Pre-step-queue queue record stored in settings.imagegen.job_queue."""
    if not isinstance(doc, dict) or _is_step_job_doc(doc):
        return False
    values = doc.get("values")
    job_id = str(doc.get("job_id") or "").strip()
    plugin_id = str(doc.get("plugin_id") or "").strip()
    function = str(doc.get("function") or "").strip()
    return bool(job_id and plugin_id and function and isinstance(values, dict))


def _job_queue_json_payload_is_legacy(raw: Any) -> bool:
    """True when job_queue.json uses pre-step-queue records, not step job docs."""
    if raw is None:
        return False
    if isinstance(raw, list):
        if not raw:
            return False
        return any(_is_legacy_job_record(item) for item in raw if isinstance(item, dict))
    if not isinstance(raw, dict):
        return False
    if _is_legacy_job_record(raw):
        return True
    jobs = raw.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        return False
    has_step_doc = any(_is_step_job_doc(item) for item in jobs if isinstance(item, dict))
    if has_step_doc:
        return False
    return any(_is_legacy_job_record(item) for item in jobs if isinstance(item, dict))


def remove_legacy_job_queue_data() -> bool:
    """Remove legacy job queue data from disk; leave step JSON files untouched."""
    from imagegen_plugins.image_gen_persistence import remove_legacy_settings_job_queue

    removed = remove_legacy_settings_job_queue()
    with _JOB_STEP_LOCK:
        path = job_queue_json_path()
        if path.is_file():
            raw = _read_json_file(path)
            if _job_queue_json_payload_is_legacy(raw):
                try:
                    path.unlink()
                    removed = True
                except OSError:
                    pass
    return removed
