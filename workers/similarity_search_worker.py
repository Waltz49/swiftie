#!/usr/bin/env python3
"""Headless CNN similarity search worker (newline JSON on stdin/stdout)."""

from __future__ import annotations

import os
import sys
import threading

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop

_cancel = threading.Event()
_SORTER = None
_SORTER_METRIC = None


def _cancel_check() -> bool:
    return _cancel.is_set()


def _get_sorter(similarity_metric: str):
    """Reuse one CNNImageSimilaritySorter so ResNet stays loaded between searches."""
    global _SORTER, _SORTER_METRIC
    metric = similarity_metric if similarity_metric != "clip" else "cosine"
    if _SORTER is None or _SORTER_METRIC != metric:
        from search.cnn_image_similarity_sorter import CNNImageSimilaritySorter
        _SORTER = CNNImageSimilaritySorter(similarity_metric=metric)
        _SORTER_METRIC = metric
    return _SORTER


def _progress_emit(job_id: str, completed, total, stage: str = "") -> None:
    payload = {
        "type": "progress",
        "job_id": job_id,
        "current": int(completed) if completed is not None else 0,
        "total": int(total) if total is not None else 0,
    }
    if stage:
        payload["stage"] = stage
    emit_message(payload)


def _run_search(cmd: dict) -> None:
    job_id = str(cmd.get("job_id") or "")
    raw_refs = cmd.get("reference_paths") or []
    raw_candidates = cmd.get("candidate_paths") or []
    reference_paths = [str(p) for p in raw_refs if str(p or "").strip()]
    candidate_paths = [str(p) for p in raw_candidates if str(p or "").strip()]
    similarity_metric = str(cmd.get("similarity_metric") or "cosine")

    if not reference_paths:
        emit_message({"type": "error", "job_id": job_id, "message": "No reference images"})
        return
    if not candidate_paths:
        emit_message({"type": "error", "job_id": job_id, "message": "No candidate images"})
        return

    _cancel.clear()
    emit_message({"type": "job_started", "job_id": job_id, "command": "search"})

    def progress_callback(*args):
        if _cancel.is_set():
            raise KeyboardInterrupt("Cancelled")
        if len(args) == 1:
            value = float(args[0])
            _progress_emit(job_id, int(value * 100), 100)
        elif len(args) >= 2:
            stage = str(args[2]) if len(args) >= 3 else ""
            _progress_emit(job_id, args[0], args[1], stage)

    try:
        sorter = _get_sorter(similarity_metric)
        ref = reference_paths if len(reference_paths) > 1 else reference_paths[0]
        ordered = sorter.reorder_by_similarity(
            candidate_paths,
            ref,
            progress_callback=progress_callback,
            progress_dialog=None,
        )
        if _cancel.is_set():
            emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "search",
                "paths": ordered,
            }
        )
    except KeyboardInterrupt:
        emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
    except Exception as exc:
        emit_message({"type": "error", "job_id": job_id, "message": str(exc)})


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        global _SORTER, _SORTER_METRIC
        _SORTER = None
        _SORTER_METRIC = None
        return "shutdown"
    if command == "cancel":
        _cancel.set()
        return None
    if command == "search":
        _run_search(cmd)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    emit_message({"type": "ready"})
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
