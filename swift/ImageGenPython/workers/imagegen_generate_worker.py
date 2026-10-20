#!/usr/bin/env python3
"""Persistent NDJSON worker for optimized image generation (Swift Prowser)."""

from __future__ import annotations

import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from workers.model_tasks_process_registry import register_worker_pid, unregister_worker_pid
from workers.model_tasks_worker import _stdout_emit, run_imagegen_worker_event_loop


def _read_stdin() -> str | None:
    line = sys.stdin.readline()
    if not line:
        return None
    return line


def main() -> int:
    register_worker_pid(os.getpid())
    try:
        run_imagegen_worker_event_loop(_read_stdin, _stdout_emit)
    finally:
        unregister_worker_pid(os.getpid())
    return 0


if __name__ == "__main__":
    sys.exit(main())
