#!/usr/bin/env python3
"""Headless Whisper transcription worker (newline JSON on stdin/stdout)."""

from __future__ import annotations

import os
import sys
import threading

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop

_cancel = threading.Event()


def _transcribe_wav(wav_path: str) -> str:
    from whisper_voice_input import is_whisper_voice_input_available

    if not is_whisper_voice_input_available():
        raise RuntimeError("faster-whisper dependencies are not installed")

    from whisper_voice_input import _get_whisper_model, transcribe_audio
    from pathlib import Path
    import wave
    import numpy as np

    model = _get_whisper_model()
    with wave.open(wav_path, "rb") as wf:
        frames = wf.readframes(wf.getnframes())
        pcm = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    return transcribe_audio(model, pcm)


def _run_transcribe(cmd: dict) -> None:
    job_id = str(cmd.get("job_id") or "")
    wav_path = str(cmd.get("wav_path") or "")
    if not wav_path or not os.path.exists(wav_path):
        raise ValueError("transcribe requires existing wav_path")

    _cancel.clear()
    emit_message({"type": "job_started", "job_id": job_id, "command": "transcribe"})
    if _cancel.is_set():
        emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
        return
    text = _transcribe_wav(wav_path)
    if _cancel.is_set():
        emit_message({"type": "error", "job_id": job_id, "message": "Cancelled"})
        return
    if not text.strip():
        emit_message({"type": "error", "job_id": job_id, "message": "Empty transcription"})
        return
    emit_message(
        {
            "type": "result",
            "job_id": job_id,
            "command": "transcribe",
            "text": text.strip(),
        }
    )


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        return "shutdown"
    if command == "cancel":
        _cancel.set()
        return None
    if command == "transcribe":
        _run_transcribe(cmd)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
