#!/usr/bin/env python3
"""Headless known-faces settings helpers for Swift UI (newline JSON on stdin/stdout)."""

from __future__ import annotations

import base64
import io
import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop


PLACEHOLDER_ADD = "Add..."


def _is_available(cmd: dict) -> None:
    job_id = str(cmd.get("job_id") or "")
    try:
        from faces.face_engine import is_available

        ok = bool(is_available())
    except Exception:
        ok = False
    emit_message({"type": "result", "job_id": job_id, "command": "is_available", "available": ok})


def _suggest_name(encoding, subjects) -> str:
    try:
        from faces.face_engine import compare_faces
    except Exception:
        return PLACEHOLDER_ADD
    if not encoding:
        return PLACEHOLDER_ADD
    for subject in subjects or []:
        name = (subject.get("name") or "").strip()
        if not name:
            continue
        samples = subject.get("samples") or []
        known = [s.get("embedding") for s in samples if s.get("embedding")]
        if not known:
            continue
        if compare_faces(known_encodings=[e for e in known if e], unknown_encoding=encoding):
            return name
    return PLACEHOLDER_ADD


def _detect_faces(cmd: dict) -> None:
    from faces.face_engine import get_faces_with_locations_and_rgb_from_path, is_available
    from quick_person_search import _QUICK_PERSON_ENCODING_MODEL

    job_id = str(cmd.get("job_id") or "")
    image_path = str(cmd.get("image_path") or "").strip()
    subjects = cmd.get("subjects") or []
    if not image_path:
        emit_message({"type": "error", "job_id": job_id, "message": "No image path"})
        return
    if not is_available():
        emit_message({"type": "error", "job_id": job_id, "message": "Face recognition is not available."})
        return
    detections, rgb = get_faces_with_locations_and_rgb_from_path(
        image_path, encoding_model=_QUICK_PERSON_ENCODING_MODEL
    )
    if not detections:
        emit_message({"type": "error", "job_id": job_id, "message": "No faces were detected in the selected image."})
        return
    preview_b64 = ""
    if rgb is not None:
        try:
            from PIL import Image

            img = Image.fromarray(rgb)
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=85)
            preview_b64 = base64.b64encode(buf.getvalue()).decode("ascii")
        except Exception:
            preview_b64 = ""
    faces = []
    for trbl, emb in detections:
        faces.append({
            "trbl": [int(trbl[0]), int(trbl[1]), int(trbl[2]), int(trbl[3])],
            "embedding": list(emb),
            "suggested_name": _suggest_name(emb, subjects),
        })
    emit_message({
        "type": "result",
        "job_id": job_id,
        "command": "detect_faces",
        "image_path": image_path,
        "preview_b64": preview_b64,
        "faces": faces,
    })


def _ensure_thumbnails(cmd: dict) -> None:
    from faces.face_sample_thumbnail import ensure_face_sample_thumbnail

    job_id = str(cmd.get("job_id") or "")
    raw = cmd.get("samples") or []
    built = 0
    for item in raw:
        if not isinstance(item, dict):
            continue
        path = str(item.get("path") or "")
        emb = item.get("embedding")
        if not isinstance(emb, list) or len(emb) != 128:
            continue
        try:
            px = ensure_face_sample_thumbnail(path, emb)
            if px is not None and not px.isNull():
                built += 1
        except Exception:
            pass
    emit_message({
        "type": "result",
        "job_id": job_id,
        "command": "ensure_thumbnails",
        "built": built,
    })


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        return "shutdown"
    if command == "is_available":
        _is_available(cmd)
        return None
    if command == "detect_faces":
        _detect_faces(cmd)
        return None
    if command == "ensure_thumbnails":
        _ensure_thumbnails(cmd)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
