#!/usr/bin/env python3
"""Headless quick-person face encoding for Swift UI (newline JSON on stdin/stdout)."""

from __future__ import annotations

import base64
import io
import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop


def _encode_faces(cmd: dict) -> None:
    from faces.face_engine import get_faces_with_locations_and_rgb_from_path, is_available
    from quick_person_search import _QUICK_PERSON_ENCODING_MODEL

    job_id = str(cmd.get("job_id") or "")
    paths = [str(p) for p in (cmd.get("image_paths") or []) if str(p or "").strip()]
    if not paths:
        raise ValueError("encode_faces requires image_paths")
    if not is_available():
        emit_message({"type": "error", "job_id": job_id, "message": "Face recognition is not available."})
        return

    results = []
    for path in paths:
        detections, rgb = get_faces_with_locations_and_rgb_from_path(
            path, encoding_model=_QUICK_PERSON_ENCODING_MODEL
        )
        faces = []
        for trbl, emb in detections or []:
            faces.append({
                "trbl": [int(trbl[0]), int(trbl[1]), int(trbl[2]), int(trbl[3])],
                "embedding": list(emb),
            })
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
        results.append({"path": path, "faces": faces, "preview_b64": preview_b64})

    emit_message({"type": "result", "job_id": job_id, "command": "encode_faces", "images": results})


def _scale_cover_pil(image, size: int):
    from PIL import Image

    w, h = image.size
    if w <= 0 or h <= 0:
        return None
    scale = max(size / w, size / h)
    new_w = max(1, int(round(w * scale)))
    new_h = max(1, int(round(h * scale)))
    resized = image.resize((new_w, new_h), Image.Resampling.LANCZOS)
    left = max(0, (new_w - size) // 2)
    top = max(0, (new_h - size) // 2)
    return resized.crop((left, top, left + size, top + size))


def _write_face_sample_thumb_files(image_path: str, pil_image, face_key: str) -> None:
    import json
    import os

    from faces.face_sample_cache import _by_face_key_dir, _index_key, _index_path, _thumb_path

    try:
        st = os.stat(image_path)
        mtime, size = st.st_mtime, st.st_size
    except OSError:
        mtime, size = 0, 0
    thumb_path = _thumb_path(image_path, face_key)
    thumb_path.parent.mkdir(parents=True, exist_ok=True)
    pil_image.save(str(thumb_path), "PNG")
    idx_path = _index_path()
    index = {}
    if idx_path.exists():
        try:
            with open(idx_path, "r", encoding="utf-8") as f:
                index = json.load(f)
        except (json.JSONDecodeError, OSError):
            index = {}
    index[_index_key(image_path, face_key)] = {"mtime": mtime, "size": size}
    with open(idx_path, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=0)
    by_fk = _by_face_key_dir() / f"{face_key}.png"
    pil_image.save(str(by_fk), "PNG")


def _headless_ensure_face_sample_thumbnail(image_path: str, embedding: list) -> bool:
    """Build/cache a 96x96 face thumb without Qt (headless worker safe)."""
    import os

    from PIL import Image

    from faces.face_engine import face_distance, get_faces_with_locations_and_rgb_from_path
    from faces.face_sample_cache import _by_face_key_dir, _thumb_path, embedding_to_face_key
    from quick_person_search import _QUICK_PERSON_ENCODING_MODEL

    if not image_path or not os.path.exists(image_path):
        return False
    if not embedding or len(embedding) != 128:
        return False
    face_key = embedding_to_face_key(embedding)
    if not face_key:
        return False
    for ck in (face_key, f"{face_key}_L"):
        if _thumb_path(image_path, ck).exists():
            return True
        if (_by_face_key_dir() / f"{ck}.png").exists():
            return True

    detections, rgb = get_faces_with_locations_and_rgb_from_path(
        image_path, encoding_model=_QUICK_PERSON_ENCODING_MODEL
    )
    if rgb is None:
        return False
    matched_loc = None
    if len(detections) == 1:
        matched_loc = detections[0][0]
    else:
        best_loc = None
        best_d = None
        for loc, enc in detections or []:
            try:
                d = face_distance([enc], embedding)
            except Exception:
                continue
            if d is None:
                continue
            if best_d is None or d < best_d:
                best_d = d
                best_loc = loc
        if best_loc is not None and best_d is not None and best_d <= 0.6:
            matched_loc = best_loc

    pil_src = Image.fromarray(rgb)
    pad = 10
    if matched_loc:
        top, right, bottom, left = [int(v) for v in matched_loc]
        h0, w0 = pil_src.size[1], pil_src.size[0]
        left_p = max(0, left - pad)
        top_p = max(0, top - pad)
        right_p = min(w0, right + pad)
        bottom_p = min(h0, bottom + pad)
        if right_p > left_p and bottom_p > top_p:
            pil_src = pil_src.crop((left_p, top_p, right_p, bottom_p))
    thumb = _scale_cover_pil(pil_src, 96)
    if thumb is None:
        return False
    _write_face_sample_thumb_files(image_path, thumb, face_key)
    return True


def _save_quick_person(cmd: dict) -> None:
    from quick_person_search import _replace_all_samples, _subject_id_for_quick_person

    job_id = str(cmd.get("job_id") or "")
    raw_samples = cmd.get("samples") or []
    path_embeddings = []
    for item in raw_samples:
        if not isinstance(item, dict):
            continue
        path = str(item.get("path") or "").strip()
        emb = item.get("embedding")
        if not path or not isinstance(emb, list) or len(emb) != 128:
            continue
        path_embeddings.append((path, [float(x) for x in emb]))
    if not path_embeddings:
        emit_message({"type": "error", "job_id": job_id, "message": "No valid face samples to save."})
        return
    sid = _subject_id_for_quick_person()
    if not sid:
        emit_message({
            "type": "error",
            "job_id": job_id,
            "message": 'Could not create or find the "Z Quick Person" person.',
        })
        return
    if not _replace_all_samples(sid, path_embeddings):
        emit_message({"type": "error", "job_id": job_id, "message": "Could not save the face samples."})
        return
    for path, emb in path_embeddings:
        try:
            _headless_ensure_face_sample_thumbnail(path, emb)
        except Exception:
            pass
    emit_message({
        "type": "result",
        "job_id": job_id,
        "command": "save_quick_person",
        "subject_id": sid,
    })


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        return "shutdown"
    if command == "encode_faces":
        _encode_faces(cmd)
        return None
    if command == "save_quick_person":
        _save_quick_person(cmd)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
