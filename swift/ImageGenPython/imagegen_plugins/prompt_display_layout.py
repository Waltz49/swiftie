#!/usr/bin/env python3
"""Width-aware prompt clamping for job card display (2-line max, word-boundary elide)."""

from __future__ import annotations

from functools import lru_cache

from PySide6.QtGui import QFont, QFontMetrics, QTextLayout

from imagegen_plugins.model_task_status_info import PROMPT_DISPLAY_MAX_LINES

_ELLIPSIS = "…"
_JOB_CARD_FONT_PX = 12
_FONT_METRICS_CACHE: dict[tuple, QFontMetrics] = {}


def job_card_prompt_font(base: QFont | None = None) -> QFont:
    """Font metrics used for job-card prompt rows (12px, preserving family)."""
    font = QFont(base) if base is not None else QFont()
    font.setPixelSize(_JOB_CARD_FONT_PX)
    return font


def _font_cache_key(font: QFont) -> tuple:
    style = font.style()
    style_id = style.value if hasattr(style, "value") else int(style)
    return (
        font.family(),
        font.pixelSize(),
        font.weight(),
        style_id,
        font.italic(),
    )


def _font_from_key(key: tuple) -> QFont:
    font = QFont()
    font.setFamilies([key[0]])
    font.setPixelSize(key[1])
    font.setWeight(key[2])
    font.setStyle(QFont.Style(key[3]))
    font.setItalic(bool(key[4]))
    return font


def _font_metrics(font: QFont) -> QFontMetrics:
    key = _font_cache_key(font)
    cached = _FONT_METRICS_CACHE.get(key)
    if cached is None:
        cached = QFontMetrics(font)
        _FONT_METRICS_CACHE[key] = cached
    return cached


@lru_cache(maxsize=2048)
def _line_start_indices_cached(
    text: str, width: int, font_key: tuple
) -> tuple[int, ...]:
    if not text or width <= 0:
        return ()
    font = _font_from_key(font_key)
    layout = QTextLayout(text, font)
    layout.setCacheEnabled(True)
    starts: list[int] = []
    layout.beginLayout()
    try:
        while True:
            line = layout.createLine()
            if not line.isValid():
                break
            line.setLineWidth(float(width))
            starts.append(line.textStart())
    finally:
        layout.endLayout()
    return tuple(starts)


def _line_count(text: str, font_key: tuple, width: int) -> int:
    return len(_line_start_indices_cached(text, width, font_key))


def _snap_to_word_boundary(text: str, cut: int) -> int:
    if cut <= 0:
        return 0
    if cut >= len(text):
        return len(text)
    last_space = text.rfind(" ", 0, cut)
    return last_space if last_space > 0 else cut


def _clamp_impl(text: str, width: int, font_key: tuple, max_lines: int) -> str:
    if _line_count(text, font_key, width) <= max_lines:
        return text

    starts = _line_start_indices_cached(text, width, font_key)
    if len(starts) <= max_lines:
        return text

    cut = starts[max_lines]
    cut = _snap_to_word_boundary(text, cut)
    while cut > 0:
        candidate = text[:cut].rstrip() + _ELLIPSIS
        if _line_count(candidate, font_key, width) <= max_lines:
            return candidate
        prev_space = text.rfind(" ", 0, cut - 1)
        cut = prev_space if prev_space > 0 else cut - 1

    return _ELLIPSIS


@lru_cache(maxsize=512)
def _clamp_cached(text: str, width: int, font_key: tuple, max_lines: int) -> str:
    return _clamp_impl(text, width, font_key, max_lines)


def clamp_prompt_for_display(
    text: str,
    font: QFont,
    width: int,
    *,
    max_lines: int = PROMPT_DISPLAY_MAX_LINES,
) -> str:
    """Show as much prompt as fits in ``max_lines``; elide on a word boundary."""
    text = (text or "").rstrip()
    if not text or width <= 0:
        return text
    display_font = job_card_prompt_font(font)
    _ = _font_metrics(display_font)  # warm font-metrics cache
    font_key = _font_cache_key(display_font)
    return _clamp_cached(text, int(width), font_key, int(max_lines))
