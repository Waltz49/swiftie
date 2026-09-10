#!/usr/bin/env python3
"""Headless face scan worker (newline JSON on stdin/stdout)."""

from __future__ import annotations

import os
import sys
import threading

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop

_cancel = threading.Event()


def _cancel_check() -> bool:
    return _cancel.is_set()


def _run_scan(cmd: dict) -> None:
    from faces.face_gathering_coordinator import set_foreground_face_scan_active
    from faces.face_scan_runner import run_scan

    job_id = str(cmd.get("job_id") or "")
    root_dir = str(cmd.get("directory") or "")
    if not root_dir:
        raise ValueError("scan requires directory")
    max_depth = int(cmd.get("max_depth") or 1)
    raw_paths = cmd.get("image_paths")
    image_paths = None
    if isinstance(raw_paths, list):
        image_paths = [str(p) for p in raw_paths if str(p or "").strip()]

    _cancel.clear()
    emit_message({"type": "job_started", "job_id": job_id, "command": "scan"})
    set_foreground_face_scan_active(True)
    try:

        def progress(current: int, total: int, path: str, processed: bool) -> None:
            emit_message(
                {
                    "type": "progress",
                    "job_id": job_id,
                    "current": current,
                    "total": total,
                    "path": path,
                    "processed": processed,
                }
            )

        count = run_scan(
            root_dir,
            max_depth,
            progress,
            _cancel_check,
            image_paths_override=image_paths,
        )
        if _cancel.is_set():
            emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "scan",
                "faces_cached": count,
            }
        )
    finally:
        set_foreground_face_scan_active(False)


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        return "shutdown"
    if command == "cancel":
        _cancel.set()
        return None
    if command == "scan":
        _run_scan(cmd)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
