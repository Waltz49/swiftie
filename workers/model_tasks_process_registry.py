#!/usr/bin/env python3
"""Track and reap model_tasks_worker subprocess PIDs (macOS dev + frozen)."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
from typing import Iterable

_REGISTRY_LOCK = threading.Lock()
_TRACKED_PIDS: set[int] = set()

_WORKER_MARKERS = (
    "workers.model_tasks_worker",
    "--model-tasks-worker",
)


def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def register_worker_pid(pid: int) -> None:
    pid = int(pid)
    if pid <= 0:
        return
    with _REGISTRY_LOCK:
        _TRACKED_PIDS.add(pid)


def unregister_worker_pid(pid: int) -> None:
    pid = int(pid)
    if pid <= 0:
        return
    with _REGISTRY_LOCK:
        _TRACKED_PIDS.discard(pid)


def _command_matches_worker(command: str) -> bool:
    return any(marker in command for marker in _WORKER_MARKERS)


def list_model_tasks_worker_processes() -> list[tuple[int, int, str]]:
    """Return (pid, ppid, command) for matching worker processes."""
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,ppid,command"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return []
    if result.returncode != 0:
        return []
    rows: list[tuple[int, int, str]] = []
    for line in result.stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        command = parts[2]
        if not _command_matches_worker(command):
            continue
        rows.append((pid, ppid, command))
    return rows


def terminate_worker_pid(
    pid: int,
    *,
    grace_sec: float = 2.0,
    force_wait_sec: float = 3.0,
) -> bool:
    """SIGTERM then SIGKILL. Returns True when the pid is no longer alive."""
    pid = int(pid)
    if pid <= 0 or not is_pid_alive(pid):
        unregister_worker_pid(pid)
        return True
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        unregister_worker_pid(pid)
        return True
    except OSError:
        pass

    deadline = time.monotonic() + max(0.0, grace_sec)
    while time.monotonic() < deadline:
        if not is_pid_alive(pid):
            unregister_worker_pid(pid)
            return True
        time.sleep(0.1)

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        unregister_worker_pid(pid)
        return True
    except OSError:
        pass

    kill_deadline = time.monotonic() + max(0.0, force_wait_sec)
    while time.monotonic() < kill_deadline:
        if not is_pid_alive(pid):
            unregister_worker_pid(pid)
            return True
        time.sleep(0.1)
    return not is_pid_alive(pid)


def reap_orphan_model_tasks_workers(
    *,
    keep_pids: Iterable[int] | None = None,
) -> list[int]:
    """Kill worker processes orphaned by a prior prowser run (PPID 1 or dead parent)."""
    own_pid = os.getpid()
    keep = {int(p) for p in (keep_pids or ()) if int(p) > 0}
    killed: list[int] = []
    for pid, ppid, _command in list_model_tasks_worker_processes():
        if pid == own_pid or pid in keep:
            continue
        if ppid != 1 and is_pid_alive(ppid):
            continue
        if terminate_worker_pid(pid):
            killed.append(pid)
        else:
            print(
                f"[model_tasks] could not reap orphan worker pid={pid} ppid={ppid}",
                file=sys.stderr,
                flush=True,
            )
    return killed
