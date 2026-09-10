#!/usr/bin/env python3
"""Headless person/face search worker (newline JSON on stdin/stdout)."""

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


def _paths_missing_face_cache(paths: list[str], sample_limit: int = 30) -> list[str]:
    from faces.face_cache import get_encodings

    missing = []
    for path in paths[:sample_limit]:
        try:
            if not get_encodings(path):
                missing.append(path)
        except Exception:
            missing.append(path)
    if missing:
        return missing
    # Sample looked clean; still scan any later paths that lack cache when matching.
    return []


def _scan_paths(paths: list[str], job_id: str) -> None:
    if not paths:
        return
    from faces.face_scan_runner import run_scan

    root = os.path.dirname(paths[0]) or os.path.expanduser("~")

    def progress_callback(current, total, _path, _processed):
        _progress_emit(job_id, current, total, "scanning_faces")

    run_scan(
        root,
        0,
        progress_callback,
        _cancel_check,
        image_paths_override=paths,
    )


def _match_paths(paths: list[str], known_encodings: list, job_id: str) -> list[str]:
    from faces.face_cache import get_encodings
    from faces.face_engine import compare_faces, face_mean_distance

    matching_with_dist = []
    total = len(paths)
    for i, path in enumerate(paths):
        if _cancel_check():
            raise KeyboardInterrupt("Cancelled")
        if i % 8 == 0:
            _progress_emit(job_id, i, total, "matching")
        try:
            encodings = get_encodings(path)
        except Exception:
            continue
        if not encodings:
            continue
        best_mean = None
        for enc in encodings:
            if compare_faces(known_encodings, enc):
                dist = face_mean_distance(known_encodings, enc)
                if dist is not None and (best_mean is None or dist < best_mean):
                    best_mean = dist
        if best_mean is not None:
            matching_with_dist.append((path, best_mean))

    matching_with_dist.sort(key=lambda item: item[1])
    return [path for path, _ in matching_with_dist]


def _run_search(cmd: dict) -> None:
    from faces.known_faces_manager import get_subject

    job_id = str(cmd.get("job_id") or "")
    subject_id = str(cmd.get("subject_id") or "")
    raw_paths = cmd.get("candidate_paths") or []
    candidate_paths = [str(p) for p in raw_paths if str(p or "").strip()]
    scan_missing = bool(cmd.get("scan_missing", True))

    if not subject_id:
        emit_message({"type": "error", "job_id": job_id, "message": "No person selected"})
        return
    if not candidate_paths:
        emit_message({"type": "error", "job_id": job_id, "message": "No candidate images"})
        return

    subject = get_subject(subject_id)
    if not subject or not subject.get("samples"):
        emit_message(
            {
                "type": "error",
                "job_id": job_id,
                "message": "No face samples found for this person.",
            }
        )
        return

    known_encodings = [
        s["embedding"] for s in subject.get("samples", []) if s.get("embedding")
    ]
    if not known_encodings:
        emit_message(
            {
                "type": "error",
                "job_id": job_id,
                "message": "No face encodings for this person.",
            }
        )
        return

    _cancel.clear()
    emit_message({"type": "job_started", "job_id": job_id, "command": "search"})

    try:
        if scan_missing:
            sample_missing = _paths_missing_face_cache(candidate_paths)
            if sample_missing:
                _scan_paths(candidate_paths, job_id)

        ordered = _match_paths(candidate_paths, known_encodings, job_id)
        if _cancel.is_set():
            emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        emit_message(
            {
                "type": "result",
                "job_id": job_id,
                "command": "search",
                "paths": ordered,
                "person_name": subject.get("name") or "",
            }
        )
    except KeyboardInterrupt:
        emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
    except Exception as exc:
        emit_message({"type": "error", "job_id": job_id, "message": str(exc)})


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
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
