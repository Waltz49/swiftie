#!/usr/bin/env python3
"""Debug logging for CNN similarity (⌘K) and CLIP text search (⌘F). Gated on debug_mode."""

from __future__ import annotations

import os
import sys
from typing import Iterable, Optional, Sequence, Tuple

from debug_log import debug_timestamp

ScorePath = Tuple[float, str]


def debug_enabled(main_window=None) -> bool:
    if main_window is not None and getattr(main_window, "debug_mode", False):
        return True
    try:
        from config import get_config

        return bool(get_config().load_settings().get("debug_mode", False))
    except Exception:
        return False


def log_similarity_search(message: str, *, main_window=None) -> None:
    if not debug_enabled(main_window):
        return
    line = f"[{debug_timestamp()}] similarity_search: {message}"
    print(line, flush=True)
    # When stdout is redirected (e.g. `> /tmp/pylog.txt`), still show lines on the terminal.
    if not sys.stdout.isatty():
        print(line, file=sys.stderr, flush=True)


def log_similarity_top_scores(
    label: str,
    scored: Sequence[ScorePath],
    *,
    main_window=None,
    limit: int = 15,
) -> None:
    if not debug_enabled(main_window):
        return
    log_similarity_search(f"{label} top {min(limit, len(scored))} scores:", main_window=main_window)
    for idx, (score, path) in enumerate(scored[:limit]):
        log_similarity_search(
            f"  {idx:2d}  {score:.4f}  {os.path.basename(path)}  {path}",
            main_window=main_window,
        )


def log_similarity_scope(
    *,
    kind: str,
    main_window=None,
    candidate_count: int,
    recursive: bool = False,
    search_directory: Optional[str] = None,
    filter_pattern: Optional[str] = None,
    search_depth: Optional[int] = None,
    reference_paths: Optional[Iterable[str]] = None,
    extra: str = "",
) -> None:
    if not debug_enabled(main_window):
        return
    refs = list(reference_paths or [])
    ref_line = os.path.basename(refs[0]) if len(refs) == 1 else f"{len(refs)} refs"
    if len(refs) == 1 and refs[0]:
        ref_line = f"{ref_line} ({refs[0]})"
    parts = [
        f"{kind} scope candidates={candidate_count}",
        f"recursive={recursive}",
        f"search_dir={search_directory or '(current)'}",
        f"filter={filter_pattern or '*'}",
    ]
    if search_depth is not None:
        parts.append(f"search_depth={search_depth}")
    parts.append(f"reference={ref_line}")
    if extra:
        parts.append(extra)
    log_similarity_search(" ".join(parts), main_window=main_window)
