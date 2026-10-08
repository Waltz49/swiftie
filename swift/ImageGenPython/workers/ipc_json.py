#!/usr/bin/env python3
"""Shared newline-delimited JSON helpers for headless worker IPC."""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Callable, Dict, Iterable, Optional


def configure_profile_from_env() -> None:
    """Apply PROWSER_PROFILE for Swift-spawned headless workers."""
    profile = os.environ.get("PROWSER_PROFILE", "").strip()
    if not profile:
        return
    from config import get_config

    get_config(profile_dir=profile)


configure_profile_from_env()


def emit_message(msg: Dict[str, Any], *, stream=None) -> None:
    """Write one JSON object as a single stdout line."""
    out = stream if stream is not None else sys.stdout
    out.write(json.dumps(msg, ensure_ascii=False) + "\n")
    out.flush()


def read_line(source=None) -> Optional[str]:
    """Read one line; return None on EOF."""
    src = source if source is not None else sys.stdin
    line = src.readline()
    if not line:
        return None
    return line


def parse_command_line(line: str) -> Dict[str, Any]:
    line = (line or "").strip()
    if not line:
        raise ValueError("empty command line")
    data = json.loads(line)
    if not isinstance(data, dict):
        raise ValueError("command must be a JSON object")
    return data


def run_json_command_loop(
    read_line_fn: Callable[[], Optional[str]],
    emit_fn: Callable[[Dict[str, Any]], None],
    handle_command: Callable[[Dict[str, Any]], Any],
    *,
    ready: bool = True,
) -> None:
    """Generic stdin/stdout worker loop."""
    if ready:
        emit_fn({"type": "ready"})
    while True:
        line = read_line_fn()
        if line is None:
            break
        # readline() returns "" on EOF; without this check the loop spins at 100% CPU
        # when the parent exits without closing the worker cleanly.
        if line == "":
            break
        line = line.strip()
        if not line:
            continue
        try:
            cmd = parse_command_line(line)
        except (json.JSONDecodeError, ValueError) as exc:
            emit_fn({"type": "error", "message": f"Invalid JSON command: {exc}"})
            continue
        job_id = str(cmd.get("job_id") or "")
        try:
            result = handle_command(cmd)
            if result == "shutdown":
                break
        except Exception as exc:
            emit_fn({"type": "error", "job_id": job_id, "message": str(exc)})


def iter_stdout_json_lines(buffer: str, chunk: str) -> tuple[list[Dict[str, Any]], str]:
    """Split accumulated stdout into parsed JSON objects."""
    buffer += chunk
    messages: list[Dict[str, Any]] = []
    while "\n" in buffer:
        line, buffer = buffer.split("\n", 1)
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            messages.append(data)
    return messages, buffer
