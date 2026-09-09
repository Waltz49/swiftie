#!/usr/bin/env python3
"""Shared MFLUX stepwise PNG watching and progress JSON for model_tasks_worker."""

from __future__ import annotations

import os
import re
import shutil
import tempfile
import threading
import time
from typing import Any, Callable, Dict, Optional, Set, Tuple

from prowser_temp_files import prowser_mkdtemp

_MFLUX_STEPWISE_RE = re.compile(r"^seed_(\d+)_step(\d+)of(\d+)\.png$", re.IGNORECASE)
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
_MIN_PNG_SIZE = 64
_STEPWISE_FLUSH_TIMEOUT_S = 30.0


def _generation_cancelled(stop_event: threading.Event | None = None) -> bool:
    if stop_event is not None and stop_event.is_set():
        return True
    try:
        from workers.model_tasks_worker import generation_cancel_requested

        return generation_cancel_requested()
    except Exception:
        return False


def emit_mflux_progress(
    output_path: str | None = None,
    *,
    step: int | None = None,
    step_total: int | None = None,
) -> None:
    msg: Dict[str, Any] = {"type": "progress"}
    if output_path:
        msg["path"] = output_path
    if step is not None:
        msg["step"] = int(step)
    if step_total is not None:
        msg["step_total"] = int(step_total)
    from workers.model_tasks_worker import emit_worker_message

    emit_worker_message(msg)


def atomic_copy2(src: str, dst: str) -> None:
    """Copy src to dst atomically via a temp file in dst's directory."""
    dst_dir = os.path.dirname(os.path.abspath(dst)) or "."
    os.makedirs(dst_dir, exist_ok=True)
    suffix = os.path.splitext(dst)[1] or ".png"
    fd, tmp_path = tempfile.mkstemp(
        prefix=".imagegen-progress-",
        suffix=suffix,
        dir=dst_dir,
    )
    os.close(fd)
    replaced = False
    try:
        shutil.copy2(src, tmp_path)
        os.replace(tmp_path, dst)
        replaced = True
    finally:
        if not replaced:
            try:
                if os.path.isfile(tmp_path):
                    os.unlink(tmp_path)
            except OSError:
                pass


def _png_looks_complete(path: str) -> bool:
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if size < _MIN_PNG_SIZE:
        return False
    try:
        with open(path, "rb") as f:
            if f.read(8) != _PNG_MAGIC:
                return False
            f.seek(size - 8)
            return f.read(4) == b"IEND"
    except OSError:
        return False


def _wait_for_stable_png(
    path: str,
    *,
    stable_secs: float = 0.2,
    poll: float = 0.05,
    timeout: float = 10.0,
    stop_event: threading.Event | None = None,
) -> bool:
    deadline = time.monotonic() + timeout
    last_size = -1
    stable_since: float | None = None
    while time.monotonic() < deadline:
        if _generation_cancelled(stop_event):
            return False
        try:
            size = os.path.getsize(path)
        except FileNotFoundError:
            last_size = -1
            stable_since = None
            time.sleep(poll)
            continue
        except OSError:
            return False
        if not _png_looks_complete(path):
            last_size = -1
            stable_since = None
            time.sleep(poll)
            continue
        if size != last_size:
            last_size = size
            stable_since = time.monotonic()
        elif (
            stable_since is not None
            and time.monotonic() - stable_since >= stable_secs
        ):
            return True
        time.sleep(poll)
    return False


def _parse_stepwise_name(name: str) -> Optional[Tuple[int, int, int]]:
    m = _MFLUX_STEPWISE_RE.match(name)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def _stepwise_steps_seen(seen: Set[str], seed: int) -> Set[int]:
    steps: Set[int] = set()
    for name in seen:
        parsed = _parse_stepwise_name(name)
        if parsed is None:
            continue
        file_seed, step_num, _total = parsed
        if file_seed == seed:
            steps.add(step_num)
    return steps


def _stepwise_drain_complete(seen: Set[str], seed: int, expected_steps: int) -> bool:
    if expected_steps <= 1:
        return True
    got = _stepwise_steps_seen(seen, seed)
    return all(step in got for step in range(1, expected_steps + 1))


