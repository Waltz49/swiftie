"""Minimal worker helpers for vendored pipeline scripts (Swift ImageGenPython bundle)."""
from __future__ import annotations

import time
from typing import Any


def generation_cancel_requested() -> bool:
    return False


def emit_worker_message(_msg: dict[str, Any]) -> None:
    pass


def perf_log_kv(event: str, **fields: Any) -> None:
    pass


def flux_prompt_system_message() -> str:
    return ""


class PerfTimer:
    """Context manager: logs elapsed on exit when perf debug is on (no-op in Swift bundle)."""

    def __init__(self, event: str, **fields: Any) -> None:
        self._event = event
        self._fields = dict(fields)
        self._t0: float | None = None

    def __enter__(self) -> PerfTimer:
        self._t0 = time.perf_counter()
        perf_log_kv(f"{self._event}_start", **self._fields)
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self._t0 is None:
            return
        elapsed = time.perf_counter() - self._t0
        status = "error" if exc is not None else "ok"
        perf_log_kv(
            self._event,
            elapsed=elapsed,
            status=status,
            **self._fields,
        )
