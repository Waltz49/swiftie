#!/usr/bin/env python3
"""Headless LM Studio chat worker (newline JSON on stdin/stdout)."""

from __future__ import annotations

import os
import sys
import threading

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.ipc_json import emit_message, run_json_command_loop

_cancel = threading.Event()


def _request_cancel() -> None:
    _cancel.set()


def _clear_cancel() -> None:
    _cancel.clear()


def _messages_from_payload(raw_messages) -> list:
    from chat_plugins.chat_session import ChatMessage

    out: list[ChatMessage] = []
    if not isinstance(raw_messages, list):
        return out
    for item in raw_messages:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "user")
        if role not in ("user", "assistant"):
            role = "user"
        text = str(item.get("text") or "")
        paths = item.get("image_paths") or []
        if not isinstance(paths, list):
            paths = []
        out.append(
            ChatMessage(
                role=role,
                text=text,
                image_paths=[str(p) for p in paths if str(p or "").strip()],
            )
        )
    return out


def _run_chat(cmd: dict, emit) -> None:
    from chat_plugins.chat_lmstudio import (
        CHAT_REJECTION_MAX_RETRIES,
        chat_response_contains_rejected_phrase,
        finalize_chat_response,
        stream_chat_response,
    )

    job_id = str(cmd.get("job_id") or "")
    messages = _messages_from_payload(cmd.get("messages"))
    system_prompt = str(cmd.get("system_prompt") or "")
    if not messages:
        raise ValueError("chat requires messages")

    _clear_cancel()
    emit({"type": "job_started", "job_id": job_id, "command": "chat"})

    for attempt in range(1, CHAT_REJECTION_MAX_RETRIES + 1):
        if _cancel.is_set():
            emit({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        accumulated = ""
        suppress_auto_image_gen = False
        retry_stream = False
        for piece in stream_chat_response(messages, system_prompt=system_prompt):
            if _cancel.is_set():
                emit({"type": "error", "job_id": job_id, "message": "Cancelled"})
                return
            accumulated += piece
            rejected = chat_response_contains_rejected_phrase(accumulated)
            if rejected:
                if attempt < CHAT_REJECTION_MAX_RETRIES:
                    emit({"type": "restarted", "job_id": job_id})
                    retry_stream = True
                    break
                suppress_auto_image_gen = True
            emit({"type": "chunk", "job_id": job_id, "text": piece})
        if _cancel.is_set():
            emit({"type": "error", "job_id": job_id, "message": "Cancelled"})
            return
        if retry_stream:
            continue
        final = finalize_chat_response(accumulated)
        if not final:
            emit({"type": "error", "job_id": job_id, "message": "Empty response"})
            return
        emit(
            {
                "type": "result",
                "job_id": job_id,
                "command": "chat",
                "text": final,
                "suppress_auto_image_gen": suppress_auto_image_gen,
            }
        )
        return


def _handle_command(cmd: dict):
    command = cmd.get("command")
    if command == "shutdown":
        return "shutdown"
    if command == "cancel":
        _request_cancel()
        return None
    if command == "chat":
        _run_chat(cmd, emit_message)
        return None
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    run_json_command_loop(sys.stdin.readline, emit_message, _handle_command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
