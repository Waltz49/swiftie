#!/usr/bin/env python3
"""Native Qt widgets for the active-job progress strip."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from imagegen_plugins.job_queue_skip_cooldown_button import CooldownSkipLabel
from imagegen_plugins.job_status_views import (
    ActiveJobStripView,
    StripBarRow,
    StripCountRow,
)
from imagegen_plugins.model_task_status_info import (
    _INFO_PANEL_BAR_H,
    _INFO_PANEL_BAR_MIN_W,
    _INFO_PANEL_LABEL_W,
    _INFO_PANEL_POSTFIX_W,
    _INFO_PANEL_PREFIX_W,
    _INFO_PANEL_PROGRESS_BAR_FILL_HEX,
    _information_panel_row_content_width,
)
from theme.theme_service import get_active_theme

_FONT_PX = 12
_STRIP_EMPTY_CELL = "\u00a0"


def _strip_cell_text(text: str) -> str:
    """Non-breaking space placeholder for empty prefix/postfix cells (HTML &nbsp;)."""
    return text if (text or "").strip() else _STRIP_EMPTY_CELL


class StripProgressBar(QWidget):
    def __init__(
        self,
        fill_percent: int,
        *,
        slot_text: str = "",
        show_pending_start: bool = False,
        parent=None,
    ):
        super().__init__(parent)
        self._fill_percent = max(0, min(100, int(fill_percent)))
        self._slot_text = slot_text or ""
        self._show_pending_start = bool(show_pending_start)
        self.setFixedHeight(_INFO_PANEL_BAR_H)
        self.setMinimumWidth(_INFO_PANEL_BAR_MIN_W)
        self.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )

    def paintEvent(self, event) -> None:
        th = get_active_theme()
        border = QColor(th.progress_bar_border_hex)
        bg = QColor(th.progress_bar_bg_hex)
        fill = QColor(_INFO_PANEL_PROGRESS_BAR_FILL_HEX)
        text_color = QColor(th.progress_bar_text_hex)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, False)
        rect = self.rect()
        bar_w = rect.width()
        bar_h = rect.height()
        if self._slot_text:
            painter.setPen(text_color)
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, self._slot_text)
            return
        painter.fillRect(rect, bg)
        if self._show_pending_start and self._fill_percent <= 0:
            painter.setPen(QColor(Qt.GlobalColor.white))
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, "\u2192")
        else:
            filled_w = max(
                0,
                min(bar_w, int(round(bar_w * self._fill_percent / 100.0))),
            )
            if filled_w > 0:
                painter.fillRect(0, 0, filled_w, bar_h, fill)
        painter.setPen(QPen(border))
        painter.drawRect(0, 0, bar_w - 1, bar_h - 1)

    def set_values(
        self,
        *,
        fill_percent: int,
        slot_text: str = "",
        show_pending_start: bool = False,
    ) -> None:
        self._fill_percent = max(0, min(100, int(fill_percent)))
        self._slot_text = slot_text or ""
        self._show_pending_start = bool(show_pending_start)
        self.update()


class _StripIconButton(QPushButton):
    def __init__(
        self,
        asset: str,
        hover_asset: str,
        tooltip: str,
        *,
        on_hovered: Callable[[bool], None] | None = None,
        parent=None,
    ):
        super().__init__(parent)
        self._asset = asset
        self._hover_asset = hover_asset
        self._hovered = False
        self._on_hovered = on_hovered
        self.setFixedSize(16, 16)
        self.setToolTip(tooltip)
        self.setStyleSheet("border: none; padding: 0; margin: 0;")
        self._apply_icon()

    def enterEvent(self, event) -> None:
        self.set_hovered(True)
        if self._on_hovered is not None:
            self._on_hovered(True)
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self.set_hovered(False)
        if self._on_hovered is not None:
            self._on_hovered(False)
        super().leaveEvent(event)

    def _apply_icon(self) -> None:
        from theme.theme_base import asset_file_url

        asset = self._hover_asset if self._hovered else self._asset
        px = QPixmap(asset_file_url(asset))
        if not px.isNull():
            self.setIcon(QIcon(px))
            self.setIconSize(px.size())

    def set_hovered(self, hovered: bool) -> None:
        hovered = bool(hovered)
        if hovered == self._hovered:
            return
        self._hovered = hovered
        self._apply_icon()


class ActiveJobStripContentWidget(QWidget):
    def __init__(
        self,
        main_window,
        *,
        on_icon_hover: Callable[[str, bool], None] | None = None,
        parent=None,
    ):
        super().__init__(parent)
        self._main_window = main_window
        self._on_icon_hover = on_icon_hover
        self._content_width = 0
        self._progress_has_icon = False
        self._last_view: ActiveJobStripView | None = None
        self._row_widgets: list[QWidget] = []
        self._bar_handles: list[tuple[QLabel, QLabel, QLabel, StripProgressBar]] = []
        self._cooldown_skip_label: CooldownSkipLabel | None = None
        self._cancel_btn: _StripIconButton | None = None
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(2)
        self.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )

    def has_rows(self) -> bool:
        return bool(self._row_widgets)

    def set_content_width(self, content_width: int) -> None:
        """Update target width when the strip is resized (no full rebuild)."""
        content_width = max(80, int(content_width))
        if content_width == self._content_width:
            return
        self._content_width = content_width
        row_w = self._progress_row_width()
        for _label, _prefix, _postfix, bar in self._bar_handles:
            outer = bar.parentWidget()
            if outer is not None:
                outer.setMinimumWidth(row_w)
        self.updateGeometry()

    def set_strip_view(self, view: ActiveJobStripView, content_width: int) -> None:
        self._content_width = max(80, int(content_width))
        self._last_view = view
        self._progress_has_icon = view.show_cancel_icon
        self._clear_rows()
        if view.mode == "cooldown":
            self._add_cooldown_row(view)
        for row in view.rows:
            if isinstance(row, StripBarRow):
                self._add_progress_row(row)
            elif isinstance(row, StripCountRow):
                self._add_count_row(row)
        self.updateGeometry()

    def update_live_fields(self, view: ActiveJobStripView) -> None:
        self._last_view = view
        if view.mode == "cooldown":
            if self._cooldown_skip_label is not None:
                self._cooldown_skip_label.set_prefix(view.cooldown_text)
                self._cooldown_skip_label.set_count(view.cooldown_count_text)
            return
        bar_rows = [row for row in view.rows if isinstance(row, StripBarRow)]
        for handle, row in zip(self._bar_handles, bar_rows):
            _label_lbl, prefix, postfix, bar = handle
            prefix.setText(_strip_cell_text(row.prefix))
            postfix.setText(_strip_cell_text(row.postfix))
            bar.set_values(
                fill_percent=row.fill_percent,
                slot_text=row.slot_text,
                show_pending_start=row.show_pending_start,
            )

    def update_icon_hover(self, *, skip_hovered: bool, cancel_hovered: bool) -> None:
        if self._cooldown_skip_label is not None:
            self._cooldown_skip_label.set_hovered(skip_hovered)
        if self._cancel_btn is not None:
            self._cancel_btn.set_hovered(cancel_hovered)

    def refresh_theme_styles(self) -> None:
        if self._last_view is not None and self._content_width > 0:
            self.set_strip_view(self._last_view, self._content_width)

    def _clear_rows(self) -> None:
        while self._layout.count():
            item = self._layout.takeAt(0)
            widget = item.widget() if item is not None else None
            if widget is not None:
                widget.deleteLater()
        self._row_widgets.clear()
        self._bar_handles.clear()
        self._cooldown_skip_label = None
        self._cancel_btn = None

    def _notify_icon_hover(self, kind: str, hovered: bool) -> None:
        if self._on_icon_hover is not None:
            self._on_icon_hover(kind, hovered)

    def _label_style(self) -> str:
        t = get_active_theme()
        return (
            f"color: {t.sidebar_text_color_hex}; "
            f"font-size: {_FONT_PX}px; font-weight: bold;"
        )

    def _value_style(self) -> str:
        t = get_active_theme()
        return f"color: {t.sidebar_text_color_hex}; font-size: {_FONT_PX}px;"

    def _progress_row_width(self) -> int:
        return _information_panel_row_content_width(
            self._content_width, has_icon=self._progress_has_icon
        )

    def _add_cooldown_row(self, view: ActiveJobStripView) -> None:
        outer = QWidget()
        outer.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )
        layout = QHBoxLayout(outer)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        th = get_active_theme()
        cooldown_lbl = CooldownSkipLabel(
            prefix_text=view.cooldown_text,
            count=view.cooldown_count_text,
            text_color_hex=th.sidebar_text_color_hex,
            font_px=_FONT_PX,
            show_skip=view.show_skip_icon,
            on_hovered=lambda hovered: self._notify_icon_hover("skip", hovered),
            on_clicked=self._on_skip,
        )
        cooldown_lbl.set_hovered(view.skip_hovered)
        self._cooldown_skip_label = cooldown_lbl
        layout.addWidget(
            cooldown_lbl, 0, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter
        )
        layout.addStretch(1)
        if view.show_cancel_icon:
            cancel = _StripIconButton(
                "trash_icon.png",
                "trash_icon_hover.png",
                "Cancel generation",
                on_hovered=lambda hovered: self._notify_icon_hover("cancel", hovered),
            )
            cancel.set_hovered(view.cancel_hovered)
            cancel.clicked.connect(self._on_cancel)
            self._cancel_btn = cancel
            layout.addWidget(cancel, 0, Qt.AlignmentFlag.AlignVCenter)
        self._layout.addWidget(outer)
        self._row_widgets.append(outer)

    def _add_count_row(self, row: StripCountRow) -> None:
        outer = QWidget()
        outer.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )
        layout = QHBoxLayout(outer)
        layout.setContentsMargins(0, 0, 0, 0)
        label = QLabel(row.label)
        label.setFixedWidth(_INFO_PANEL_LABEL_W)
        label.setStyleSheet(self._label_style())
        value = QLabel(row.count)
        value.setStyleSheet(self._value_style())
        layout.addWidget(label)
        layout.addWidget(value, 1)
        self._layout.addWidget(outer)
        self._row_widgets.append(outer)

    def _add_progress_row(self, row: StripBarRow) -> None:
        wrapper = self._build_progress_row(row)
        self._layout.addWidget(wrapper)
        self._row_widgets.append(wrapper)

    def _build_progress_row(self, row: StripBarRow) -> QWidget:
        outer = QWidget()
        outer.setMinimumWidth(self._progress_row_width())
        outer.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
        )
        layout = QHBoxLayout(outer)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        label = QLabel(row.label)
        label.setFixedWidth(_INFO_PANEL_LABEL_W)
        label.setStyleSheet(self._label_style())
        layout.addWidget(label, 0, Qt.AlignmentFlag.AlignVCenter)

        prefix = QLabel(_strip_cell_text(row.prefix))
        prefix.setFixedWidth(_INFO_PANEL_PREFIX_W)
        prefix.setStyleSheet(self._value_style())
        layout.addWidget(prefix, 0, Qt.AlignmentFlag.AlignVCenter)

        bar = StripProgressBar(
            row.fill_percent,
            slot_text=row.slot_text,
            show_pending_start=row.show_pending_start,
        )
        layout.addWidget(bar, 1, Qt.AlignmentFlag.AlignVCenter)

        postfix = QLabel(_strip_cell_text(row.postfix))
        postfix.setFixedWidth(_INFO_PANEL_POSTFIX_W)
        postfix.setStyleSheet(self._value_style())
        postfix.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        layout.addWidget(postfix, 0, Qt.AlignmentFlag.AlignVCenter)
        self._bar_handles.append((label, prefix, postfix, bar))
        return outer

    def _on_skip(self) -> None:
        from imagegen_plugins.image_gen_controller import get_imagegen_controller

        try:
            get_imagegen_controller(self._main_window).skip_copy_cooldown()
        except ImportError:
            pass

    def _on_cancel(self) -> None:
        from imagegen_plugins.image_gen_controller import get_imagegen_controller

        get_imagegen_controller(self._main_window).confirm_cancel_generation(
            self._main_window
        )

    def sizeHint(self):
        h = 0
        for i in range(self._layout.count()):
            item = self._layout.itemAt(i)
            w = item.widget() if item is not None else None
            if w is not None:
                h += w.sizeHint().height()
        h += max(0, self._layout.count() - 1) * self._layout.spacing()
        return QSize(self._content_width, max(h, 28))
