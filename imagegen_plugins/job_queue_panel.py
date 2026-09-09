#!/usr/bin/env python3
"""Shared job queue list UI (job cards, progress strip) for pane and dialog."""

from __future__ import annotations

import os
from typing import Callable

from PySide6.QtCore import QEvent, QEventLoop, Qt, QTimer, QSize, QPoint, QObject, QMimeData
from PySide6.QtGui import QColor, QDrag, QIcon, QMouseEvent, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QAbstractButton,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from imagegen_plugins.active_job_strip_widget import ActiveJobStripWidget
from imagegen_plugins.image_gen_controller import get_imagegen_controller
from imagegen_plugins.job_card_status_widget import JobCardStatusWidget
from imagegen_plugins.job_queue_common import (
    _ACTION_BAR_HEIGHT,
    _apply_job_queue_cell_background,
    _valid_preview_paths,
    JobQueueActionBar,
    create_invalid_job_preview_label,
    job_queue_edit_row,
    open_reference_thumbnail_paths,
    schedule_restore_main_canvas_focus,
    status_view_for_queue_row,
)
from config import job_queue_cell_background_hex, job_queue_running_cell_background_hex
from imagegen_plugins.job_prompt_tooltip import (
    install_delayed_prompt_tooltip,
    update_delayed_prompt_tooltip,
)
from theme.theme_service import get_active_theme
from theme.titlebar_icons import titlebar_chip_colors
from browser_window.sidebar.sidebar_pane_chrome import apply_scroll_area_viewport_background
from thumbnails.sidebar_pane_layout import MIN_JOBS_QUEUE_CONTENT_HEIGHT, pane_fit_height_tolerance
from thumbnails import thumbnail_constants as tc
from utils import create_job_status_thumbnail_label

_JOB_QUEUE_DRAG_MIME = "application/x-prowser-job-queue-id"
_CARD_CONTENT_MARGIN = 12
_DROP_LINE_HEIGHT = 6
_DROP_LINE_COLOR = tc.CURRENT_IMAGE_BORDER_COLOR
_DROP_LINE_PEN_WIDTH = 1

_THUMB_SIZE = 55
_THUMB_GAP = 14

# Sidebar Job Control pane minimum content width (px).
MIN_JOBS_PANE_WIDTH = 250

# Floating Job Control dialog minimum content width (px). Outer min = + 2× margin.
MIN_JOB_WIN_WIDTH = 210 # DGN hardcoded to current font sizes

QUEUE_SIZE_ALL = "all"
QUEUE_SIZE_ONE = "one"
QUEUE_SIZE_STRIP = "strip"
_QUEUE_SIZE_MODES = (QUEUE_SIZE_ALL, QUEUE_SIZE_ONE, QUEUE_SIZE_STRIP)

# Extra client height when pin-sizing pane/dialog to job rows (avoids inner scrollbars).
JOBS_PANE_FIT_BOTTOM_SLACK_PX = 5


def next_queue_size_mode(mode: str) -> str:
    idx = _QUEUE_SIZE_MODES.index(mode) if mode in _QUEUE_SIZE_MODES else 0
    return _QUEUE_SIZE_MODES[(idx + 1) % len(_QUEUE_SIZE_MODES)]

_EMPTY_LABEL_FONT_PX = 12
_EMPTY_LABEL_HEIGHT_LINES = 1.5
_EMPTY_QUEUE_LABEL_TEXT = "No jobs in the queue."


def _empty_queue_label_stylesheet(text_hex: str) -> str:
    return (
        f"color: {text_hex}; font-size: {_EMPTY_LABEL_FONT_PX}px; "
        "padding: 0px 8px; margin: 0px;"
    )


def empty_queue_label_height_px(label: QLabel) -> int:
    """~1.5 line heights for the empty-queue message."""
    fm = label.fontMetrics()
    return int(fm.height() * _EMPTY_LABEL_HEIGHT_LINES)


def _apply_empty_queue_label_style(label: QLabel, text_hex: str) -> None:
    label.setStyleSheet(_empty_queue_label_stylesheet(text_hex))
    h = empty_queue_label_height_px(label)
    label.setFixedHeight(h)


def job_control_dialog_outer_minimum_width(*, margin_px: int = 0) -> int:
    """Minimum outer width for the floating job control dialog."""
    return MIN_JOB_WIN_WIDTH + 2 * margin_px

# When scroll viewport width exceeds this and a row has 1–2 reference images, show
# them in a vertical column beside the text instead of below it.
JOB_CELL_INLINE_REFS_MIN_SCROLL_WIDTH = 350
JOB_CELL_INLINE_REFS_RIGHT_PADDING_PX = 2
_JOB_CELL_INLINE_TEXT_REFS_SPACING = 4


def jobs_header_status_text(controller) -> str:
    """Title-bar queue summary: waiting jobs, or all queued jobs when held."""
    rows = controller.queue_snapshot()
    if controller.hold_job_queue():
        held = len(rows)
        if held > 0:
            return f"={held} "
        return ""
    waiting = sum(1 for row in rows if not row.is_active)
    if waiting > 0:
        return f"+{waiting} "
    return ""


def _disable_tab_focus(root: QWidget) -> None:
    """Keep job pane controls out of the keyboard tab order."""
    root.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    for child in root.findChildren(QWidget):
        child.setFocusPolicy(Qt.FocusPolicy.NoFocus)


def _job_selection_border_hex() -> str:
    """Titlebar chip button background (hide/tools/flyout)."""
    return titlebar_chip_colors()[0]


def _job_selection_border_width_px() -> int:
    w = int(tc.CURRENT_IMAGE_BORDER_WIDTH_PX or 0)
    if w > 0:
        return w
    t = get_active_theme()
    idx = int(getattr(t, "current_image_border_width_index", 2))
    return max(1, min(10, idx))


def _job_card_stylesheet(*, selected: bool = False, running: bool = False) -> str:
    t = get_active_theme()
    bg = (
        job_queue_running_cell_background_hex()
        if running
        else job_queue_cell_background_hex()
    )
    if selected:
        border = _job_selection_border_hex()
        width = _job_selection_border_width_px()
    else:
        border = t.border_default_hex
        width = 1
    return f"""
        QFrame#sidebarJobCard {{
            background-color: {bg};
            color: {t.sidebar_text_color_hex};
            border: {width}px solid {border};
            border-radius: 4px;
            padding: 0px;
            margin: 0px;
        }}
    """


def refresh_jobs_flyout_buttons(main_window) -> None:
    from imagegen_plugins.jobs_display_mode import (
        JOBS_DISPLAY_PANE,
        get_jobs_display_mode,
    )

    from theme.titlebar_icons import (
        apply_titlebar_button_icons,
        titlebar_flyout_icon_pair,
    )

    pane_mode = get_jobs_display_mode(main_window) == JOBS_DISPLAY_PANE
    tooltip = (
        "Open job queue in floating panel"
        if pane_mode
        else "Dock job queue in sidebar pane"
    )
    panels = []
    rs = getattr(main_window, "right_sidebar", None)
    if rs is not None:
        w = getattr(rs, "jobs_widget", None)
        if w is not None:
            panels.append(w)
    dlg = getattr(main_window, "_imagegen_job_queue_dialog", None)
    if dlg is not None and getattr(dlg, "_panel", None) is not None:
        panels.append(dlg._panel)
    for panel in panels:
        btn = getattr(panel, "_flyout_button", None)
        if btn is None:
            continue
        btn.setProperty("_titlebar_flyout_pane_mode", pane_mode)
        btn.setToolTip(tooltip)
        apply_titlebar_button_icons(btn, *titlebar_flyout_icon_pair(pane_mode))