def _collect_stepwise_progress(
    stepwise_dir: str,
    output_path: str | None,
    seed: int,
    seen: Set[str],
    *,
    stop_event: threading.Event | None = None,
    stable_timeout: float = 2.0,
) -> int:
    """Scan stepwise_dir once; return count of newly emitted step PNGs."""
    added = 0
    try:
        names = os.listdir(stepwise_dir)
    except OSError:
        return 0
    for name in sorted(names):
        if name in seen or "composite" in name.lower():
            continue
        parsed = _parse_stepwise_name(name)
        if parsed is None:
            continue
        file_seed, step_num, total = parsed
        if file_seed != seed or step_num > total:
            continue
        full = os.path.join(stepwise_dir, name)
        if not os.path.isfile(full):
            continue
        if not _png_looks_complete(full):
            continue
        if not _wait_for_stable_png(
            full,
            stop_event=stop_event,
            timeout=stable_timeout,
        ):
            continue
        try:
            if output_path:
                atomic_copy2(full, output_path)
            seen.add(name)
            emit_mflux_progress(
                output_path if output_path else None,
                step=step_num,
                step_total=total,
            )
            added += 1
        except OSError:
            pass
    return added


def watch_stepwise_to_output(
    stepwise_dir: str,
    output_path: str | None,
    seed: int,
    stop_event: threading.Event,
    seen: Set[str],
    poll_interval: float = 0.25,
) -> None:
    """Watch MFLUX step PNGs; optionally copy to output_path and emit step progress."""
    while not _generation_cancelled(stop_event):
        _collect_stepwise_progress(
            stepwise_dir,
            output_path,
            seed,
            seen,
            stop_event=stop_event,
        )
        time.sleep(poll_interval)


def flush_stepwise_to_output(
    stepwise_dir: str,
    output_path: str | None,
    seed: int,
    seen: Set[str],
    *,
    expected_steps: int | None = None,
    timeout: float = _STEPWISE_FLUSH_TIMEOUT_S,
    poll_interval: float = 0.25,
) -> None:
    """Pick up step PNGs still flushing after generate_image returns."""
    deadline = time.monotonic() + timeout
    idle_passes = 0
    while time.monotonic() < deadline:
        if _generation_cancelled(None):
            return
        added = _collect_stepwise_progress(
            stepwise_dir,
            output_path,
            seed,
            seen,
            stop_event=None,
            stable_timeout=10.0,
        )
        if expected_steps is not None and _stepwise_drain_complete(
            seen, seed, expected_steps
        ):
            return
        if added:
            idle_passes = 0
        else:
            idle_passes += 1
            if idle_passes >= 4:
                return
        time.sleep(poll_interval)


def stepwise_dirs_for_run(
    steps: int,
    output_path: str,
) -> tuple[str | None, str | None]:
    """Return (stepwise_dir, progressive_output_path) when steps > 1.

    stepwise_dir is always created for steps > 1 so MFLUX callbacks and step
    progress still run. progressive_output_path always targets the job output;
    the UI gates whether step updates are shown in browse.
    """
    if steps > 1:
        return prowser_mkdtemp(prefix="imagegen-mflux-stepwise-"), output_path
    return None, None


def run_with_stepwise_watcher(
    *,
    seed: int,
    stepwise_dir: str | None,
    progressive_output_path: str | None,
    run: Callable[[], None],
    expected_steps: int | None = None,
) -> None:
    stop_watcher = threading.Event()
    seen: Set[str] = set()
    watcher: threading.Thread | None = None
    if stepwise_dir:
        watcher = threading.Thread(
            target=watch_stepwise_to_output,
            args=(
                stepwise_dir,
                progressive_output_path,
                seed,
                stop_watcher,
                seen,
            ),
            daemon=True,
        )
        watcher.start()
    try:
        run()
    finally:
        if stepwise_dir and not _generation_cancelled(stop_watcher):
            flush_stepwise_to_output(
                stepwise_dir,
                progressive_output_path,
                seed,
                seen,
                expected_steps=expected_steps,
            )
        if watcher is not None:
            stop_watcher.set()
            watcher.join(timeout=60)


def finalize_stepwise_progress(output_path: str, steps: int) -> None:
    if steps > 1:
        emit_mflux_progress(output_path, step=steps, step_total=steps)


def cleanup_stepwise_dir(stepwise_dir: str | None) -> None:
    if stepwise_dir:
        shutil.rmtree(stepwise_dir, ignore_errors=True)
