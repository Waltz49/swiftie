#!/usr/bin/env python3
"""Live-updating active job progress strip (shared by jobs pane, panel, and quit prompts)."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QEvent, Qt, QTimer
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from imagegen_plugins.active_job_strip_content import ActiveJobStripContentWidget
from imagegen_plugins.image_gen_controller import get_imagegen_controller
from imagegen_plugins.model_task_status_info import (
    _ACTIVE_JOB_STRIP_FRAME_CHROME_V,
    active_job_strip_layout_widths,
    active_job_timing_progress_row_count,
    build_active_job_strip_view,
)
from theme.theme_service import get_active_theme

_ACTIVE_JOB_STRIP_MARGIN = 8  # left + right QLayout margins on the strip (4+4)


def _active_job_strip_frame_stylesheet() -> str:
    t = get_active_theme()
    bdr = t.default_border_color_hex
    return f"""
        QFrame#activeJobStripFrame {{
            border: 1px solid {bdr};
            padding: 4px;
            background: transparent;
        }}
    """


def _disable_tab_focus(root: QWidget) -> None:
    root.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    for child in root.findChildren(QWidget):
        child.setFocusPolicy(Qt.FocusPolicy.NoFocus)


class ActiveJobStripWidget(QWidget):
    """Bordered progress strip for the active generation/caption job."""

    def __init__(
        self,
        main_window,
        parent=None,
        *,
        pause_when_imagegen_dialog_building: bool = True,
        layout_width_px: int | None = None,
    ):
        super().__init__(parent)
        self.main_window = main_window
        self._controller = get_imagegen_controller(main_window)
        self._pause_when_imagegen_dialog_building = bool(
            pause_when_imagegen_dialog_building
        )
        self._layout_width_px = layout_width_px
        self._cancel_hovered = False
        self._skip_hovered = False
        self._last_strip_fingerprint: tuple | None = None
        self._cached_content_height = 0
        self._progress_row_count = 0
        self._deferred_remeasure_pending = False
        self._deferred_remeasure_baseline_h = 0
        self._on_content_height_changed: Callable[[], None] | None = None
        self._resize_refresh_timer = QTimer(self)
        self._resize_refresh_timer.setSingleShot(True)
        self._resize_refresh_timer.setInterval(50)
        self._resize_refresh_timer.timeout.connect(lambda: self.refresh(force=True))
        self._setup_ui()
        self._connect_controller()

    def set_on_content_height_changed(
        self, callback: Callable[[], None] | None
    ) -> None:
        self._on_content_height_changed = callback

    def _include_queue_jobs_row(self) -> bool:
        parent = self.parent()
        if parent is not None and hasattr(parent, "is_queue_compact"):
            return bool(parent.is_queue_compact())
        return False

    def _emit_content_height_changed(self) -> None:
        cb = self._on_content_height_changed
        if cb is not None:
            cb()

    def _schedule_deferred_remeasure(self, *, before_height: int) -> None:
        if self._deferred_remeasure_pending:
            if before_height > 0:
                self._deferred_remeasure_baseline_h = min(
                    self._deferred_remeasure_baseline_h or before_height,
                    before_height,
                )
            return
        self._deferred_remeasure_baseline_h = before_height
        self._deferred_remeasure_pending = True
        QTimer.singleShot(0, self._deferred_remeasure)

    def _strip_should_show(self) -> bool:
        return self._controller.pane_shows_generation_progress()

    def _deferred_remeasure(self) -> None:
        self._deferred_remeasure_pending = False
        if not self.isVisible() or not self._strip_should_show():
            self._deferred_remeasure_baseline_h = 0
            return
        baseline_h = self._deferred_remeasure_baseline_h
        self._deferred_remeasure_baseline_h = 0
        self.refresh(force=True)
        if self.content_height() != baseline_h:
            self._emit_content_height_changed()

    def _setup_ui(self) -> None:
        h_policy = (
            QSizePolicy.Policy.Preferred
            if self._layout_width_px is not None
            else QSizePolicy.Policy.Expanding
        )
        self.setSizePolicy(h_policy, QSizePolicy.Policy.Fixed)
        if self._layout_width_px is not None:
            self.setMaximumWidth(self._layout_width_px)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 0)
        layout.setSpacing(0)
        self._frame = QFrame()
        self._frame.setObjectName("activeJobStripFrame")
        self._frame.setStyleSheet(_active_job_strip_frame_stylesheet())
        frame_layout = QVBoxLayout(self._frame)
        frame_layout.setContentsMargins(0, 0, 0, 0)
        frame_layout.setSpacing(0)
        self._content = ActiveJobStripContentWidget(
            self.main_window, on_icon_hover=self._on_strip_icon_hover
        )
        self._content.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )
        self._content.installEventFilter(self)
        frame_layout.addWidget(self._content, 1)
        layout.addWidget(
            self._frame,
            0,
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop,
        )
        self.hide()

    def _connect_controller(self) -> None:
        self._controller.generation_started.connect(lambda: self.refresh(force=True))
        self._controller.job_processing_started.connect(
            lambda _kind: self.refresh(force=True)
        )
        self._controller.generation_finished.connect(self.refresh)
        self._controller.task_status_info_changed.connect(
            lambda: self.refresh(force=True)
        )
        self._controller.live_status_tick.connect(self._on_live_refresh_timer)

    def _imagegen_dialog_building_active(self) -> bool:
        if not self._pause_when_imagegen_dialog_building:
            return False
        main_window = self.main_window
        return bool(getattr(main_window, "_imagegen_dialog_building", False))

    def set_layout_width_px(self, width_px: int) -> None:
        width_px = max(80, int(width_px))
        if width_px == self._layout_width_px:
            return
        self._layout_width_px = width_px
        self.setMaximumWidth(width_px)
        self.refresh(force=True)

    def _strip_min_frame_width(self) -> int:
        return 80

    def _layout_content_width(self) -> int:
        if self._layout_width_px is not None:
            return max(0, self._layout_width_px - _ACTIVE_JOB_STRIP_MARGIN)
        w = self.width()
        if w <= 0:
            parent = self.parentWidget()
            if parent is not None:
                w = parent.width()
        return max(0, w - _ACTIVE_JOB_STRIP_MARGIN)

    def _layout_widths(self) -> tuple[int, int]:
        return active_job_strip_layout_widths(
            self._layout_content_width(),
            min_frame_width_px=self._strip_min_frame_width(),
        )

    def _on_live_refresh_timer(self) -> None:
        if self._imagegen_dialog_building_active():
            return
        if not self.isVisible():
            return
        if not self._controller.task_status_display_needs_refresh():
            return
        self.refresh(force=True)
        self._controller.mark_task_status_display_refreshed()

    def _on_strip_icon_hover(self, kind: str, hovered: bool) -> None:
        if kind == "skip":
            if self._skip_hovered == hovered:
                return
            self._skip_hovered = hovered
        elif kind == "cancel":
            if self._cancel_hovered == hovered:
                return
            self._cancel_hovered = hovered
        else:
            return
        self._content.update_icon_hover(
            skip_hovered=self._skip_hovered,
            cancel_hovered=self._cancel_hovered,
        )

    def _build_strip_view(self):
        include_queue_jobs_row = self._include_queue_jobs_row()
        return build_active_job_strip_view(
            self._controller,
            cancel_hovered=self._cancel_hovered,
            skip_hovered=self._skip_hovered,
            include_queue_jobs_row=include_queue_jobs_row,
        )

    def refresh(self, *, force: bool = False, notify_geometry: bool = True) -> None:
        if not force and self._imagegen_dialog_building_active():
            return
        if not self._strip_should_show():
            self._cached_content_height = 0
            self._progress_row_count = 0
            self.hide()
            return
        if not force and not self._controller.task_status_display_needs_refresh():
            return
        prev_h = (
            self._cached_content_height
            if self._cached_content_height > 0
            else self.height()
        )
        include_queue_jobs_row = self._include_queue_jobs_row()
        row_count = active_job_timing_progress_row_count(
            self._controller, include_queue_jobs_row=include_queue_jobs_row
        )
        rows_changed = row_count != self._progress_row_count
        if rows_changed:
            self._cached_content_height = 0
        self._progress_row_count = row_count
        frame_w, content_w = self._layout_widths()
        view = self._build_strip_view()
        if view.is_empty():
            self._cached_content_height = 0
            self.hide()
            return
        fp = view.fingerprint()
        if fp == self._last_strip_fingerprint and self._content.has_rows():
            self._content.set_content_width(content_w)
            self._content.update_live_fields(view)
        else:
            self._content.set_strip_view(view, content_w)
            self._last_strip_fingerprint = fp
        content_h = self._content.sizeHint().height()
        frame_h = content_h + _ACTIVE_JOB_STRIP_FRAME_CHROME_V
        self._frame.setFixedWidth(frame_w)
        self._frame.setMinimumHeight(0)
        self._frame.setFixedHeight(frame_h)
        layout = self.layout()
        margin_h = 0
        if layout is not None:
            margins = layout.contentsMargins()
            margin_h = margins.top() + margins.bottom()
        target_h = frame_h + margin_h
        self.setMinimumHeight(0)
        self.setFixedHeight(target_h)
        self._cached_content_height = target_h
        self.show()
        _disable_tab_focus(self)
        if rows_changed:
            if notify_geometry:
                self._schedule_deferred_remeasure(before_height=prev_h)
                self._emit_content_height_changed()
        elif target_h != prev_h and notify_geometry:
            self._emit_content_height_changed()

    def content_height(self) -> int:
        """Last computed target height (live height() may lag pending relayout)."""
        if not self._strip_should_show():
            return 0
        if self._cached_content_height > 0:
            return self._cached_content_height
        if self.isVisible() and self.height() > 0:
            self._cached_content_height = self.height()
            return self._cached_content_height
        layout = self.layout()
        margin_h = 0
        if layout is not None:
            margins = layout.contentsMargins()
            margin_h = margins.top() + margins.bottom()
        return 28 + _ACTIVE_JOB_STRIP_FRAME_CHROME_V + margin_h

    def refresh_theme_styles(self) -> None:
        self._frame.setStyleSheet(_active_job_strip_frame_stylesheet())
        self._content.refresh_theme_styles()
        self.refresh(force=True, notify_geometry=False)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if self._layout_width_px is None:
            old = event.oldSize()
            new = event.size()
            if old.width() != new.width():
                self.refresh(force=True, notify_geometry=False)
            else:
                self._resize_refresh_timer.start()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self.refresh(force=True)

    def hideEvent(self, event) -> None:
        super().hideEvent(event)

    def eventFilter(self, obj, event) -> bool:
        if obj is self._content:
            if event.type() == QEvent.Type.Leave:
                changed = self._cancel_hovered or self._skip_hovered
                self._cancel_hovered = False
                self._skip_hovered = False
                if changed:
                    self._content.update_icon_hover(
                        skip_hovered=False,
                        cancel_hovered=False,
                    )
        return super().eventFilter(obj, event)