class _JobQueueDropLine(QWidget):
    """Horizontal insertion marker (matches thumbnail canvas drop indicator style)."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAutoFillBackground(False)
        self.hide()

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setPen(QPen(_DROP_LINE_COLOR, _DROP_LINE_PEN_WIDTH))
        mid_y = self.height() // 2
        painter.drawLine(0, mid_y, self.width(), mid_y)


class _FlowReferenceThumbs(QWidget):
    """Reference thumbnails in right-aligned rows; wrap on resize."""

    def __init__(
        self,
        main_window,
        paths: list[str],
        *,
        references_invalid: bool = False,
        parent=None,
    ):
        super().__init__(parent)
        self._main_window = main_window
        self._references_invalid = bool(references_invalid)
        self._paths = [] if self._references_invalid else _valid_preview_paths(paths)
        self._cells: list[QLabel] = []
        self._last_cols: int | None = None
        self._last_reflow_width = 0
        self._reflow_guard = False
        if self._references_invalid:
            self.setCursor(Qt.CursorShape.ArrowCursor)
        else:
            self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setAttribute(Qt.WidgetAttribute.WA_DontCreateNativeAncestors, True)
        self.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, False)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._outer = QVBoxLayout(self)
        self._outer.setContentsMargins(0, 2, 0, 0)
        self._outer.setSpacing(_THUMB_GAP)
        if self._references_invalid:
            thumb = create_invalid_job_preview_label(_THUMB_SIZE)
            thumb.setToolTip("Reference files for this job are missing")
            self._cells.append(thumb)
            self.reflow_to_width(_THUMB_SIZE)
            return
        for path in self._paths:
            thumb = create_job_status_thumbnail_label(path, _THUMB_SIZE)
            thumb.setCursor(Qt.CursorShape.PointingHandCursor)
            thumb.setAttribute(Qt.WidgetAttribute.WA_DontCreateNativeAncestors, True)
            thumb.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, False)
            thumb.setToolTip(os.path.basename(path))
            self._cells.append(thumb)
        if self._paths:
            self.reflow_to_width(max(_THUMB_SIZE * 2, 120))
        else:
            self.hide()
            self.setFixedHeight(0)
            self.setMaximumHeight(0)
            self.setMinimumHeight(0)
            self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)

    def _effective_reflow_width(self, width: int) -> int:
        if width > 0:
            return width
        parent = self.parentWidget()
        if parent is not None and parent.width() > 0:
            return parent.width()
        return max(_THUMB_SIZE * 2, 120)

    def _cols_for_width(self, width: int) -> int:
        w = max(width, _THUMB_SIZE)
        stride = _THUMB_SIZE + _THUMB_GAP
        return max(1, (w + _THUMB_GAP) // stride)

    def _content_height(self, cols: int) -> int:
        n = len(self._cells)
        if not n:
            return 0
        rows = (n + cols - 1) // cols
        return rows * (_THUMB_SIZE + _THUMB_GAP) - _THUMB_GAP + 4

    def _row_width(self, count: int) -> int:
        if count <= 0:
            return 0
        return count * _THUMB_SIZE + (count - 1) * _THUMB_GAP

    def _content_width(self, cols: int) -> int:
        n = len(self._cells)
        if not n:
            return 0
        first_row = min(cols, n)
        return self._row_width(first_row)

    def _clear_rows(self) -> None:
        while self._outer.count():
            item = self._outer.takeAt(0)
            row_layout = item.layout()
            if row_layout is not None:
                while row_layout.count():
                    row_layout.takeAt(0)
                row_layout.deleteLater()

    def reflow_to_width(self, width: int, *, force_cols: int | None = None) -> None:
        width = self._effective_reflow_width(width)
        self._last_reflow_width = width
        if self._reflow_guard or not self._cells:
            return
        cols = force_cols if force_cols is not None else self._cols_for_width(width)
        if cols == self._last_cols and self._outer.count() > 0:
            self._apply_thumb_height(cols, width)
            return
        self._reflow_guard = True
        try:
            self._clear_rows()
            self._last_cols = cols
            for row_start in range(0, len(self._cells), cols):
                row_layout = QHBoxLayout()
                row_layout.setContentsMargins(0, 0, 0, 0)
                row_layout.setSpacing(_THUMB_GAP)
                row_layout.addStretch(1)
                for cell in self._cells[row_start : row_start + cols]:
                    row_layout.addWidget(
                        cell,
                        0,
                        Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignTop,
                    )
                self._outer.addLayout(row_layout)
        finally:
            self._reflow_guard = False
        self._apply_thumb_height(cols, width)
        self.updateGeometry()

    def _apply_thumb_height(self, cols: int, width: int | None = None) -> None:
        h = self._content_height(cols)
        self.setMinimumWidth(0)
        self.setMaximumWidth(16777215)
        self.setFixedHeight(h)
        self.setMinimumHeight(h)
        self.setMaximumHeight(h)

    def sizeHint(self) -> QSize:
        if not self._cells:
            return QSize(0, 0)
        cols = self._last_cols or self._cols_for_width(max(self.width(), _THUMB_SIZE))
        return QSize(self._content_width(cols), self._content_height(cols))

    def minimumSizeHint(self) -> QSize:
        if not self._cells:
            return QSize(0, 0)
        cols = self._last_cols or self._cols_for_width(max(self.width(), _THUMB_SIZE))
        return QSize(0, self._content_height(cols))

    def mousePressEvent(self, event) -> None:
        if (
            event.button() == Qt.MouseButton.LeftButton
            and self._paths
            and not self._references_invalid
        ):
            open_reference_thumbnail_paths(self._main_window, self._paths)
            event.accept()
            return
        super().mousePressEvent(event)


class _JobCardDblClickFilter(QObject):
    """Open the job editor on double-click (viewport + browser)."""

    def __init__(
        self,
        opener: Callable[[], None],
        on_force_select: Callable[[], None] | None = None,
        parent: QObject | None = None,
    ):
        super().__init__(parent)
        self._opener = opener
        self._on_force_select = on_force_select

    def eventFilter(self, obj: QObject, event: QEvent) -> bool:
        if event.type() == QEvent.Type.MouseButtonDblClick:
            mouse_event = event  # type: ignore[assignment]
            if mouse_event.button() == Qt.MouseButton.LeftButton:
                if self._on_force_select is not None:
                    self._on_force_select()
                self._opener()
                return True
        return False


class JobCard(QFrame):
    """One queue row: status widgets + thumbnails; action bar embeds when selected."""

    def __init__(
        self,
        main_window,
        controller,
        row_idx: int,
        *,
        job_id: str,
        is_active: bool,
        on_select: Callable[[str], None] | None = None,
        on_select_force: Callable[[str], None] | None = None,
        on_reorder_drop: Callable[[str, str | None], None] | None = None,
        on_drop_hover: Callable[[int], None] | None = None,
        on_drop_hover_clear: Callable[[], None] | None = None,
        on_drag_auto_scroll: Callable[[QPoint], None] | None = None,
        parent=None,
    ):
        super().__init__(parent)
        self.setObjectName("sidebarJobCard")
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        self.setAcceptDrops(True)
        self._main_window = main_window
        self._controller = controller
        self._row_idx = row_idx
        self._job_id = job_id
        self._is_active = bool(is_active)
        self._on_select = on_select
        self._on_select_force = on_select_force
        self._on_reorder_drop = on_reorder_drop
        self._on_drop_hover = on_drop_hover
        self._on_drop_hover_clear = on_drop_hover_clear
        self._on_drag_auto_scroll = on_drag_auto_scroll
        self._selected = False
        self._full_prompt = ""
        self._last_status_view = None
        self._last_view_fingerprint: tuple | None = None
        self._scroll_width = 0
        self._content_inline = False
        self._last_content_width = 0
        self._drag_start_pos: QPoint | None = None
        self._drag_started = False
        self._action_bar: QWidget | None = None
        self._content_deferred = False
        self._deferred_thumbnail_paths: list[str] | None = None
        self._deferred_references_invalid = False
        self._pending_select_timer = QTimer(self)
        self._pending_select_timer.setSingleShot(True)
        self._pending_select_timer.timeout.connect(self._apply_pending_select)

        card_layout = QVBoxLayout(self)
        card_layout.setContentsMargins(2, 2, 2, 2)
        card_layout.setSpacing(2)

        self._content = QWidget()
        self._content.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)

        self._status_widget = JobCardStatusWidget(main_window)
        self._dblclick_filter: _JobCardDblClickFilter | None = None
        self._status_widget.setSizePolicy(
            QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed
        )
        self._status_widget.installEventFilter(self)
        self._content.installEventFilter(self)

        self._refs = _FlowReferenceThumbs(main_window, [])
        self._ensure_content_layout(False)
        card_layout.addWidget(self._content, 1)
        self._ensure_child_widgets_forward_drops()
        self._apply_card_style()

    def job_id(self) -> str:
        return self._job_id

    def row_index(self) -> int:
        return self._row_idx

    def set_row_index(self, row_idx: int) -> None:
        self._row_idx = row_idx

    def rebind_for_row(
        self, row_idx: int, job_id: str, *, is_active: bool
    ) -> None:
        job_changed = job_id != self._job_id
        self._row_idx = row_idx
        self._job_id = job_id
        self.set_active_row(is_active)
        if job_changed:
            self._last_view_fingerprint = None
            self._last_status_view = None
            self._content_deferred = False
            self._deferred_thumbnail_paths = None
            self._deferred_references_invalid = False

    def is_active_row(self) -> bool:
        return self._is_active

    def set_active_row(self, is_active: bool) -> None:
        is_active = bool(is_active)
        if self._is_active == is_active:
            return
        self._is_active = is_active
        self._apply_card_style()

    def _ensure_child_widgets_forward_drops(self) -> None:
        """Route drops on text/ref chrome to the card frame."""
        for widget in (self._content, self._status_widget, self._refs):
            widget.setAcceptDrops(False)

    def set_selected(self, selected: bool) -> None:
        selected = bool(selected)
        if self._selected == selected:
            return
        self._selected = selected
        self._apply_card_style()
        if self._last_content_width <= 0:
            self.updateGeometry()

    def attach_action_bar(self, bar: QWidget) -> None:
        """Embed the shared action bar at the bottom of this card."""
        if self._action_bar is bar:
            layout = self.layout()
            if layout is not None and layout.indexOf(bar) >= 0:
                bar.show()
                self._resync_height_after_action_bar_change()
                return
        self.detach_action_bar()
        layout = self.layout()
        if layout is None:
            return
        self._action_bar = bar
        bar.setParent(self)
        layout.addWidget(bar, 0)
        bar.show()
        self._resync_height_after_action_bar_change()

    def detach_action_bar(self) -> None:
        bar = self._action_bar
        if bar is None:
            return
        layout = self.layout()
        if layout is not None:
            layout.removeWidget(bar)
        self._action_bar = None
        self._resync_height_after_action_bar_change()

    def has_action_bar(self) -> bool:
        return self._action_bar is not None

    def _action_bar_block_height(self) -> int:
        bar = self._action_bar
        if bar is None or not bar.isVisible():
            return 0
        layout = self.layout()
        spacing = layout.spacing() if layout is not None else 0
        h = bar.height()
        if h <= 0:
            hint = bar.sizeHint().height()
            h = hint if hint > 0 else _ACTION_BAR_HEIGHT
        return spacing + h

    def _resync_height_after_action_bar_change(self) -> None:
        if self._last_content_width > 0:
            self._sync_card_height(
                self._last_content_width,
                scroll_width=self._scroll_width or None,
            )
        else:
            self.updateGeometry()

    def _frame_border_width_px(self) -> int:
        return _job_selection_border_width_px() if self._selected else 1

    def _layout_vertical_margins_px(self) -> int:
        layout = self.layout()
        if layout is None:
            return 4
        m = layout.contentsMargins()
        return m.top() + m.bottom()

    def _card_frame_minimum_height(self, content_h: int) -> int:
        return (
            content_h
            + self._action_bar_block_height()
            + self._layout_vertical_margins_px()
            + (2 * self._frame_border_width_px())
        )

    def _apply_cell_chrome_stylesheet(self) -> None:
        running = self._is_active
        self.setStyleSheet(
            _job_card_stylesheet(selected=self._selected, running=running)
        )
        content = getattr(self, "_content", None)
        if content is not None:
            _apply_job_queue_cell_background(content, running=running)

    def _apply_card_style(self) -> None:
        self._apply_cell_chrome_stylesheet()
        self.setCursor(
            Qt.CursorShape.OpenHandCursor
            if not self._drag_started
            else Qt.CursorShape.ClosedHandCursor
        )
        if self._last_content_width > 0 and self._last_status_view is not None:
            self._sync_card_height(
                self._last_content_width,
                scroll_width=self._scroll_width or None,
            )

    def _select_self(self) -> None:
        if self._on_select is not None:
            self._on_select(self._job_id)

    def _force_select_self(self) -> None:
        self._cancel_pending_select()
        if self._on_select_force is not None:
            self._on_select_force(self._job_id)

    def _schedule_select_toggle(self) -> None:
        self._pending_select_timer.start(QApplication.doubleClickInterval())

    def _cancel_pending_select(self) -> None:
        self._pending_select_timer.stop()

    def _apply_pending_select(self) -> None:
        self._select_self()

    def _open_edit_dialog(self) -> None:
        job_queue_edit_row(self._main_window, self._controller, self._row_idx)

    def _event_pos_in_card(self, obj: QObject, event: QMouseEvent) -> QPoint:
        pos = event.position().toPoint()
        if obj is self:
            return pos
        widget = obj if isinstance(obj, QWidget) else None
        if widget is None:
            return pos
        return self.mapFromGlobal(widget.mapToGlobal(pos))

    def _is_card_drag_source(self, obj: QObject) -> bool:
        if obj is self or obj is self._content or obj is self._status_widget:
            return True
        if isinstance(obj, QWidget) and self._status_widget.isAncestorOf(obj):
            return not isinstance(obj, QPushButton)
        return False

    def _is_card_drop_forward_target(self, obj: QObject) -> bool:
        return obj in (self, self._content, self._status_widget)

    def _handle_drag_mouse_press(self, pos_in_card: QPoint) -> None:
        self._schedule_select_toggle()
        self._drag_start_pos = pos_in_card
        self._drag_started = False

    def _handle_drag_mouse_move(self, pos_in_card: QPoint, buttons) -> bool:
        if (
            self._drag_start_pos is not None
            and buttons & Qt.MouseButton.LeftButton
            and not self._drag_started
        ):
            distance = (pos_in_card - self._drag_start_pos).manhattanLength()
            if distance >= QApplication.startDragDistance():
                self._start_drag()
                self._drag_started = True
                return True
        return False

    def _handle_drag_mouse_release(self) -> None:
        self._drag_start_pos = None
        self._drag_started = False
        self.setCursor(Qt.CursorShape.OpenHandCursor)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self._handle_drag_mouse_press(event.position().toPoint())
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self._force_select_self()
            self._open_edit_dialog()
            event.accept()
            return
        super().mouseDoubleClickEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._handle_drag_mouse_move(
            event.position().toPoint(), event.buttons()
        ):
            event.accept()
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._handle_drag_mouse_release()
        super().mouseReleaseEvent(event)

    def _start_drag(self) -> None:
        self._cancel_pending_select()
        mime = QMimeData()
        mime.setData(_JOB_QUEUE_DRAG_MIME, self._job_id.encode("utf-8"))
        drag = QDrag(self)
        drag.setMimeData(mime)
        try:
            drag.exec(Qt.DropAction.MoveAction)
        finally:
            if self._on_drop_hover_clear is not None:
                self._on_drop_hover_clear()

    def _reorder_drag_payload(self, event) -> str | None:
        if not event.mimeData().hasFormat(_JOB_QUEUE_DRAG_MIME):
            return None
        payload = bytes(event.mimeData().data(_JOB_QUEUE_DRAG_MIME)).decode("utf-8")
        if not payload or payload == self._job_id:
            return None
        return payload

    def _insert_index_for_drag_y(self, local_y: float) -> int:
        insert_after = local_y > (self.height() / 2)
        anchor_row = self._controller.row_index_for_job_id(self._job_id)
        if anchor_row < 0:
            anchor_row = self._row_idx
        return anchor_row + (1 if insert_after else 0)

    def _before_job_id_for_drag_y(self, local_y: float) -> str | None:
        insert_after = local_y > (self.height() / 2)
        rows = self._controller.queue_snapshot()
        anchor_row = self._controller.row_index_for_job_id(self._job_id)
        if anchor_row < 0:
            anchor_row = self._row_idx
        insert_index = anchor_row + (1 if insert_after else 0)
        if insert_index >= len(rows):
            return None
        return rows[insert_index].job_id

    def _notify_drag_auto_scroll(self, event) -> None:
        if self._on_drag_auto_scroll is None:
            return
        self._on_drag_auto_scroll(self.mapToGlobal(event.position().toPoint()))

    def dragEnterEvent(self, event) -> None:
        if self._reorder_drag_payload(event) is not None:
            if self._on_drop_hover is not None:
                self._on_drop_hover(self._insert_index_for_drag_y(event.position().y()))
            self._notify_drag_auto_scroll(event)
            event.acceptProposedAction()
            return
        event.ignore()

    def dragMoveEvent(self, event) -> None:
        if self._reorder_drag_payload(event) is not None:
            if self._on_drop_hover is not None:
                self._on_drop_hover(self._insert_index_for_drag_y(event.position().y()))
            self._notify_drag_auto_scroll(event)
            event.acceptProposedAction()
            return
        event.ignore()

    def dropEvent(self, event) -> None:
        payload = self._reorder_drag_payload(event)
        if payload is None:
            event.ignore()
            return
        before_job_id = self._before_job_id_for_drag_y(event.position().y())
        if self._on_reorder_drop is not None:
            self._on_reorder_drop(payload, before_job_id)
        event.acceptProposedAction()

    def eventFilter(self, obj, event) -> bool:
        if self._is_card_drop_forward_target(obj):
            if event.type() == QEvent.Type.DragEnter:
                self.dragEnterEvent(event)  # type: ignore[arg-type]
                return event.isAccepted()
            if event.type() == QEvent.Type.DragMove:
                self.dragMoveEvent(event)  # type: ignore[arg-type]
                return event.isAccepted()
            if event.type() == QEvent.Type.Drop:
                self.dropEvent(event)  # type: ignore[arg-type]
                return event.isAccepted()
        if self._is_card_drag_source(obj):
            if event.type() == QEvent.Type.MouseButtonPress:
                mouse = event  # type: ignore[assignment]
                if mouse.button() == Qt.MouseButton.LeftButton:
                    self._handle_drag_mouse_press(
                        self._event_pos_in_card(obj, mouse)
                    )
                    return True
            if event.type() == QEvent.Type.MouseMove:
                mouse = event  # type: ignore[assignment]
                if self._handle_drag_mouse_move(
                    self._event_pos_in_card(obj, mouse), mouse.buttons()
                ):
                    return True
            if event.type() == QEvent.Type.MouseButtonRelease:
                self._handle_drag_mouse_release()
        return super().eventFilter(obj, event)

    def _ensure_dblclick_edit_filter(self) -> None:
        """Install after prompt tooltip so this filter runs first on dbl-click."""
        if self._dblclick_filter is not None:
            return
        opener = lambda: job_queue_edit_row(
            self._main_window, self._controller, self._row_idx
        )
        filt = _JobCardDblClickFilter(
            opener, on_force_select=self._force_select_self, parent=self
        )
        self._dblclick_filter = filt
        self._status_widget.installEventFilter(filt)

    def _ref_count(self) -> int:
        if getattr(self._refs, "_references_invalid", False):
            return 1
        return len(getattr(self._refs, "_paths", []) or [])

    def _use_inline_refs_layout(self, scroll_width: int) -> bool:
        return (
            scroll_width > JOB_CELL_INLINE_REFS_MIN_SCROLL_WIDTH
            and 1 <= self._ref_count() <= 2
        )

    def _status_content_width(self, content_width: int, scroll_width: int) -> int:
        if self._use_inline_refs_layout(scroll_width):
            reserved = (
                _THUMB_SIZE
                + JOB_CELL_INLINE_REFS_RIGHT_PADDING_PX
                + _JOB_CELL_INLINE_TEXT_REFS_SPACING
            )
            return max(80, content_width - reserved)
        return max(80, content_width)

    def _ensure_content_layout(self, inline: bool) -> None:
        if inline == self._content_inline and self._content.layout() is not None:
            return
        self._content_inline = inline
        old_layout = self._content.layout()
        if old_layout is not None:
            old_layout.removeWidget(self._status_widget)
            old_layout.removeWidget(self._refs)
            QWidget().setLayout(old_layout)
        if inline:
            layout = QHBoxLayout(self._content)
            layout.setContentsMargins(
                0, 0, JOB_CELL_INLINE_REFS_RIGHT_PADDING_PX, 0
            )
            layout.setSpacing(_JOB_CELL_INLINE_TEXT_REFS_SPACING)
            self._refs.setSizePolicy(
                QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed
            )
            layout.addWidget(self._status_widget, 1, Qt.AlignmentFlag.AlignTop)
            layout.addWidget(
                self._refs,
                0,
                Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignRight,
            )
        else:
            layout = QVBoxLayout(self._content)
            layout.setContentsMargins(0, 0, 0, 0)
            layout.setSpacing(2)
            self._refs.setSizePolicy(
                QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
            )
            layout.addWidget(self._status_widget, 0, Qt.AlignmentFlag.AlignTop)
            layout.addWidget(
                self._refs,
                0,
                Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignRight,
            )

    def _reflow_visible_refs(self, content_width: int, scroll_width: int) -> None:
        if not self._refs.isVisible():
            return
        if self._use_inline_refs_layout(scroll_width):
            self._refs.reflow_to_width(_THUMB_SIZE, force_cols=1)
        else:
            self._refs.reflow_to_width(max(_THUMB_SIZE, content_width))

    def _sync_card_height(
        self,
        content_width: int,
        *,
        status_h: int | None = None,
        scroll_width: int | None = None,
    ) -> None:
        sw = scroll_width if scroll_width is not None else self._scroll_width
        self._ensure_content_layout(self._use_inline_refs_layout(sw))
        self._reflow_visible_refs(content_width, sw)
        refs_h = self._refs.sizeHint().height() if self._refs.isVisible() else 0
        if status_h is None:
            status_h = self._status_widget.sizeHint().height()
        if self._use_inline_refs_layout(sw):
            content_h = max(status_h, refs_h) + 2
        else:
            content_h = status_h + refs_h + 2
        frame_h = self._card_frame_minimum_height(content_h)
        if (
            self._content.minimumHeight() == content_h
            and self._content.maximumHeight() == content_h
            and self.minimumHeight() == frame_h
        ):
            return
        self._content.setMinimumHeight(content_h)
        self._content.setMaximumHeight(content_h)
        self.setMinimumHeight(frame_h)
        self.setMaximumHeight(16777215)
        self.updateGeometry()

    def set_row_content(
        self,
        *,
        status_view,
        full_prompt: str,
        thumbnail_paths: list[str],
        content_width: int,
        scroll_width: int,
        references_invalid: bool = False,
    ) -> None:
        self._scroll_width = scroll_width
        self._full_prompt = full_prompt or ""
        install_delayed_prompt_tooltip(
            self._status_widget,
            self._full_prompt,
            displayed_prompt=self._status_widget.displayed_prompt_text(),
        )
        self._ensure_dblclick_edit_filter()
        self._replace_refs(
            thumbnail_paths,
            content_width,
            scroll_width=scroll_width,
            references_invalid=references_invalid,
        )
        self.update_status_view(status_view, content_width, scroll_width=scroll_width)

    def update_status_view(
        self,
        status_view,
        content_width: int,
        *,
        scroll_width: int | None = None,
    ) -> None:
        sw = (
            scroll_width
            if scroll_width is not None
            else self._scroll_width or (content_width + _CARD_CONTENT_MARGIN)
        )
        self._scroll_width = sw
        self._last_content_width = content_width
        self._ensure_content_layout(self._use_inline_refs_layout(sw))
        self._last_status_view = status_view
        text_w = self._status_content_width(content_width, sw)
        fp = status_view.fingerprint() if status_view is not None else None
        width_changed = text_w != self._status_widget.width()
        if (
            fp == self._last_view_fingerprint
            and self._status_widget.has_rendered_view()
            and not width_changed
        ):
            self._status_widget.update_live_fields(status_view)
        else:
            self._status_widget.set_status_view(status_view, text_w)
            self._last_view_fingerprint = fp
        self._status_widget.setFixedWidth(text_w)
        self._status_widget.setSizePolicy(
            QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed
        )
        self._apply_cell_chrome_stylesheet()
        self._sync_card_height(content_width, scroll_width=sw)
        update_delayed_prompt_tooltip(
            self._status_widget,
            self._full_prompt,
            displayed_prompt=self._status_widget.displayed_prompt_text(),
        )
        self.setMinimumWidth(0)
        self.setMaximumWidth(16777215)

    def _replace_refs(
        self,
        paths: list[str],
        content_width: int,
        *,
        scroll_width: int | None = None,
        references_invalid: bool = False,
        defer_thumbnails: bool = False,
    ) -> None:
        sw = (
            scroll_width
            if scroll_width is not None
            else self._scroll_width or (content_width + _CARD_CONTENT_MARGIN)
        )
        self._scroll_width = sw
        if defer_thumbnails:
            self._deferred_thumbnail_paths = list(paths)
            self._deferred_references_invalid = references_invalid
            paths = []
            references_invalid = False
        else:
            self._deferred_thumbnail_paths = None
            self._deferred_references_invalid = False
        valid = [] if references_invalid else _valid_preview_paths(paths)
        inline = self._use_inline_refs_layout(sw)
        if (
            self._refs.isVisible()
            and getattr(self._refs, "_paths", None) == valid
            and getattr(self._refs, "_references_invalid", False) == references_invalid
            and inline == self._content_inline
        ):
            self._reflow_visible_refs(content_width, sw)
            return
        layout = self._content.layout()
        if layout is not None:
            layout.removeWidget(self._refs)
        self._refs.deleteLater()
        self._refs = _FlowReferenceThumbs(
            self._main_window,
            paths,
            references_invalid=references_invalid,
        )
        mode_changed = inline != self._content_inline
        self._ensure_content_layout(inline)
        if not mode_changed:
            layout = self._content.layout()
            if layout is not None:
                layout.addWidget(
                    self._refs,
                    0,
                    Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignRight,
                )
        self._reflow_visible_refs(content_width, sw)

    def reflow_layout(self, content_width: int, scroll_width: int) -> None:
        """Reflow refs and reclamp prompt width without rebuilding status rows."""
        sw = scroll_width
        self._scroll_width = sw
        self._last_content_width = content_width
        self._ensure_content_layout(self._use_inline_refs_layout(sw))
        text_w = self._status_content_width(content_width, sw)
        if (
            self._last_status_view is not None
            and self._status_widget.has_rendered_view()
        ):
            self._status_widget.set_content_width(text_w)
            self._status_widget.setFixedWidth(text_w)
        self._reflow_visible_refs(content_width, sw)
        self.setMinimumWidth(0)
        self.setMaximumWidth(16777215)
        self._sync_card_height(content_width, scroll_width=sw)

    def reflow_refs(self, scroll_width: int) -> None:
        content_width = max(80, scroll_width - _CARD_CONTENT_MARGIN)
        self.reflow_layout(content_width, scroll_width)


class JobQueuePanelWidget(QWidget):
    """Scrollable job queue with active progress strip (shared by pane and dialog)."""

    def __init__(self, main_window, parent=None, *, job_control_dialog: bool = False):
        super().__init__(parent)
        self.main_window = main_window
        self._job_control_dialog = job_control_dialog
        self._controller = get_imagegen_controller(main_window)
        self._job_cards: list[JobCard] = []
        self._card_pool: list[JobCard] = []
        self._refresh_table_timer: QTimer | None = None
        self._resize_timer: QTimer | None = None
        self._empty_state_sync_timer: QTimer | None = None
        self._queue_size_mode = QUEUE_SIZE_ALL
        self._signal_connected = False
        self._live_refresh_paused = False
        self._deferred_table_refresh = False
        self._startup_card_refresh_pending = False
        self._startup_refresh_hook_registered = False
        self._header_getter: Callable[[], QWidget | None] | None = None
        self._on_compact_geometry_changed: Callable[[], None] | None = None
        self._floating_window: QWidget | None = None
        self._floating_drag_via_client_getter: Callable[[], bool] | None = None
        self._floating_double_click_callback: Callable[[], None] | None = None
        self._floating_drag_filter_targets: list[QWidget] = []
        self._preparing_size_measure = False
        self._flyout_button: QPushButton | None = None
        self._drop_indicator_index: int | None = None
        self._drop_line: _JobQueueDropLine | None = None
        self._drag_hover_viewport_pos: QPoint | None = None
        self._auto_scroll_timer = QTimer(self)
        self._auto_scroll_timer.timeout.connect(self._handle_drag_auto_scroll)
        self._auto_scroll_direction = 0
        self._auto_scroll_speed = 0.0
        settings = main_window.config.load_settings()
        self._show_toolbar = bool(settings.get("jobs_show_toolbar", True))
        self._toolbar = None
        self._setup_ui()
        self._connect_controller()

    def _jobs_ui_active(self) -> bool:
        if self._job_control_dialog:
            return self.isVisible()
        rs = getattr(self.main_window, "right_sidebar", None)
        if rs is not None and hasattr(rs, "is_jobs_visible") and rs.is_jobs_visible():
            return True
        return False

    def _should_use_startup_pass(self) -> bool:
        if os.environ.get("PROWSER_QUIT_AFTER_STARTUP", "").strip().lower() in (
            "1",
            "true",
            "yes",
        ):
            return False
        if getattr(self.main_window, "_startup_refresh_complete", False):
            return False
        return bool(self._controller.queue_snapshot())

    def _startup_priority_row_indices(self, rows) -> set[int]:
        priority: set[int] = set()
        if not rows:
            return priority
        priority.add(0)
        for idx, row in enumerate(rows):
            if row.is_active:
                priority.add(idx)
        if hasattr(self, "_scroll") and self._job_cards:
            viewport = self._scroll.viewport()
            vp_rect = viewport.rect()
            vp_top = vp_rect.top()
            vp_bottom = vp_rect.bottom()
            for idx, card in enumerate(self._job_cards):
                if idx >= len(rows):
                    break
                card_top = card.mapTo(viewport, QPoint(0, 0)).y()
                card_bottom = card_top + card.height()
                if card_bottom > vp_top and card_top < vp_bottom:
                    priority.add(idx)
        return priority

    def _apply_deferred_row_shell_to_job_card(
        self,
        card: JobCard,
        row_idx: int,
        row,
        info_w: int,
        viewport_w: int,
    ) -> None:
        from imagegen_plugins.job_status_views import EMPTY_QUEUE_STATUS_VIEW
        from imagegen_plugins.model_task_status_info import (
            build_queue_job_title_only_view,
        )

        card.set_row_index(row_idx)
        card.set_active_row(row.is_active)
        card._full_prompt = row.full_prompt or ""
        card._content_deferred = True
        card._deferred_thumbnail_paths = list(row.thumbnail_paths or [])
        card._deferred_references_invalid = row.references_invalid
        job = self._controller._queued_job_by_id(row.job_id)
        if job is not None:
            status_view = build_queue_job_title_only_view(
                job.plugin,
                job.values,
                plugin_id=job.plugin_id,
                function=job.function,
                plugin_unavailable=job.plugin_unavailable,
            )
        else:
            status_view = row.status_view or EMPTY_QUEUE_STATUS_VIEW
        card.update_status_view(status_view, info_w, scroll_width=viewport_w)
        card.reflow_refs(viewport_w)

    def _complete_startup_card_refresh(self) -> None:
        if not self._startup_card_refresh_pending:
            return
        self._startup_card_refresh_pending = False
        if not self._job_cards:
            return
        rows = self._controller.queue_snapshot()
        info_w = self._info_content_width()
        viewport_w = self._viewport_width()
        geometry_needed = False
        for row_idx, card in enumerate(self._job_cards):
            if row_idx >= len(rows):
                break
            row = rows[row_idx]
            if card._content_deferred:
                card._content_deferred = False
                self._apply_row_to_job_card(
                    card, row_idx, row, info_w, viewport_w
                )
                geometry_needed = True
            elif card._deferred_thumbnail_paths is not None:
                card._replace_refs(
                    card._deferred_thumbnail_paths,
                    info_w,
                    scroll_width=viewport_w,
                    references_invalid=card._deferred_references_invalid,
                )
                geometry_needed = True
        if geometry_needed:
            self._notify_sidebar_geometry_if_needed(on_queue_change=True)

    def _flush_deferred_table_refresh(self) -> None:
        if not self._deferred_table_refresh and self._job_cards:
            return
        self._deferred_table_refresh = False
        startup_pass = self._should_use_startup_pass()
        if startup_pass:
            self._startup_card_refresh_pending = True
        self.refresh_table(startup_pass=startup_pass)

    def ensure_table_ready_for_show(self) -> None:
        """Build job cards before dialog/pane layout measure on first show."""
        startup_pass = self._should_use_startup_pass()
        if startup_pass:
            self._startup_card_refresh_pending = True
        if self._deferred_table_refresh or not self._job_cards:
            if startup_pass:
                self._deferred_table_refresh = False
                self.refresh_table(startup_pass=True)
            else:
                self._flush_deferred_table_refresh()
        if not self._job_cards and self._controller.queue_snapshot():
            self.refresh_table(startup_pass=startup_pass)

    def _defer_queue_empty_state_sync(self) -> None:
        """Re-apply empty/progress layout after worker/controller state settles."""
        if not self._jobs_ui_active():
            return
        timer = self._empty_state_sync_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self._sync_queue_empty_state_layout)
            self._empty_state_sync_timer = timer
        timer.start(0)

    def _sync_queue_empty_state_layout(self) -> None:
        self._refresh_active_job_strip(force=True)
        self._apply_queue_size_layout()
        self._notify_sidebar_geometry_if_needed(on_queue_change=True)

    def set_header_getter(self, getter: Callable[[], QWidget | None] | None) -> None:
        self._header_getter = getter

    def set_on_compact_geometry_changed(
        self, callback: Callable[[], None] | None
    ) -> None:
        self._on_compact_geometry_changed = callback

    def configure_floating_window_move(
        self,
        window: QWidget | None,
        *,
        drag_via_client_getter: Callable[[], bool] | None = None,
        double_click_callback: Callable[[], None] | None = None,
    ) -> None:
        """Drag the frameless dialog from client chrome when the title bar is hidden."""
        self._floating_window = window
        self._floating_drag_via_client_getter = drag_via_client_getter
        self._floating_double_click_callback = double_click_callback
        for widget in self._floating_drag_filter_targets:
            widget.removeEventFilter(self)
        self._floating_drag_filter_targets.clear()
        if window is None:
            return
        targets = [self._active_job_strip, self._empty_label]
        strip = self._active_job_strip
        for attr in ("_frame", "_browser"):
            child = getattr(strip, attr, None)
            if child is not None:
                targets.append(child)
        browser = getattr(strip, "_browser", None)
        if browser is not None and browser.viewport() is not None:
            targets.append(browser.viewport())
        for widget in targets:
            widget.installEventFilter(self)
            self._floating_drag_filter_targets.append(widget)

    def _floating_client_drag_active(self) -> bool:
        return (
            self._floating_window is not None
            and self._floating_drag_via_client_getter is not None
            and self._floating_drag_via_client_getter()
        )

    def _mouse_event_hits_interactive_target(
        self, event: QMouseEvent, watched: QObject
    ) -> bool:
        widget = watched if isinstance(watched, QWidget) else None
        while widget is not None:
            if isinstance(widget, QAbstractButton):
                return True
            widget = widget.parentWidget()
        return False

    def _try_start_floating_client_drag(
        self, event: QMouseEvent, watched: QObject | None = None
    ) -> bool:
        if not self._floating_client_drag_active():
            return False
        if event.button() != Qt.MouseButton.LeftButton:
            return False
        if watched is not None and self._mouse_event_hits_interactive_target(
            event, watched
        ):
            return False
        from utils import try_start_frameless_system_move

        if try_start_frameless_system_move(
            self._floating_window, event.globalPosition().toPoint()
        ):
            event.accept()
            return True
        return False

    def _try_handle_floating_client_double_click(
        self, event: QMouseEvent, watched: QObject | None = None
    ) -> bool:
        if not self._floating_client_drag_active():
            return False
        if event.button() != Qt.MouseButton.LeftButton:
            return False
        if watched is not None and self._mouse_event_hits_interactive_target(
            event, watched
        ):
            return False
        cb = self._floating_double_click_callback
        if cb is None:
            return False
        cb()
        event.accept()
        return True

    def _job_queue_dialog_for_menu(self):
        window = self.window()
        if hasattr(window, "is_job_queue_always_on_top"):
            return window
        return None

    def _show_jobs_pane_context_menu(self, global_pos) -> None:
        from imagegen_plugins.jobs_tools_menu import show_jobs_context_menu

        show_jobs_context_menu(
            self,
            global_pos,
            job_queue_dialog=self._job_queue_dialog_for_menu(),
        )

    def is_jobs_toolbar_visible(self) -> bool:
        return bool(self._show_toolbar)

    def set_jobs_toolbar_visible(self, visible: bool) -> None:
        visible = bool(visible)
        if self._show_toolbar == visible:
            return
        self._show_toolbar = visible
        self.main_window.config.update_setting("jobs_show_toolbar", visible)
        if self._toolbar is not None:
            self._toolbar.set_toolbar_visible(visible)
        QTimer.singleShot(0, self._refit_after_toolbar_visibility_change)

    def _refit_after_toolbar_visibility_change(self) -> None:
        self._sync_fixed_panel_geometry()
        self._notify_sidebar_geometry_if_needed()

    def jobs_toolbar_action_specs(self) -> list[dict[str, object]]:
        from imagegen_plugins.image_gen_persistence import load_show_progressive_images

        inter_state = self._controller.get_show_progressive_images_menu_state()
        inter_enabled = inter_state is not None
        inter_checked = (
            inter_state if inter_state is not None else load_show_progressive_images()
        )
        return [
            {
                "action_id": "intermediate_images",
                "label": "Intermediate Images",
                "visible": True,
                "enabled": inter_enabled,
                "checkable": True,
                "checked": bool(inter_checked),
            },
            {
                "action_id": "hold_queue",
                "label": "Hold Job Queue",
                "visible": True,
                "enabled": True,
                "checkable": True,
                "checked": self._controller.hold_job_queue(),
            },
            {
                "action_id": "skip_copy",
                "label": "Skip This Copy",
                "visible": True,
                "enabled": self._controller.can_skip_active_series_copy(),
                "tooltip": "End the current copy and start the next one in this series.",
            },
        ]

    def trigger_jobs_toolbar_action(
        self, action_id: str, checked: bool | None = None
    ) -> None:
        if action_id == "intermediate_images":
            if checked is None:
                btn = None if self._toolbar is None else self._toolbar.button(
                    "intermediate_images"
                )
                checked = btn.isChecked() if btn is not None else False
            self._controller.set_show_progressive_images(bool(checked))
        elif action_id == "hold_queue":
            if checked is None:
                btn = None if self._toolbar is None else self._toolbar.button("hold_queue")
                checked = btn.isChecked() if btn is not None else (
                    not self._controller.hold_job_queue()
                )
            self._controller.set_hold_job_queue(bool(checked))
        elif action_id == "skip_copy":
            self._controller.skip_active_series_copy()
        self._update_jobs_toolbar_state()
        schedule_restore_main_canvas_focus(self.main_window)

    def _update_jobs_toolbar_state(self) -> None:
        if self._toolbar is None:
            return
        skipping_copy = self._controller.is_skipping_active_series_copy()
        self._toolbar.set_skipping_copy_active(skipping_copy)
        if skipping_copy:
            self._toolbar.refresh_theme_styles()
            return
        specs = {spec["action_id"]: spec for spec in self.jobs_toolbar_action_specs()}
        for action_id in ("intermediate_images", "hold_queue", "skip_copy"):
            spec = specs.get(action_id)
            if spec is None:
                continue
            self._toolbar.set_action_enabled(action_id, bool(spec["enabled"]))
            if spec.get("checkable"):
                if action_id == "intermediate_images":
                    self._toolbar.set_intermediate_checked(bool(spec.get("checked")))
                elif action_id == "hold_queue":
                    self._toolbar.set_hold_checked(bool(spec.get("checked")))
        self._toolbar.refresh_theme_styles()

    def _toolbar_block_height(self) -> int:
        if self._toolbar is None or not self._show_toolbar:
            return 0
        h = self._toolbar.height()
        if h <= 0:
            h = self._toolbar.sizeHint().height()
        return max(0, h)

    def attach_header_tools(self) -> None:
        """Wire titlebar tools menu and flyout button on the bound header (if any)."""
        from imagegen_plugins.jobs_tools_menu import show_jobs_tools_menu

        header = self._jobs_header()
        if header is None:
            return
        btn = QPushButton()
        btn.setToolTip("Job queue tools")
        btn.clicked.connect(
            lambda: show_jobs_tools_menu(
                self,
                btn,
                job_queue_dialog=self._job_queue_dialog_for_menu(),
            )
        )
        if hasattr(header, "set_tools_button"):
            header.set_tools_button(btn)

        from imagegen_plugins.jobs_display_mode import (
            JOBS_DISPLAY_PANE,
            get_jobs_display_mode,
        )

        pane_mode = get_jobs_display_mode(self.main_window) == JOBS_DISPLAY_PANE
        fly_btn = QPushButton()
        fly_btn.setProperty("_titlebar_flyout_pane_mode", pane_mode)
        fly_btn.clicked.connect(self._on_flyout_clicked)
        if hasattr(header, "set_flyout_button"):
            header.set_flyout_button(fly_btn)
        self._flyout_button = fly_btn
        refresh_jobs_flyout_buttons(self.main_window)

    def _on_flyout_clicked(self) -> None:
        sm = getattr(self.main_window, "sidebar_manager", None)
        if sm is not None and hasattr(sm, "toggle_jobs_display_mode"):
            sm.toggle_jobs_display_mode()
            return
        from imagegen_plugins.jobs_display_mode import toggle_jobs_display_mode

        toggle_jobs_display_mode(self.main_window)
        schedule_restore_main_canvas_focus(self.main_window)

    def _on_job_selected(self, job_id: str) -> None:
        sole = self._sole_visible_job_card()
        if sole is not None and job_id == sole.job_id():
            self._controller.set_selected_job_id(job_id)
            self._sync_all_panels_selection()
            schedule_restore_main_canvas_focus(self.main_window)
            return
        if self._controller.selected_job_id() == job_id:
            self._controller.set_selected_job_id(None)
        else:
            self._controller.set_selected_job_id(job_id)
        self._sync_all_panels_selection()
        schedule_restore_main_canvas_focus(self.main_window)

    def _on_job_force_selected(self, job_id: str) -> None:
        self._controller.set_selected_job_id(job_id)
        self._sync_all_panels_selection()

    def _sync_all_panels_selection(self) -> None:
        self._sync_selection_ui()
        mw = self.main_window
        rs = getattr(mw, "right_sidebar", None)
        other = getattr(rs, "jobs_widget", None) if rs is not None else None
        if other is not None and other is not self:
            other._sync_selection_ui()
        dlg = getattr(mw, "_imagegen_job_queue_dialog", None)
        panel = getattr(dlg, "_panel", None) if dlg is not None else None
        if panel is not None and panel is not self:
            panel._sync_selection_ui()

    def _is_single_job_mode(self) -> bool:
        return self._queue_size_mode == QUEUE_SIZE_ONE

    def _sole_visible_job_card(self) -> JobCard | None:
        """The one job card shown in the list, if any (one-job mode or sole queue row)."""
        if self._queue_size_mode == QUEUE_SIZE_STRIP or not self._job_cards:
            return None
        if self._queue_size_mode == QUEUE_SIZE_ONE or len(self._job_cards) == 1:
            return self._job_cards[0]
        return None

    def _is_single_visible_job(self) -> bool:
        return self._sole_visible_job_card() is not None

    def _ensure_single_job_auto_selection(self) -> None:
        sole = self._sole_visible_job_card()
        if sole is None:
            return
        job_id = sole.job_id()
        if self._controller.selected_job_id() != job_id:
            self._controller.set_selected_job_id(job_id)

    def _action_bar_row_index(self) -> int:
        """Controller queue row targeted by the shared action bar."""
        sole = self._sole_visible_job_card()
        if sole is not None:
            return sole.row_index()
        return self._controller.resolve_selected_row_index()

    def _action_bar_card_list_index(self) -> int:
        """Job card list index that hosts the embedded action bar."""
        sole = self._sole_visible_job_card()
        if sole is not None:
            return self._job_cards.index(sole)
        row_idx = self._controller.resolve_selected_row_index()
        return row_idx if row_idx >= 0 else -1

    def _should_show_action_bar(self) -> bool:
        """Show when a job card is selected, or always in single-job / sole-row views."""
        if self._queue_size_mode == QUEUE_SIZE_STRIP:
            return False
        if self._is_single_job_mode() and self._job_cards:
            return True
        if self._is_single_visible_job():
            return True
        return self._controller.resolve_selected_row_index() >= 0

    def _refresh_action_bar_if_visible(self) -> None:
        if not self._should_show_action_bar():
            return
        row_idx = self._action_bar_row_index()
        if row_idx < 0:
            return
        self._action_bar.update_for_row(row_idx)

    def _is_action_bar_embedded_on_card(self) -> bool:
        if self._action_bar is None or not self._action_bar.isVisible():
            return False
        return any(card.has_action_bar() for card in self._job_cards)

    def _action_bar_embedded_growth_height(self) -> int:
        """Extra job-card height when the shared action bar is embedded."""
        for card in self._job_cards:
            if card.has_action_bar():
                h = card._action_bar_block_height()
                if h > 0:
                    return h
        if self._action_bar is None:
            return 0
        bar_h = self._action_bar.height()
        if bar_h <= 0:
            bar_h = self._action_bar.sizeHint().height()
        if bar_h <= 0:
            bar_h = _ACTION_BAR_HEIGHT
        return 2 + bar_h

    def _grow_pane_for_action_bar(self) -> None:
        extra = self._action_bar_embedded_growth_height()
        if extra <= 0:
            return
        mode = self._queue_size_mode
        uses_fixed_content = mode in (QUEUE_SIZE_ONE, QUEUE_SIZE_STRIP) or (
            mode == QUEUE_SIZE_ALL
            and (self.should_shrink_wrap_client() or self.queue_job_count() <= 1)
        )
        if uses_fixed_content:
            if self._job_cards and mode == QUEUE_SIZE_ONE:
                self._apply_one_job_scroll_height()
            self._sync_fixed_panel_geometry()

        sidebar = getattr(self.main_window, "right_sidebar", None)
        grow_method = (
            getattr(sidebar, "grow_jobs_pane_for_action_bar", None)
            if sidebar is not None
            else None
        )
        if callable(grow_method):
            if (
                mode == QUEUE_SIZE_ALL
                and not self.should_shrink_wrap_client()
                and self.queue_job_count() > 1
            ):
                grow_method(extra)
            elif uses_fixed_content and hasattr(
                sidebar, "ensure_jobs_pane_fits_content"
            ):
                sidebar.ensure_jobs_pane_fits_content()
            else:
                grow_method(extra)
        else:
            self._notify_shell_geometry_changed()

        if mode == QUEUE_SIZE_ONE:
            QTimer.singleShot(0, self._deferred_action_bar_geometry_sync)

    def _deferred_action_bar_geometry_sync(self) -> None:
        if not self._is_action_bar_embedded_on_card():
            return
        if self._queue_size_mode != QUEUE_SIZE_ONE:
            return
        self._apply_one_job_scroll_height()
        self._sync_fixed_panel_geometry()
        self._notify_sidebar_geometry_if_needed()

    def _sync_action_bar_from_selection(self) -> None:
        was_embedded = self._is_action_bar_embedded_on_card()
        if self._is_single_visible_job():
            self._ensure_single_job_auto_selection()
        if self._should_show_action_bar():
            row_idx = self._action_bar_row_index()
            list_row = self._action_bar_card_list_index()
            self._place_action_bar(list_row)
            self._action_bar.update_for_row(row_idx)
        else:
            self._detach_action_bar()
            self._action_bar.hide()
        if not was_embedded and self._is_action_bar_embedded_on_card():
            self._grow_pane_for_action_bar()
        # When removing the action bar, intentionally do not shrink the pane.

    def _detach_action_bar(self) -> None:
        """Remove the shared action bar from any host card or list layout."""
        for card in self._job_cards:
            if card.has_action_bar():
                card.detach_action_bar()
        layout = self._list_layout
        for i in range(layout.count()):
            item = layout.itemAt(i)
            if item is not None and item.widget() is self._action_bar:
                layout.removeWidget(self._action_bar)
                break
        # Keep the shared bar owned by the panel so card teardown cannot destroy it.
        if self._action_bar.parent() is not self:
            self._action_bar.setParent(self)

    def _place_action_bar(self, row_idx: int) -> None:
        """Embed the action bar inside the target job card."""
        self._detach_action_bar()
        if row_idx < 0 or row_idx >= len(self._job_cards):
            self._action_bar.hide()
            return
        self._job_cards[row_idx].attach_action_bar(self._action_bar)
        self._action_bar.show()

    def _card_layout_height(self, card: JobCard) -> int:
        h = card.minimumHeight()
        if h > 0:
            return h
        return card.sizeHint().height()

    def _on_job_reorder_drop(self, job_id: str, before_job_id: str | None) -> None:
        self._clear_drop_indicator()
        if not self._cards_align_with_snapshot():
            self.refresh_table()
        self._controller.move_job_before(job_id, before_job_id)

    def _insert_index_at_list_y(self, y: int) -> int:
        for idx, card in enumerate(self._job_cards):
            geom = card.geometry()
            if y < geom.top() + (geom.height() / 2):
                return idx
        return len(self._job_cards)

    def _list_host_pos_from_viewport_pos(self, vp_pos: QPoint) -> QPoint:
        viewport = self._scroll.viewport()
        return self._list_host.mapFromGlobal(viewport.mapToGlobal(vp_pos))

    def _viewport_pos_from_list_host_pos(self, host_pos: QPoint) -> QPoint:
        viewport = self._scroll.viewport()
        return viewport.mapFromGlobal(self._list_host.mapToGlobal(host_pos))

    def _resolve_drop_insert_index(self, list_host_y: int | None = None) -> int:
        if self._drop_indicator_index is not None:
            return self._drop_indicator_index
        if list_host_y is not None:
            return self._insert_index_at_list_y(list_host_y)
        return len(self._job_cards)

    def _insert_before_job_id_at_list_y(self, y: int) -> str | None:
        insert_index = self._insert_index_at_list_y(y)
        rows = self._controller.queue_snapshot()
        if insert_index >= len(rows):
            return None
        return rows[insert_index].job_id

    def _finish_job_reorder_drop(self, payload: str, list_host_y: int | None = None) -> None:
        if not payload:
            return
        if not self._cards_align_with_snapshot():
            self.refresh_table()
        before_job_id = None
        if list_host_y is not None:
            before_job_id = self._insert_before_job_id_at_list_y(list_host_y)
        elif self._drop_indicator_index is not None:
            rows = self._controller.queue_snapshot()
            idx = self._drop_indicator_index
            if idx < len(rows):
                before_job_id = rows[idx].job_id
        self._clear_drop_indicator()
        self._on_job_reorder_drop(payload, before_job_id)

    def _drop_line_geometry(self, insert_index: int) -> tuple[int, int, int]:
        margins = self._list_layout.contentsMargins()
        spacing = self._list_layout.spacing()
        viewport = self._scroll.viewport()
        if not self._job_cards:
            x_host = margins.left()
            w = max(1, self._list_host.width() - margins.left() - margins.right())
            y_host = margins.top()
            pt = self._list_host.mapTo(viewport, QPoint(x_host, y_host))
            return pt.x(), pt.y(), w

        if insert_index <= 0:
            ref = self._job_cards[0]
            gap_host = ref.mapTo(self._list_host, QPoint(0, 0))
            gap_y = gap_host.y() - max(1, spacing // 2)
        elif insert_index >= len(self._job_cards):
            ref = self._job_cards[-1]
            gap_host = ref.mapTo(self._list_host, QPoint(0, ref.height()))
            gap_y = gap_host.y() + max(1, spacing // 2)
        else:
            ref = self._job_cards[insert_index]
            gap_host = ref.mapTo(self._list_host, QPoint(0, 0))
            gap_y = gap_host.y() - max(1, spacing // 2)

        ref_tl = ref.mapTo(self._list_host, QPoint(0, 0))
        pt = self._list_host.mapTo(viewport, QPoint(ref_tl.x(), gap_y))
        return pt.x(), pt.y(), ref.width()

    def _show_drop_indicator(self, insert_index: int) -> None:
        insert_index = max(0, min(int(insert_index), len(self._job_cards)))
        self._drop_indicator_index = insert_index
        line = self._drop_line
        if line is None:
            return
        x, y, w = self._drop_line_geometry(insert_index)
        line.setGeometry(
            x, y - _DROP_LINE_HEIGHT // 2, max(1, w), _DROP_LINE_HEIGHT
        )
        line.show()
        line.raise_()
        line.update()

    def _clear_drop_indicator(self) -> None:
        self._drop_indicator_index = None
        self._drag_hover_viewport_pos = None
        if self._drop_line is not None:
            self._drop_line.hide()
        self._stop_drag_auto_scroll()

    def _update_drag_auto_scroll_at_global(self, global_pos: QPoint) -> None:
        viewport = self._scroll.viewport()
        if viewport is None:
            self._stop_drag_auto_scroll()
            return
        vp_pos = viewport.mapFromGlobal(global_pos)
        if vp_pos.x() < 0 or vp_pos.x() > viewport.width():
            self._stop_drag_auto_scroll()
            return
        self._drag_hover_viewport_pos = vp_pos
        self._update_drag_auto_scroll_viewport_y(vp_pos.y())

    def _update_drag_auto_scroll_viewport_y(self, y_in_viewport: float) -> None:
        scroll_bar = self._scroll.verticalScrollBar()
        if scroll_bar.maximum() <= 0:
            self._stop_drag_auto_scroll()
            return

        viewport = self._scroll.viewport()
        viewport_height = viewport.height()
        distance_from_top = max(0.0, y_in_viewport)
        distance_from_bottom = max(0.0, viewport_height - y_in_viewport)

        scroll_direction = 0
        scroll_speed = 0.0
        band_max = tc.DRAG_AUTO_SCROLL_SPEEDS[0][0]

        if distance_from_top < distance_from_bottom:
            if distance_from_top <= band_max:
                scroll_direction = -1
                scroll_speed = self._calculate_drag_auto_scroll_speed(distance_from_top)
        else:
            if distance_from_bottom <= band_max:
                scroll_direction = 1
                scroll_speed = self._calculate_drag_auto_scroll_speed(distance_from_bottom)

        if scroll_direction != 0 and scroll_speed > 0:
            self._auto_scroll_direction = scroll_direction
            self._auto_scroll_speed = scroll_speed
            if not self._auto_scroll_timer.isActive():
                self._auto_scroll_timer.start(16)
        else:
            self._stop_drag_auto_scroll()

    def _calculate_drag_auto_scroll_speed(self, distance_from_edge: float) -> float:
        speeds = tc.DRAG_AUTO_SCROLL_SPEEDS
        if not speeds:
            return 0.0
        for i in range(len(speeds)):
            dist, speed = speeds[i]
            if distance_from_edge >= dist:
                if i == 0:
                    return speed
                prev_dist, prev_speed = speeds[i - 1]
                if prev_dist == dist:
                    return speed
                ratio = (distance_from_edge - dist) / (prev_dist - dist)
                return speed + ratio * (prev_speed - speed)
        return speeds[-1][1]

    def _handle_drag_auto_scroll(self) -> None:
        if self._auto_scroll_direction == 0 or self._auto_scroll_speed == 0:
            self._stop_drag_auto_scroll()
            return

        scroll_bar = self._scroll.verticalScrollBar()
        viewport = self._scroll.viewport()
        viewport_height = viewport.height()
        current_value = scroll_bar.value()
        max_value = scroll_bar.maximum()

        if self._auto_scroll_direction < 0 and current_value <= 0:
            self._stop_drag_auto_scroll()
            return
        if self._auto_scroll_direction > 0 and current_value >= max_value:
            self._stop_drag_auto_scroll()
            return

        scroll_amount = (
            self._auto_scroll_speed * viewport_height / 100.0
        ) * (16.0 / 1000.0)
        new_value = current_value + (self._auto_scroll_direction * scroll_amount)
        new_value = max(0, min(new_value, max_value))
        scroll_bar.setValue(int(new_value))

        hover_pos = self._drag_hover_viewport_pos
        if hover_pos is not None:
            host_pos = self._list_host_pos_from_viewport_pos(hover_pos)
            self._show_drop_indicator(self._insert_index_at_list_y(int(host_pos.y())))

    def _stop_drag_auto_scroll(self) -> None:
        if self._auto_scroll_timer.isActive():
            self._auto_scroll_timer.stop()
        self._auto_scroll_direction = 0
        self._auto_scroll_speed = 0.0

    def _on_job_list_scrolled(self, _value: int) -> None:
        if self._drop_indicator_index is not None:
            self._show_drop_indicator(self._drop_indicator_index)

    def _sync_selection_ui(self, *, notify_geometry: bool = True) -> None:
        if self._is_single_visible_job():
            self._ensure_single_job_auto_selection()
        selected_id = self._controller.selected_job_id()
        sole = self._sole_visible_job_card()
        for card in self._job_cards:
            if sole is not None and card is sole:
                card.set_selected(True)
            else:
                card.set_selected(
                    selected_id is not None and card.job_id() == selected_id
                )
        self._sync_action_bar_from_selection()
        self._reflow_all()
        if notify_geometry:
            self._notify_sidebar_geometry_if_needed()

    def schedule_refresh(self) -> None:
        """Defer table rebuild (safe during controller signal handlers)."""
        self._schedule_refresh_table()

    def has_job_rows(self) -> bool:
        return bool(self._job_cards)

    def has_active_generation(self) -> bool:
        return self._controller.pane_shows_generation_progress()

    def _has_queue_list_content(self) -> bool:
        return bool(self._job_cards)

    def should_shrink_wrap_client(self) -> bool:
        """True when client area should hug content (empty queue, no active strip)."""
        if self._controller.pane_shows_generation_progress():
            return False
        if self._job_cards:
            return False
        return not bool(self._controller.queue_snapshot())

    def queue_job_count(self) -> int:
        return len(self._job_cards)

    def should_auto_resize_sidebar_pane(self) -> bool:
        """Whether splitter fit is allowed (selection, strip height, etc.)."""
        if self._queue_size_mode in (QUEUE_SIZE_ONE, QUEUE_SIZE_STRIP):
            return True
        if self._queue_size_mode == QUEUE_SIZE_ALL:
            return self.should_shrink_wrap_client() or self.queue_job_count() <= 1
        return False

    def should_auto_resize_sidebar_on_queue_change(self) -> bool:
        """Whether queue rebuild/update should trigger sidebar splitter fit."""
        if self._queue_size_mode == QUEUE_SIZE_ONE:
            return True
        if self._queue_size_mode == QUEUE_SIZE_ALL:
            if self._job_control_dialog:
                return not self.should_shrink_wrap_client()
            return self.should_shrink_wrap_client() or self.queue_job_count() <= 1
        return False

    def _pane_fit_bottom_slack_px(self) -> int:
        """Bottom padding when pin-sizing pane/dialog to row content."""
        if self._queue_size_mode == QUEUE_SIZE_STRIP:
            return 0
        if self.should_shrink_wrap_client():
            return 0
        return JOBS_PANE_FIT_BOTTOM_SLACK_PX

    def _scroll_fits_all_job_rows(self) -> bool:
        """True when every job row fits in the scroll viewport (with fit slack)."""
        if (
            self._queue_size_mode != QUEUE_SIZE_ALL
            or not self._job_cards
            or self.should_shrink_wrap_client()
        ):
            return False
        stack_h = self._job_cards_stack_height()
        if stack_h <= 0:
            return False
        slack = self._pane_fit_bottom_slack_px()
        strip_h = self._active_strip_block_height()
        toolbar_h = self._toolbar_block_height()
        budget = self.height() - strip_h - toolbar_h
        if budget <= 0:
            viewport = self._scroll.viewport()
            if viewport is not None and viewport.height() > 0:
                budget = viewport.height()
        return budget > 0 and stack_h <= budget - slack

    def auto_sidebar_pane_content_height(self, *, quick: bool = False) -> int:
        """Height for automatic sidebar fit — not full multijob preferred height."""
        mode = self._queue_size_mode
        if mode == QUEUE_SIZE_STRIP:
            return self.strip_only_content_height()
        if mode == QUEUE_SIZE_ONE:
            return self.single_job_content_height(quick=quick)
        if mode == QUEUE_SIZE_ALL and self.queue_job_count() <= 1:
            return self.single_job_content_height(quick=quick)
        return self.preferred_content_height(quick=quick)

    def _show_queue_scroll(self) -> bool:
        return self._has_queue_list_content()

    def is_queue_list_visible(self) -> bool:
        return self._scroll.isVisible()

    def empty_label_widget(self) -> QLabel:
        return self._empty_label

    def _apply_empty_queue_label_text(self, text: str) -> None:
        self._empty_label.setText(text)
        t = get_active_theme()
        _apply_empty_queue_label_style(
            self._empty_label, t.sidebar_text_color_hex
        )

    def _reset_empty_queue_label(self) -> None:
        self._apply_empty_queue_label_text(_EMPTY_QUEUE_LABEL_TEXT)

    def _show_compact_hold_message(self) -> bool:
        if not self.is_queue_compact():
            return False
        message = self._controller.queue_hold_compact_message()
        if not message:
            return False
        self._apply_empty_queue_label_text(message)
        self._empty_label.show()
        return True

    def _compact_hold_message_height(self) -> int:
        message = self._controller.queue_hold_compact_message()
        if not message:
            return 0
        self._apply_empty_queue_label_text(message)
        return empty_queue_label_height_px(self._empty_label)

    def empty_state_height_hint(self) -> int:
        return empty_queue_label_height_px(self._empty_label) + self._toolbar_block_height()

    def prepare_expand_layout(self) -> None:
        """Reflow cards and progress strip before sizing to fit content."""
        self._reflow_all()
        self._refresh_active_job_strip(force=True)

    def _jobs_header(self):
        if self._header_getter is None:
            return None
        return self._header_getter()

    def _setup_ui(self) -> None:
        self.setMinimumWidth(0)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        from imagegen_plugins.jobs_toolbar import JobPaneToolbar

        self._toolbar = JobPaneToolbar(self)
        self._toolbar.set_toolbar_visible(self._show_toolbar)

        self._empty_label = QLabel(_EMPTY_QUEUE_LABEL_TEXT)
        self._empty_label.setAlignment(
            Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignHCenter
        )
        t = get_active_theme()
        _apply_empty_queue_label_style(
            self._empty_label, t.sidebar_text_color_hex
        )

        self._active_job_strip = ActiveJobStripWidget(self.main_window, self)
        self._active_job_strip.set_on_content_height_changed(
            self._on_active_strip_content_height_changed
        )

        self._action_bar = JobQueueActionBar(
            self.main_window, self._controller, self
        )
        self._action_bar.hide()

        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setAlignment(
            Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft
        )
        self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self._scroll.setMinimumHeight(0)
        self._scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._scroll.setStyleSheet(get_active_theme().sidebar_jobs_scroll_stylesheet())
        apply_scroll_area_viewport_background(self._scroll, t.sidebar_background_color_hex)
        vp = self._scroll.viewport()
        if vp:
            vp.installEventFilter(self)

        self._list_host = QWidget()
        self._list_host.setAcceptDrops(True)
        self._list_host.installEventFilter(self)
        self._list_layout = QVBoxLayout(self._list_host)
        self._list_layout.setContentsMargins(4, 4, 4, 4)
        self._list_layout.setSpacing(8)
        self._list_layout.addStretch(1)

        self._drop_line = _JobQueueDropLine(self._scroll.viewport())

        self._scroll.setWidget(self._list_host)
        self._scroll.verticalScrollBar().valueChanged.connect(
            self._on_job_list_scrolled
        )
        self._scroll.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self._scroll.customContextMenuRequested.connect(
            lambda pos: self._show_jobs_pane_context_menu(
                self._scroll.viewport().mapToGlobal(pos)
            )
        )
        self._panel_layout = layout
        layout.addWidget(self._toolbar, 0)
        layout.addWidget(self._active_job_strip)
        layout.addWidget(self._empty_label)
        layout.addWidget(self._scroll, 0)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.customContextMenuRequested.connect(
            lambda pos: self._show_jobs_pane_context_menu(self.mapToGlobal(pos))
        )
        self._update_jobs_toolbar_state()
        _disable_tab_focus(self)

    def _connect_controller(self) -> None:
        if self._signal_connected:
            return
        self._controller.queue_changed.connect(self._on_queue_changed)
        self._controller.jobs_pane_title_changed.connect(self._update_header_status)
        self._controller.hold_job_queue_changed.connect(self._on_hold_job_queue_changed)
        self._controller.generation_started.connect(self._on_generation_started)
        self._controller.job_processing_started.connect(
            self._on_job_processing_started
        )
        self._controller.task_status_info_changed.connect(
            self._on_task_status_info_changed
        )
        self._controller.live_status_tick.connect(self._on_live_refresh_timer)
        self._update_header_status()
        if not self._startup_refresh_hook_registered:
            schedule = getattr(self.main_window, "schedule_post_startup", None)
            if callable(schedule):
                schedule(self._complete_startup_card_refresh)
                self._startup_refresh_hook_registered = True
        if self._jobs_ui_active():
            startup_pass = self._should_use_startup_pass()
            if startup_pass:
                self._startup_card_refresh_pending = True
            self.refresh_table(startup_pass=startup_pass)
        else:
            self._deferred_table_refresh = True
        self._signal_connected = True

    def _on_hold_job_queue_changed(self) -> None:
        self._update_header_status()
        self._defer_queue_empty_state_sync()

    def _on_task_status_info_changed(self) -> None:
        self._update_jobs_toolbar_state()
        self._refresh_active_row(force=True)
        self._refresh_action_bar_if_visible()
        if not self._controller.pane_shows_generation_progress():
            self._defer_queue_empty_state_sync()

    def _on_live_refresh_timer(self) -> None:
        if self._imagegen_dialog_building_active():
            return
        if not self._controller.task_status_display_needs_refresh():
            return
        prev_strip_h = 0
        if hasattr(self, "_active_job_strip") and self._active_job_strip.isVisible():
            prev_strip_h = self._active_job_strip.content_height()
        self._refresh_active_row(force=True)
        self._active_job_strip.refresh(force=True)
        if self._queue_size_mode in (QUEUE_SIZE_STRIP, QUEUE_SIZE_ONE):
            new_strip_h = (
                self._active_job_strip.content_height()
                if self._active_job_strip.isVisible()
                else 0
            )
            if abs(new_strip_h - prev_strip_h) > 1:
                self._on_active_strip_content_height_changed()
        self._controller.mark_task_status_display_refreshed()
        self._update_jobs_toolbar_state()

    def pause_live_refresh(self) -> None:
        """Pause periodic refresh while image-gen dialog builds on the GUI thread."""
        self._live_refresh_paused = True

    def resume_live_refresh(self) -> None:
        self._live_refresh_paused = False

    def _imagegen_dialog_building_active(self) -> bool:
        if getattr(self, "_live_refresh_paused", False):
            return True
        main_window = self.main_window
        return bool(getattr(main_window, "_imagegen_dialog_building", False))

    def _update_header_status(self) -> None:
        header = self._jobs_header()
        if header is None:
            return
        if hasattr(header, "set_title_suffix"):
            header.set_title_suffix(self._controller.jobs_pane_title_suffix())
        if hasattr(header, "set_status_text"):
            header.set_status_text(jobs_header_status_text(self._controller))
        self._update_jobs_toolbar_state()

    def refresh_header_status(self) -> None:
        self._update_header_status()

    def refresh_theme_styles(self) -> None:
        """Reapply theme colors to empty state and job cards."""
        from imagegen_plugins.job_queue_common import clear_job_queue_cell_style_cache

        clear_job_queue_cell_style_cache()
        t = get_active_theme()
        _apply_empty_queue_label_style(
            self._empty_label, t.sidebar_text_color_hex
        )
        if hasattr(self, "_scroll"):
            self._scroll.setStyleSheet(t.sidebar_jobs_scroll_stylesheet())
            apply_scroll_area_viewport_background(
                self._scroll, t.sidebar_background_color_hex
            )
        for card in self._job_cards:
            card._apply_card_style()
            card._status_widget.refresh_theme_styles()
        if self._can_refresh_queue_rows_in_place():
            self._refresh_queue_rows_theme_colors_only()
        if hasattr(self, "_action_bar"):
            self._action_bar.refresh_theme_styles()
        if hasattr(self, "_toolbar") and self._toolbar is not None:
            self._toolbar.refresh_theme_styles()
        self._active_job_strip.refresh_theme_styles()
        header = self._jobs_header()
        if header is not None:
            from theme.titlebar_icons import refresh_header_titlebar_icons

            refresh_header_titlebar_icons(header)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        old = event.oldSize()
        new = event.size()
        # Avoid strip reflow feedback when the parent only tweaks height in ALL mode.
        if (
            self._queue_size_mode == QUEUE_SIZE_ALL
            and old.width() == new.width()
            and old.height() != new.height()
        ):
            return
        if old.width() != new.width():
            if self._jobs_ui_active() and self._job_cards:
                self._schedule_reflow()
        if old.width() != new.width() or self._queue_size_mode != QUEUE_SIZE_ALL:
            self._refresh_active_job_strip(force=True)

    def sizeHint(self) -> QSize:
        if self._queue_size_mode == QUEUE_SIZE_ALL:
            w = self.width() if self.width() > 0 else -1
            h = self.height() if self.height() > 0 else MIN_JOBS_QUEUE_CONTENT_HEIGHT
            return QSize(w, h)
        return super().sizeHint()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        if self._deferred_table_refresh or not self._job_cards:
            self._flush_deferred_table_refresh()
        self._update_header_status()
        if not self._job_control_dialog:
            self._refresh_active_job_strip(force=True)
        if getattr(self.main_window, "_startup_refresh_complete", False):
            if self._startup_card_refresh_pending or any(
                card._content_deferred for card in self._job_cards
            ):
                self._complete_startup_card_refresh()

    def hideEvent(self, event) -> None:
        super().hideEvent(event)

    def mousePressEvent(self, event) -> None:
        if isinstance(event, QMouseEvent) and self._try_start_floating_client_drag(
            event, self
        ):
            return
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event) -> None:
        if isinstance(event, QMouseEvent) and self._try_handle_floating_client_double_click(
            event, self
        ):
            return
        super().mouseDoubleClickEvent(event)

    def eventFilter(self, obj, event) -> bool:
        if isinstance(event, QMouseEvent) and obj in self._floating_drag_filter_targets:
            if (
                event.type() == QEvent.Type.MouseButtonDblClick
                and self._try_handle_floating_client_double_click(event, obj)
            ):
                return True
            if (
                event.type() == QEvent.Type.MouseButtonPress
                and self._try_start_floating_client_drag(event, obj)
            ):
                return True
        if (
            hasattr(self, "_scroll")
            and obj is self._scroll.viewport()
            and event.type() == QEvent.Type.Resize
        ):
            self._schedule_reflow()
            if not self._sidebar_geometry_adjusting():
                self._refresh_active_job_strip(force=True)
            if self._drop_indicator_index is not None:
                self._show_drop_indicator(self._drop_indicator_index)
        if hasattr(self, "_scroll") and obj is self._scroll.viewport():
            if event.type() in (QEvent.Type.DragEnter, QEvent.Type.DragMove):
                mime = event.mimeData()  # type: ignore[union-attr]
                if mime.hasFormat(_JOB_QUEUE_DRAG_MIME):
                    mouse = event  # type: ignore[assignment]
                    vp_pos = mouse.position().toPoint()
                    self._drag_hover_viewport_pos = vp_pos
                    host_pos = self._list_host_pos_from_viewport_pos(vp_pos)
                    self._show_drop_indicator(
                        self._insert_index_at_list_y(int(host_pos.y()))
                    )
                    self._update_drag_auto_scroll_viewport_y(vp_pos.y())
                    event.acceptProposedAction()
                    return True
            if event.type() == QEvent.Type.DragLeave:
                self._stop_drag_auto_scroll()
            if event.type() == QEvent.Type.Drop:
                mime = event.mimeData()  # type: ignore[union-attr]
                if mime.hasFormat(_JOB_QUEUE_DRAG_MIME):
                    mouse = event  # type: ignore[assignment]
                    payload = bytes(mime.data(_JOB_QUEUE_DRAG_MIME)).decode("utf-8")
                    host_pos = self._list_host_pos_from_viewport_pos(
                        mouse.position().toPoint()
                    )
                    self._finish_job_reorder_drop(payload, int(host_pos.y()))
                    event.acceptProposedAction()
                    return True
        if hasattr(self, "_list_host") and obj is self._list_host:
            if event.type() == QEvent.Type.DragEnter:
                if event.mimeData().hasFormat(_JOB_QUEUE_DRAG_MIME):
                    mouse = event  # type: ignore[assignment]
                    host_pos = mouse.position().toPoint()
                    vp_pos = self._viewport_pos_from_list_host_pos(host_pos)
                    self._drag_hover_viewport_pos = vp_pos
                    self._show_drop_indicator(
                        self._insert_index_at_list_y(int(host_pos.y()))
                    )
                    self._update_drag_auto_scroll_viewport_y(vp_pos.y())
                    event.acceptProposedAction()
                    return True
            if event.type() == QEvent.Type.DragMove:
                if event.mimeData().hasFormat(_JOB_QUEUE_DRAG_MIME):
                    mouse = event  # type: ignore[assignment]
                    host_pos = mouse.position().toPoint()
                    vp_pos = self._viewport_pos_from_list_host_pos(host_pos)
                    self._drag_hover_viewport_pos = vp_pos
                    self._show_drop_indicator(
                        self._insert_index_at_list_y(int(host_pos.y()))
                    )
                    self._update_drag_auto_scroll_viewport_y(vp_pos.y())
                    event.acceptProposedAction()
                    return True
            if event.type() == QEvent.Type.DragLeave:
                self._stop_drag_auto_scroll()
            if event.type() == QEvent.Type.Drop:
                if event.mimeData().hasFormat(_JOB_QUEUE_DRAG_MIME):
                    mouse = event  # type: ignore[assignment]
                    payload = bytes(
                        event.mimeData().data(_JOB_QUEUE_DRAG_MIME)
                    ).decode("utf-8")
                    self._finish_job_reorder_drop(payload, int(mouse.position().y()))
                    event.acceptProposedAction()
                    return True
        return super().eventFilter(obj, event)

    def _schedule_reflow(self) -> None:
        if not self._jobs_ui_active():
            return
        timer = self._resize_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self._reflow_all_and_notify_geometry)
            self._resize_timer = timer
        timer.start(tc.JOBS_PANE_HORIZ_RESIZE_DEBOUNCE_MS)

    def _reflow_all_and_notify_geometry(self) -> None:
        self._reflow_all()
        self._notify_sidebar_geometry_if_needed()

    def _schedule_refresh_table(self) -> None:
        timer = self._refresh_table_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self.refresh_table)
            self._refresh_table_timer = timer
        timer.start(0)

    def _cards_align_with_snapshot(self) -> bool:
        rows = self._controller.queue_snapshot()
        if len(rows) != len(self._job_cards):
            return False
        for card, row in zip(self._job_cards, rows):
            if card.job_id() != row.job_id:
                return False
        return True

    def _take_pooled_card(self) -> JobCard | None:
        while self._card_pool:
            card = self._card_pool.pop()
            card.show()
            return card
        return None

    def _park_job_card(self, card: JobCard) -> None:
        if card.has_action_bar():
            card.detach_action_bar()
        card.set_selected(False)
        card._content_deferred = False
        card._deferred_thumbnail_paths = None
        card._deferred_references_invalid = False
        self._list_layout.removeWidget(card)
        card.hide()
        card.setParent(self._list_host)
        if card not in self._card_pool:
            self._card_pool.append(card)

    def _create_job_card(self, row_idx: int, row) -> JobCard:
        return JobCard(
            self.main_window,
            self._controller,
            row_idx,
            job_id=row.job_id,
            is_active=row.is_active,
            on_select=self._on_job_selected,
            on_select_force=self._on_job_force_selected,
            on_reorder_drop=self._on_job_reorder_drop,
            on_drop_hover=self._show_drop_indicator,
            on_drop_hover_clear=self._clear_drop_indicator,
            on_drag_auto_scroll=self._update_drag_auto_scroll_at_global,
        )

    def _card_row_content_unchanged(
        self,
        card: JobCard,
        row,
        status_view,
        info_w: int,
        viewport_w: int,
    ) -> bool:
        if status_view is None or not card._status_widget.has_rendered_view():
            return False
        fp = status_view.fingerprint()
        text_w = card._status_content_width(info_w, viewport_w)
        if (
            fp != card._last_view_fingerprint
            or card._last_content_width != info_w
            or card._scroll_width != viewport_w
            or text_w != card._status_widget.width()
        ):
            return False
        valid = [] if row.references_invalid else _valid_preview_paths(row.thumbnail_paths)
        inline = card._use_inline_refs_layout(viewport_w)
        return (
            getattr(card._refs, "_paths", None) == valid
            and getattr(card._refs, "_references_invalid", False)
            == row.references_invalid
            and inline == card._content_inline
        )

    def _apply_row_to_job_card(
        self,
        card: JobCard,
        row_idx: int,
        row,
        info_w: int,
        viewport_w: int,
        *,
        skip_unchanged: bool = False,
        defer_thumbnails: bool = False,
    ) -> None:
        card._content_deferred = False
        card.set_row_index(row_idx)
        card.set_active_row(row.is_active)
        status_view = status_view_for_queue_row(
            self._controller, row_idx, row, for_sidebar=True
        )
        card._full_prompt = row.full_prompt or ""
        update_delayed_prompt_tooltip(
            card._status_widget,
            card._full_prompt,
            displayed_prompt=card._status_widget.displayed_prompt_text(),
        )
        if skip_unchanged and not row.is_active:
            if self._card_row_content_unchanged(
                card, row, status_view, info_w, viewport_w
            ):
                return
        card.update_status_view(status_view, info_w, scroll_width=viewport_w)
        if row.thumbnail_paths:
            card._replace_refs(
                row.thumbnail_paths,
                info_w,
                scroll_width=viewport_w,
                references_invalid=row.references_invalid,
                defer_thumbnails=defer_thumbnails,
            )
        else:
            card.reflow_refs(viewport_w)

    def _reorder_cards_in_layout(self, cards: list[JobCard]) -> None:
        for card in cards:
            self._list_layout.removeWidget(card)
        for row_idx, card in enumerate(cards):
            self._list_layout.insertWidget(row_idx, card)
            card.show()

    def _sum_job_cards_layout_height(self) -> int:
        margins = self._list_layout.contentsMargins()
        spacing = self._list_layout.spacing()
        total = margins.top() + margins.bottom()
        for row_idx, card in enumerate(self._job_cards):
            if row_idx > 0:
                total += spacing
            total += self._card_layout_height(card)
        return total

    def _sync_queue_row_chrome_from_snapshot(self) -> None:
        """Apply running/idle chrome immediately (before worker fork blocks the loop)."""
        if not self._job_cards or not self._cards_align_with_snapshot():
            return
        for card, row in zip(self._job_cards, self._controller.queue_snapshot()):
            card.set_active_row(row.is_active)

    def _can_refresh_queue_rows_in_place(self) -> bool:
        return bool(self._job_cards) and self._cards_align_with_snapshot()

    def _refresh_queue_rows_in_place(self, *, skip_unchanged: bool = False) -> None:
        """Update row status and action bar without tearing down job cards."""
        rows = self._controller.queue_snapshot()
        info_w = self._info_content_width()
        viewport_w = self._viewport_width()
        for row_idx, card in enumerate(self._job_cards):
            if row_idx >= len(rows):
                break
            row = rows[row_idx]
            self._apply_row_to_job_card(
                card,
                row_idx,
                row,
                info_w,
                viewport_w,
                skip_unchanged=skip_unchanged,
            )
        self._controller.resolve_selected_row_index()
        self._sync_selection_ui(notify_geometry=False)
        self._update_header_status()
        self._refresh_active_job_strip(force=True)
        if self._queue_size_mode in _QUEUE_SIZE_MODES:
            self._apply_queue_size_layout()
        self._notify_sidebar_geometry_if_needed(on_queue_change=True)

    def _refresh_queue_rows_theme_colors_only(self) -> None:
        """Reformat row status views for theme colors without exit scripts or geometry."""
        if not self._can_refresh_queue_rows_in_place():
            return
        from imagegen_plugins.model_task_queue import refresh_queued_job_status

        rows = self._controller.queue_snapshot()
        info_w = self._info_content_width()
        viewport_w = self._viewport_width()
        for row_idx, card in enumerate(self._job_cards):
            if row_idx >= len(rows):
                break
            row = rows[row_idx]
            if row.is_active:
                status_view = self._controller.get_task_queue_status_view(
                    omit_live_steps_row=True
                )
            else:
                job = self._controller._queued_job_by_id(row.job_id)
                if job is not None:
                    refresh_queued_job_status(
                        job, skip_image_exit=job.status_view is not None
                    )
                    status_view = job.status_view
                else:
                    status_view = row.status_view
            card.update_status_view(status_view, info_w, scroll_width=viewport_w)

    def _on_queue_changed(self) -> None:
        self._update_header_status()
        if not self._jobs_ui_active():
            self._deferred_table_refresh = True
            return
        if self._can_refresh_queue_rows_in_place():
            self._sync_queue_row_chrome_from_snapshot()
            self._refresh_queue_rows_in_place(skip_unchanged=True)
            self._refresh_action_bar_if_visible()
            self._refresh_active_job_strip(force=True)
            if self._queue_size_mode in _QUEUE_SIZE_MODES:
                self._apply_queue_size_layout()
        else:
            self._sync_job_cards_to_snapshot()
        self._defer_queue_empty_state_sync()

    def _viewport_width(self) -> int:
        w = self._scroll.viewport().width() if hasattr(self, "_scroll") else self.width()
        return max(80, w - 8)

    def _info_content_width(self) -> int:
        return max(80, self._viewport_width() - _CARD_CONTENT_MARGIN)

    def _clear_expanded_layout_pin(self) -> None:
        """Drop empty-queue shrink-wrap height once jobs or generation need space."""
        if self._queue_size_mode != QUEUE_SIZE_ALL or self.should_shrink_wrap_client():
            return
        self.setMinimumHeight(0)
        self.setMaximumHeight(16777215)
        self.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
        )
        self.updateGeometry()

    def _deferred_generation_geometry_sync(self) -> None:
        """Re-measure after Qt applies strip/content layout from generation start."""
        self._refresh_active_job_strip(force=True)
        self._apply_queue_size_layout()
        if self._queue_size_mode == QUEUE_SIZE_ALL:
            self._clear_expanded_layout_pin()
        self._notify_sidebar_geometry_if_needed()

    def _on_generation_started(self) -> None:
        """Resize compact / single-job views when the progress strip appears."""
        self._sync_queue_row_chrome_from_snapshot()
        self._refresh_active_job_strip(force=True)
        self._apply_queue_size_layout()
        self._update_jobs_toolbar_state()
        self._notify_sidebar_geometry_if_needed()
        QTimer.singleShot(0, self._deferred_generation_geometry_sync)

    def _on_job_processing_started(self, _kind: str) -> None:
        self._sync_queue_row_chrome_from_snapshot()
        self._refresh_active_job_strip(force=True)
        self._refresh_active_row(force=True)

    def _refresh_active_job_strip(self, *, force: bool = False) -> None:
        if not hasattr(self, "_active_job_strip"):
            return
        adjusting = self._sidebar_geometry_adjusting()
        if not self.isVisible() or not self._controller.pane_shows_generation_progress():
            if self._active_job_strip.isVisible():
                self._active_job_strip.hide()
            if not adjusting:
                self._apply_queue_size_layout()
                self._notify_sidebar_geometry_if_needed()
            return
        prev_strip_h = self._active_job_strip.content_height()
        self._active_job_strip.refresh(force=force)
        if adjusting:
            return
        if self._queue_size_mode in (QUEUE_SIZE_STRIP, QUEUE_SIZE_ONE):
            self._sync_fixed_panel_geometry()
            if abs(self._active_job_strip.content_height() - prev_strip_h) > 1:
                self._notify_sidebar_geometry_if_needed()

    def _on_active_strip_content_height_changed(self) -> None:
        if self._sidebar_geometry_adjusting():
            return
        if self._queue_size_mode == QUEUE_SIZE_ONE:
            self._apply_one_job_scroll_height()
        self._sync_fixed_panel_geometry()
        self._notify_sidebar_geometry_if_needed()

    def queue_size_mode(self) -> str:
        return self._queue_size_mode

    def set_queue_size_mode(self, mode: str, *, force_refit: bool = False) -> None:
        """all: every job row; one: active strip + first row; strip: progress strip only."""
        if mode not in _QUEUE_SIZE_MODES:
            mode = QUEUE_SIZE_ALL
        if mode == self._queue_size_mode and not force_refit:
            if mode != QUEUE_SIZE_ALL or self.should_shrink_wrap_client():
                self._sync_fixed_panel_geometry()
            return
        if mode != self._queue_size_mode:
            self._queue_size_mode = mode
        self._apply_queue_size_layout()

    def is_queue_compact(self) -> bool:
        return self._queue_size_mode == QUEUE_SIZE_STRIP

    def prepare_size_measure(self, *, quick: bool = False) -> None:
        """Flush layout so fit-to-content height measurements are stable."""
        if self._preparing_size_measure:
            return
        self._preparing_size_measure = True
        try:
            if quick:
                app = QApplication.instance()
                if app is not None:
                    app.processEvents(
                        QEventLoop.ProcessEventsFlag.ExcludeUserInputEvents
                    )
                return
            self._refresh_active_job_strip(force=True)
            self._reflow_all()
            app = QApplication.instance()
            if app is not None:
                app.processEvents(QEventLoop.ProcessEventsFlag.ExcludeUserInputEvents)
        finally:
            self._preparing_size_measure = False

    def refresh_compact_geometry(self, strip_h: int | None = None) -> None:
        """Re-pin widget height to the strip (strip mode / sidebar compact)."""
        if not self.is_queue_compact():
            return
        if strip_h is not None:
            self.setSizePolicy(
                QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
            )
            self.setFixedHeight(strip_h)
            self.updateGeometry()
            return
        self._sync_fixed_panel_geometry()

    def _sync_fixed_panel_geometry(self) -> None:
        if self._queue_size_mode == QUEUE_SIZE_ALL and not self.should_shrink_wrap_client():
            return
        content_h = self.content_height_for_size_mode()
        # Compare applied constraints, not height(): live geometry lags
        # setFixedHeight() until the parent layout runs.
        if (
            self.minimumHeight() == content_h
            and self.maximumHeight() == content_h
        ):
            return
        self.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )
        if content_h < self.height():
            self.setMinimumHeight(0)
            self.setMaximumHeight(16777215)
        self.setFixedHeight(content_h)
        self.setMaximumHeight(content_h)
        self.updateGeometry()

    def _apply_panel_layout_stretch(self) -> None:
        layout = getattr(self, "_panel_layout", None)
        if layout is None:
            return
        shrink = self.should_shrink_wrap_client()
        dialog_all_fit = self._dialog_fits_all_jobs_to_content()
        if self._queue_size_mode == QUEUE_SIZE_ALL and not shrink:
            if dialog_all_fit:
                layout.setStretchFactor(self._scroll, 0)
                self._scroll.setSizePolicy(
                    QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
                )
                self._scroll.setMinimumHeight(0)
                self._scroll.setMaximumHeight(16777215)
            else:
                layout.setStretchFactor(self._scroll, 1)
                self._scroll.setSizePolicy(
                    QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
                )
                self._scroll.setMinimumHeight(0)
                self._scroll.setMaximumHeight(16777215)
        else:
            layout.setStretchFactor(self._scroll, 0)
            self._scroll.setSizePolicy(
                QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
            )
            if shrink or self._queue_size_mode != QUEUE_SIZE_ALL:
                self._scroll.setFixedHeight(0)
                self._scroll.setMaximumHeight(0)

    def _apply_one_job_scroll_height(self) -> None:
        if not self._job_cards:
            self._scroll.setFixedHeight(0)
            return
        margins = self._list_layout.contentsMargins()
        card_h = self._measure_first_job_card_height()
        if card_h <= 0:
            card_h = self._job_cards[0].minimumHeight()
        self._scroll.setFixedHeight(
            card_h + margins.top() + margins.bottom()
        )

    def _dialog_fits_all_jobs_to_content(self) -> bool:
        """Floating dialog ALL mode: pin scroll to every job row (no inner scroll)."""
        return (
            self._job_control_dialog
            and self._queue_size_mode == QUEUE_SIZE_ALL
            and not self.should_shrink_wrap_client()
            and len(self._job_cards) > 1
        )

    def _job_cards_stack_height(self) -> int:
        if not self._job_cards:
            return 0
        width = self._viewport_width()
        info_w = self._info_content_width()
        for card in self._job_cards:
            card.reflow_layout(info_w, width)
        return self._sum_job_cards_layout_height()

    def refit_dialog_scroll_geometry(self, client_height: int | None = None) -> None:
        """Size the job-list scroll area to fill the floating dialog panel."""
        if not self._dialog_fits_all_jobs_to_content():
            return
        if not self._job_cards:
            self._scroll.setFixedHeight(0)
            return
        stack_h = self._job_cards_stack_height()
        strip_h = self._active_strip_block_height()
        toolbar_h = self._toolbar_block_height()
        panel_h = (
            client_height
            if client_height is not None and client_height > 0
            else self.height()
        )
        available = panel_h - strip_h - toolbar_h
        if available <= 0:
            available = stack_h
        slack = self._pane_fit_bottom_slack_px()
        # Always fill the panel client area so the scroll grows when the outer
        # window resizes; use an inner scrollbar only when cards exceed space.
        if stack_h > available - slack:
            scroll_h = available
            bar_policy = Qt.ScrollBarPolicy.ScrollBarAsNeeded
        else:
            scroll_h = available
            bar_policy = Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        self._scroll.setFixedHeight(scroll_h)
        self._scroll.setVerticalScrollBarPolicy(bar_policy)

    def refit_dialog_compact_geometry(self) -> None:
        """Re-apply compact (strip-only) layout for the floating dialog panel."""
        if not self.is_queue_compact():
            return
        self._refresh_active_job_strip(force=True)
        self._sync_fixed_panel_geometry()

    def refit_dialog_client_geometry(self, client_height: int | None = None) -> None:
        if self._dialog_fits_all_jobs_to_content():
            self.refit_dialog_scroll_geometry(client_height)
        elif self.is_queue_compact():
            self.refit_dialog_compact_geometry()

    def _apply_queue_size_layout(self) -> None:
        has_rows = bool(self._job_cards)
        show_empty = self.should_shrink_wrap_client()
        show_scroll = self._show_queue_scroll()
        mode = self._queue_size_mode
        self._apply_panel_layout_stretch()
        self._sync_action_bar_from_selection()

        if mode == QUEUE_SIZE_STRIP:
            self._scroll.hide()
            for card in self._job_cards:
                card.hide()
            if self._controller.pane_shows_generation_progress():
                self._active_job_strip.refresh(force=True)
            elif self._active_job_strip.isVisible():
                self._active_job_strip.hide()
            if self._show_compact_hold_message():
                pass
            elif self._controller.pane_shows_generation_progress() or self._job_cards:
                self._empty_label.hide()
            else:
                self._reset_empty_queue_label()
                self._empty_label.setVisible(show_empty)
            self._sync_fixed_panel_geometry()
        elif mode == QUEUE_SIZE_ONE:
            self._reset_empty_queue_label()
            self._empty_label.setVisible(show_empty)
            self._scroll.setVisible(show_scroll)
            self._scroll.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAlwaysOff
            )
            for idx, card in enumerate(self._job_cards):
                card.setVisible(idx == 0)
            if has_rows:
                self._apply_one_job_scroll_height()
            else:
                self._scroll.setFixedHeight(0)
            self._sync_fixed_panel_geometry()
        else:
            self._clear_expanded_layout_pin()
            self.setMinimumHeight(0)
            self.setMaximumHeight(16777215)
            self.setSizePolicy(
                QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
            )
            self._scroll.setMinimumHeight(0)
            self._scroll.setMaximumHeight(16777215)
            if self._scroll_fits_all_job_rows():
                scroll_policy = Qt.ScrollBarPolicy.ScrollBarAlwaysOff
            else:
                scroll_policy = Qt.ScrollBarPolicy.ScrollBarAsNeeded
            self._scroll.setVerticalScrollBarPolicy(scroll_policy)
            for card in self._job_cards:
                card.show()
            self._reset_empty_queue_label()
            self._empty_label.setVisible(show_empty)
            self._scroll.setVisible(show_scroll)
            if self._dialog_fits_all_jobs_to_content():
                self.refit_dialog_scroll_geometry()
            elif self.should_shrink_wrap_client():
                self._sync_fixed_panel_geometry()
        self.updateGeometry()

    def _active_strip_block_height(self) -> int:
        if not self._controller.pane_shows_generation_progress():
            return 0
        strip_h = self._active_job_strip.content_height()
        if strip_h > 0:
            return strip_h
        return self._active_job_strip.height()

    def strip_only_content_height(self) -> int:
        """Client height for strip-only view: progress strip + optional toolbar."""
        toolbar_h = self._toolbar_block_height()
        if self._controller.pane_shows_generation_progress():
            strip_h = self._active_job_strip.content_height()
            if strip_h <= 0 and not self._preparing_size_measure:
                self._active_job_strip.refresh(force=True)
                strip_h = self._active_job_strip.content_height()
            if strip_h > 0:
                return strip_h + toolbar_h
        hold_h = self._compact_hold_message_height()
        if hold_h > 0:
            return hold_h + toolbar_h
        if not self._job_cards:
            return self.empty_state_height_hint()
        # Queued jobs but no live progress: toolbar only (no job rows, no filler).
        if toolbar_h > 0:
            return toolbar_h
        return self.empty_state_height_hint()

    def _measure_first_job_card_height(self) -> int:
        if not self._job_cards:
            return 0
        info_w = self._info_content_width()
        width = self._viewport_width()
        card = self._job_cards[0]
        rows = self._controller.queue_snapshot()
        row = rows[0] if rows else None
        if card._last_status_view is not None:
            card.update_status_view(card._last_status_view, info_w, scroll_width=width)
        elif row is not None:
            card.update_status_view(
                status_view_for_queue_row(
                    self._controller, 0, row, for_sidebar=True
                ),
                info_w,
                scroll_width=width,
            )
            if row.thumbnail_paths:
                card._replace_refs(row.thumbnail_paths, info_w, scroll_width=width)
        else:
            card.reflow_refs(width)
            return card.minimumHeight()
        card.reflow_refs(width)
        return card.minimumHeight()

    def single_job_content_height(self, *, quick: bool = False) -> int:
        """Client height for one job row (+ active strip when running)."""
        total = self._active_strip_block_height()
        if not self._job_cards:
            if self._controller.pane_shows_generation_progress():
                return total + self._toolbar_block_height()
            return self.empty_state_height_hint()
        margins = self._list_layout.contentsMargins()
        if quick:
            card_h = self._card_layout_height(self._job_cards[0])
        else:
            card_h = self._measure_first_job_card_height()
        if card_h <= 0:
            card_h = self._job_cards[0].minimumHeight()
        return (
            total
            + margins.top()
            + margins.bottom()
            + card_h
            + self._toolbar_block_height()
            + self._pane_fit_bottom_slack_px()
        )

    def content_height_for_size_mode(
        self, mode: str | None = None, *, quick: bool = False
    ) -> int:
        mode = mode or self._queue_size_mode
        if mode == QUEUE_SIZE_STRIP:
            return self.strip_only_content_height()
        if mode == QUEUE_SIZE_ONE:
            return self.single_job_content_height(quick=quick)
        return self.preferred_content_height(quick=quick)

    def minimumSizeHint(self) -> QSize:
        if self._queue_size_mode != QUEUE_SIZE_ALL:
            return QSize(0, self.content_height_for_size_mode())
        if self.should_shrink_wrap_client():
            return QSize(0, self.empty_state_height_hint())
        return QSize(0, MIN_JOBS_QUEUE_CONTENT_HEIGHT)

    def _active_job_card(self) -> JobCard | None:
        for card in self._job_cards:
            if card.is_active_row():
                return card
        return None

    def _refresh_active_row(self, *, force: bool = False) -> None:
        if not force and self._imagegen_dialog_building_active():
            return
        if not self.isVisible() or not self._job_cards:
            return
        if not force and not self._controller.task_status_display_needs_refresh():
            return
        rows = self._controller.queue_snapshot()
        active_row_idx = -1
        active_row = None
        for idx, snapshot_row in enumerate(rows):
            if snapshot_row.is_active:
                active_row_idx = idx
                active_row = snapshot_row
                break
        if active_row is None:
            return
        active_card = None
        for card in self._job_cards:
            if card.job_id() == active_row.job_id:
                active_card = card
                break
        if active_card is None:
            self._schedule_refresh_table()
            return
        for card in self._job_cards:
            want_active = card.job_id() == active_row.job_id
            if card.is_active_row() != want_active:
                card.set_active_row(want_active)
        active_card.set_row_index(active_row_idx)
        info_w = self._info_content_width()
        viewport_w = self._viewport_width()
        self._apply_row_to_job_card(
            active_card,
            active_row_idx,
            active_row,
            info_w,
            viewport_w,
        )
        _disable_tab_focus(active_card)
        if self._is_single_visible_job():
            self._refresh_action_bar_if_visible()
        if self._queue_size_mode == QUEUE_SIZE_ONE:
            self._apply_one_job_scroll_height()
            self._sync_fixed_panel_geometry()
            self._notify_sidebar_geometry_if_needed()

    def _clear_job_cards(self) -> None:
        self._detach_action_bar()
        for card in self._job_cards:
            self._park_job_card(card)
        self._job_cards.clear()

    def _reflow_all(self) -> None:
        width = self._viewport_width()
        info_w = self._info_content_width()
        for card in self._job_cards:
            card.reflow_layout(info_w, width)
        if self._queue_size_mode == QUEUE_SIZE_ONE:
            self._apply_one_job_scroll_height()
            self._sync_fixed_panel_geometry()
        elif self._queue_size_mode == QUEUE_SIZE_STRIP:
            self._sync_fixed_panel_geometry()

    def _notify_shell_geometry_changed(self) -> None:
        if self._preparing_size_measure:
            return
        cb = self._on_compact_geometry_changed
        if cb is not None:
            cb()

    def _sidebar_geometry_adjusting(self) -> bool:
        sidebar = getattr(self.main_window, "right_sidebar", None)
        if sidebar is None:
            return False
        checker = getattr(sidebar, "jobs_pane_geometry_adjusting", None)
        if callable(checker):
            return bool(checker())
        return bool(getattr(sidebar, "_adjusting_jobs_geometry", False))

    def _notify_sidebar_geometry_if_needed(self, *, on_queue_change: bool = False) -> None:
        if self._sidebar_geometry_adjusting():
            return
        allowed = (
            self.should_auto_resize_sidebar_on_queue_change()
            if on_queue_change
            else self.should_auto_resize_sidebar_pane()
        )
        if allowed:
            self._notify_shell_geometry_changed()
            return
        if (
            on_queue_change
            and not self._job_control_dialog
            and self._queue_size_mode == QUEUE_SIZE_ALL
            and self.queue_job_count() > 1
            and not self.should_shrink_wrap_client()
        ):
            self._notify_shell_geometry_changed()

    def compact_content_height(self) -> int:
        """Client height for minimized view: active progress strip only."""
        return self.strip_only_content_height()

    def preferred_content_height(self, *, quick: bool = False) -> int:
        """Height needed to show all job rows without vertical scrolling."""
        total = 0
        if (
            hasattr(self, "_active_job_strip")
            and self._active_job_strip.isVisible()
        ):
            strip_h = self._active_job_strip.content_height()
            if strip_h <= 0:
                strip_h = self._active_job_strip.height()
            total += strip_h if strip_h > 0 else self._active_job_strip.sizeHint().height()
        if not self._job_cards:
            if self._controller.pane_shows_generation_progress():
                return total + self._toolbar_block_height()
            return self.empty_state_height_hint()
        self._ensure_single_job_auto_selection()
        margins = self._list_layout.contentsMargins()
        total += margins.top() + margins.bottom()
        spacing = self._list_layout.spacing()
        if quick:
            for row_idx, card in enumerate(self._job_cards):
                if row_idx > 0:
                    total += spacing
                total += self._card_layout_height(card)
            return total + self._toolbar_block_height() + self._pane_fit_bottom_slack_px()
        width = self._viewport_width()
        info_w = self._info_content_width()
        for card in self._job_cards:
            card.reflow_layout(info_w, width)
        for row_idx, card in enumerate(self._job_cards):
            if row_idx > 0:
                total += spacing
            total += self._card_layout_height(card)
        return total + self._toolbar_block_height() + self._pane_fit_bottom_slack_px()

    def _sync_job_cards_to_snapshot(self, *, startup_pass: bool = False) -> None:
        rows = self._controller.queue_snapshot()
        self._clear_drop_indicator()

        if not rows:
            self._clear_job_cards()
            self._controller.resolve_selected_row_index()
            self._sync_selection_ui(notify_geometry=False)
            self._update_header_status()
            self._refresh_active_job_strip(force=True)
            self._apply_queue_size_layout()
            self._notify_sidebar_geometry_if_needed(on_queue_change=True)
            return

        info_w = self._info_content_width()
        viewport_w = self._viewport_width()
        priority_rows = (
            self._startup_priority_row_indices(rows) if startup_pass else None
        )

        if self._cards_align_with_snapshot():
            for row_idx, (card, row) in enumerate(zip(self._job_cards, rows)):
                if startup_pass and priority_rows is not None:
                    if row_idx in priority_rows:
                        self._apply_row_to_job_card(
                            card,
                            row_idx,
                            row,
                            info_w,
                            viewport_w,
                            skip_unchanged=True,
                            defer_thumbnails=True,
                        )
                    else:
                        self._apply_deferred_row_shell_to_job_card(
                            card, row_idx, row, info_w, viewport_w
                        )
                else:
                    self._apply_row_to_job_card(
                        card,
                        row_idx,
                        row,
                        info_w,
                        viewport_w,
                        skip_unchanged=True,
                    )
        else:
            cards_by_id = {card.job_id(): card for card in self._job_cards}
            new_cards: list[JobCard] = []
            keep_ids: set[str] = set()

            for row_idx, row in enumerate(rows):
                keep_ids.add(row.job_id)
                card = cards_by_id.get(row.job_id)
                if card is None:
                    card = self._take_pooled_card()
                    if card is None:
                        card = self._create_job_card(row_idx, row)
                    else:
                        card.rebind_for_row(
                            row_idx, row.job_id, is_active=row.is_active
                        )
                else:
                    card.rebind_for_row(
                        row_idx, row.job_id, is_active=row.is_active
                    )
                if startup_pass and priority_rows is not None:
                    if row_idx in priority_rows:
                        self._apply_row_to_job_card(
                            card,
                            row_idx,
                            row,
                            info_w,
                            viewport_w,
                            defer_thumbnails=True,
                        )
                    else:
                        self._apply_deferred_row_shell_to_job_card(
                            card, row_idx, row, info_w, viewport_w
                        )
                else:
                    self._apply_row_to_job_card(
                        card, row_idx, row, info_w, viewport_w
                    )
                new_cards.append(card)

            for card in self._job_cards:
                if card.job_id() not in keep_ids:
                    self._park_job_card(card)

            self._job_cards = new_cards
            self._reorder_cards_in_layout(new_cards)
            for card in new_cards:
                _disable_tab_focus(card)

        self._controller.resolve_selected_row_index()
        _disable_tab_focus(self)
        self._sync_selection_ui(notify_geometry=False)
        self._update_header_status()
        self._refresh_active_job_strip(force=True)
        self._apply_queue_size_layout()
        self._notify_sidebar_geometry_if_needed(on_queue_change=True)
        if self._queue_size_mode == QUEUE_SIZE_ONE and self._job_cards:
            QTimer.singleShot(0, self._deferred_generation_geometry_sync)

    def refresh_table(self, *, startup_pass: bool = False) -> None:
        self._sync_job_cards_to_snapshot(startup_pass=startup_pass)
