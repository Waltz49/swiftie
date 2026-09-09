#!/usr/bin/env python3
"""Structured status views for job cards and the active-job progress strip."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Union

from imagegen_plugins.model_task_status_info import (
    _format_steps_progress_display,
    _steps_row_inline_parts,
)

QueueStatusRow = Union[
    "QueueTitleRow",
    "QueueLabelValueRow",
    "QueuePromptRow",
    "QueueInlineRow",
    "QueueUnavailableRow",
    "QueueBannerRow",
]


@dataclass(frozen=True)
class QueueTitleRow:
    title: str
    running: bool = False


@dataclass(frozen=True)
class QueueLabelValueRow:
    label: str
    value: str


@dataclass(frozen=True)
class QueuePromptRow:
    label: str
    value: str


@dataclass(frozen=True)
class QueueInlineRow:
    label: str
    primary_value: str
    inline_parts: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class QueueUnavailableRow:
    heading: str
    copies_line: str
    prompt_line: str


@dataclass(frozen=True)
class QueueBannerRow:
    text: str


def _static_inline_primary(row: QueueInlineRow) -> str:
    primary = row.primary_value.split("   (Cooldown)")[0].rstrip()
    if primary.strip().startswith("(Cooldown)"):
        return "(Cooldown)"
    if row.label == "Steps:":
        # Progress fraction changes during generation; live updates handle display.
        if "/" in primary or " of " in primary or "(total)" in primary:
            return "Steps:"
    return primary


@dataclass(frozen=True)
class QueueJobStatusView:
    rows: tuple[QueueStatusRow, ...]
    cooldown_remaining: int | None = None
    show_skip_cooldown: bool = False
    running: bool = False

    def is_empty(self) -> bool:
        return not self.rows

    def fingerprint(self) -> tuple:
        row_fps: list[tuple] = []
        for row in self.rows:
            if isinstance(row, QueueTitleRow):
                row_fps.append(("title", row.title, row.running))
            elif isinstance(row, QueueLabelValueRow):
                row_fps.append(("lv", row.label, row.value))
            elif isinstance(row, QueuePromptRow):
                row_fps.append(("prompt", row.label, row.value))
            elif isinstance(row, QueueInlineRow):
                row_fps.append(
                    (
                        "inline",
                        row.label,
                        _static_inline_primary(row),
                        row.inline_parts,
                    )
                )
            elif isinstance(row, QueueUnavailableRow):
                row_fps.append(
                    ("unavail", row.heading, row.copies_line, row.prompt_line)
                )
            elif isinstance(row, QueueBannerRow):
                row_fps.append(("banner", row.text))
        return (tuple(row_fps), self.running, self.show_skip_cooldown)


EMPTY_QUEUE_STATUS_VIEW = QueueJobStatusView(rows=())


StripRow = Union["StripBarRow", "StripCountRow"]


@dataclass(frozen=True)
class StripBarRow:
    label: str
    prefix: str
    postfix: str
    fill_percent: int
    slot_text: str = ""
    show_pending_start: bool = False


@dataclass(frozen=True)
class StripCountRow:
    label: str
    count: str


@dataclass(frozen=True)
class ActiveJobStripView:
    rows: tuple[StripRow, ...] = ()
    mode: str = ""
    cooldown_text: str = ""
    cooldown_count_text: str = ""
    show_skip_icon: bool = False
    show_cancel_icon: bool = False
    skip_hovered: bool = False
    cancel_hovered: bool = False

    def is_empty(self) -> bool:
        return not self.rows and not self.cooldown_text

    def fingerprint(self) -> tuple:
        row_fps: list[tuple] = []
        for row in self.rows:
            if isinstance(row, StripBarRow):
                row_fps.append(("bar", row.label, row.slot_text))
            elif isinstance(row, StripCountRow):
                row_fps.append(("count", row.label))
        return (
            tuple(row_fps),
            self.mode,
            self.show_skip_icon,
            self.show_cancel_icon,
        )


EMPTY_ACTIVE_JOB_STRIP_VIEW = ActiveJobStripView()


_COOLDOWN_INLINE_LABELS = ("Steps:", "AI:")


def _find_steps_inline_row(
    view: QueueJobStatusView,
) -> tuple[int, QueueInlineRow] | None:
    for idx, row in enumerate(view.rows):
        if isinstance(row, QueueInlineRow) and row.label == "Steps:":
            return idx, row
    return None


def _find_cooldown_inline_row(
    view: QueueJobStatusView,
) -> tuple[int, QueueInlineRow] | None:
    for label in _COOLDOWN_INLINE_LABELS:
        for idx, row in enumerate(view.rows):
            if isinstance(row, QueueInlineRow) and row.label == label:
                return idx, row
    for idx, row in enumerate(view.rows):
        if not isinstance(row, QueueInlineRow):
            continue
        for part_label, _ in row.inline_parts:
            if part_label == "Elapsed:":
                return idx, row
    return None


def _cooldown_suffix(remaining_seconds: int) -> str:
    remaining = max(0, int(remaining_seconds))
    return f"   (Cooldown) {remaining}"


def _cooldown_only_primary(remaining_seconds: int) -> str:
    remaining = max(0, int(remaining_seconds))
    return f"(Cooldown) {remaining}"


def _strip_cooldown_from_primary(primary: str) -> str:
    stripped = (primary or "").strip()
    if stripped.startswith("(Cooldown)"):
        return ""
    return primary.split("   (Cooldown)")[0].rstrip()


def _cooldown_primary_value(base: str, remaining_seconds: int) -> str:
    base = _strip_cooldown_from_primary(base)
    if base:
        return base + _cooldown_suffix(remaining_seconds)
    return _cooldown_only_primary(remaining_seconds)


def _insert_cooldown_inline_row(
    view: QueueJobStatusView, remaining_seconds: int
) -> tuple[QueueStatusRow, ...]:
    rows = list(view.rows)
    insert_at = 1 if rows and isinstance(rows[0], QueueTitleRow) else 0
    rows.insert(
        insert_at,
        QueueInlineRow("Steps:", _cooldown_only_primary(remaining_seconds)),
    )
    return tuple(rows)


def apply_cooldown_to_queue_status(
    view: QueueJobStatusView,
    remaining_seconds: int,
    *,
    show_skip: bool = False,
) -> QueueJobStatusView:
    remaining = max(0, int(remaining_seconds))
    found = _find_cooldown_inline_row(view)
    if found is not None:
        idx, row = found
        new_row = replace(
            row,
            primary_value=_cooldown_primary_value(row.primary_value, remaining),
        )
        rows = list(view.rows)
        rows[idx] = new_row
        return replace(
            view,
            rows=tuple(rows),
            cooldown_remaining=remaining,
            show_skip_cooldown=show_skip,
        )
    return replace(
        view,
        rows=_insert_cooldown_inline_row(view, remaining),
        cooldown_remaining=remaining,
        show_skip_cooldown=show_skip,
    )


def strip_cooldown_from_queue_status(view: QueueJobStatusView) -> QueueJobStatusView:
    found = _find_cooldown_inline_row(view)
    if found is not None:
        idx, row = found
        base = _strip_cooldown_from_primary(row.primary_value)
        rows = list(view.rows)
        if not base:
            rows.pop(idx)
        else:
            rows[idx] = replace(row, primary_value=base)
        return replace(
            view,
            rows=tuple(rows),
            cooldown_remaining=None,
            show_skip_cooldown=False,
        )
    return replace(
        view,
        cooldown_remaining=None,
        show_skip_cooldown=False,
    )


def update_queue_status_steps(
    view: QueueJobStatusView,
    step: int,
    total: int,
    *,
    elapsed_seconds: float | None = None,
    estimate_seconds: float | None = None,
) -> QueueJobStatusView:
    if total <= 0:
        return view
    found = _find_steps_inline_row(view)
    if found is None:
        return view
    idx, row = found
    step_value = _format_steps_progress_display(step, total)
    cooldown_idx = row.primary_value.find("   (Cooldown)")
    if cooldown_idx >= 0:
        step_value += row.primary_value[cooldown_idx:]
    inline_parts = tuple(
        _steps_row_inline_parts(
            {},
            elapsed_seconds=elapsed_seconds,
            estimate_seconds=estimate_seconds,
        )
    )
    new_row = replace(
        row,
        primary_value=step_value,
        inline_parts=inline_parts,
    )
    rows = list(view.rows)
    rows[idx] = new_row
    return replace(view, rows=tuple(rows))


def freeze_queue_status_elapsed(
    view: QueueJobStatusView,
    elapsed_seconds: float,
    *,
    step: int | None = None,
    step_total: int | None = None,
) -> QueueJobStatusView:
    if step is not None and step_total is not None and step_total > 0:
        return update_queue_status_steps(
            view,
            step,
            step_total,
            elapsed_seconds=elapsed_seconds,
        )
    found = _find_steps_inline_row(view)
    if found is None:
        return view
    idx, row = found
    inline_parts = tuple(
        _steps_row_inline_parts({}, elapsed_seconds=elapsed_seconds)
    )
    new_row = replace(row, inline_parts=inline_parts)
    rows = list(view.rows)
    rows[idx] = new_row
    return replace(view, rows=tuple(rows))


def set_queue_status_steps_timing(
    view: QueueJobStatusView,
    elapsed_seconds: float,
    *,
    estimate_seconds: float | None = None,
) -> QueueJobStatusView:
    found = _find_steps_inline_row(view)
    if found is None:
        return view
    idx, row = found
    inline_parts = tuple(
        _steps_row_inline_parts(
            {},
            elapsed_seconds=elapsed_seconds,
            estimate_seconds=estimate_seconds,
        )
    )
    new_row = replace(row, inline_parts=inline_parts)
    rows = list(view.rows)
    rows[idx] = new_row
    return replace(view, rows=tuple(rows))


def queue_status_steps_row_index(view: QueueJobStatusView) -> int | None:
    found = _find_steps_inline_row(view)
    return found[0] if found is not None else None
