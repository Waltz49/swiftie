#!/usr/bin/env python3
"""Headless CLIP text search worker (newline JSON on stdin/stdout)."""

from __future__ import annotations

import sys
import threading

_REPO_ROOT = __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop

_cancel = threading.Event()
_SORTER = None


def _cancel_check() -> bool:
    return _cancel.is_set()


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


def _get_sorter():
    global _SORTER
    if _SORTER is None:
        from search.cnn_image_similarity_sorter import CNNImageSimilaritySorter

        _SORTER = CNNImageSimilaritySorter(similarity_metric="cosine")
    return _SORTER


def _run_search(cmd: dict) -> None:
    job_id = str(cmd.get("job_id") or "")
    text_prompt = str(cmd.get("text_prompt") or "").strip()
    raw_paths = cmd.get("candidate_paths") or []
    candidate_paths = [str(p) for p in raw_paths if str(p or "").strip()]
    threshold = float(cmd.get("threshold", 0.20))
    filter_below = bool(cmd.get("filter_below_threshold", False))

    if not text_prompt:
        emit_message({"type": "error", "job_id": job_id, "message": "Empty text prompt"})
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
            _progress_emit(job_id, int(float(args[0]) * 100), 100)
        elif len(args) >= 2:
            stage = str(args[2]) if len(args) >= 3 else ""
            _progress_emit(job_id, args[0], args[1], stage)

    try:
        sorter = _get_sorter()
        similarity_threshold = threshold if threshold > 0 else None
        result, _highest = sorter.reorder_by_text_prompt(
            candidate_paths,
            text_prompt,
            progress_callback=progress_callback,
            similarity_threshold=similarity_threshold,
            filter_below_threshold=filter_below,
        )
        if _cancel.is_set():
            emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "search",
                "paths": result,
            }
        )
    except KeyboardInterrupt:
        emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
    except Exception as exc:
        emit_message({"type": "error", "job_id": job_id, "message": str(exc)})


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        global _SORTER
        _SORTER = None
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
