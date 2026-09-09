#!/usr/bin/env python3
"""Native Qt status block for job queue cards (replaces QTextBrowser HTML)."""

from __future__ import annotations

import re

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QFontMetrics, QPalette
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from imagegen_plugins.job_status_views import (
    QueueBannerRow,
    QueueInlineRow,
    QueueJobStatusView,
    QueueLabelValueRow,
    QueuePromptRow,
    QueueStatusRow,
    QueueTitleRow,
    QueueUnavailableRow,
)
from imagegen_plugins.model_task_status_info import (
    TASK_STATUS_PROMPT_MARGIN_PX,
    _INFO_PANEL_LABEL_W,
)
from imagegen_plugins.job_queue_skip_cooldown_button import CooldownSkipLabel
from imagegen_plugins.prompt_display_layout import (
    clamp_prompt_for_display,
    job_card_prompt_font,
)
from theme.theme_service import get_active_theme

_LABEL_WIDTH = _INFO_PANEL_LABEL_W
_FONT_PX = 12
_INLINE_GAP_PX = 3


def _inline_row_shows_cooldown(row: QueueInlineRow) -> bool:
    return "(Cooldown)" in (row.primary_value or "")


def _split_cooldown_primary(primary: str) -> tuple[str, str] | None:
    """Split '… (Cooldown) N' into pre-cooldown prefix and countdown digits."""
    text = primary or ""
    marker = "(Cooldown)"
    idx = text.rfind(marker)
    if idx < 0:
        return None
    count = text[idx + len(marker) :].strip()
    if not re.fullmatch(r"\d+", count):
        return None
    return text[:idx].rstrip(), count


def _muted_color() -> str:
    return get_active_theme().job_queue_text_muted_hex(running=True)


def _bright_color() -> str:
    return get_active_theme().sidebar_text_color_hex


def _apply_label_palette(label: QLabel, *, muted: bool = False, bold: bool = False) -> None:
    color = _muted_color() if muted else _bright_color()
    pal = label.palette()
    pal.setColor(QPalette.ColorRole.WindowText, QColor(color))
    label.setPalette(pal)
    label.setAutoFillBackground(False)
    font = label.font()
    font.setPixelSize(_FONT_PX)
    font.setBold(bold)
    label.setFont(font)


class JobCardStatusWidget(QWidget):
    """Renders QueueJobStatusView rows with fixed label column and wrapping values."""

    def __init__(self, main_window, parent=None):
        super().__init__(parent)
        self._main_window = main_window
        self._content_width = 0
        self._last_view: QueueJobStatusView | None = None
        self._displayed_prompt_text = ""
        self._row_widgets: list[QWidget] = []
        self._skip_btn: CooldownSkipLabel | None = None

        self._rows_layout = QVBoxLayout(self)
        self._rows_layout.setContentsMargins(0, 0, 0, 0)
        self._rows_layout.setSpacing(0)

    def displayed_prompt_text(self) -> str:
        return self._displayed_prompt_text

    def has_rendered_view(self) -> bool:
        return self._last_view is not None and bool(self._row_widgets)

    def set_content_width(self, content_width: int) -> None:
        """Reclamp wrapped rows after a width change without rebuilding the tree."""
        content_width = max(80, int(content_width))
        if content_width == self._content_width or self._last_view is None:
            return
        self._content_width = content_width
        val_w = self._value_column_width()
        for widget, row in zip(self._row_widgets, self._last_view.rows):
            if isinstance(row, QueuePromptRow):
                font = job_card_prompt_font(self.font())
                clamped = clamp_prompt_for_display(row.value, font, val_w)
                self._displayed_prompt_text = clamped
                for lbl in widget.findChildren(QLabel, "value"):
                    lbl.setFixedWidth(val_w)
                    lbl.setText(clamped)
            elif isinstance(row, QueueLabelValueRow):
                for lbl in widget.findChildren(QLabel, "value"):
                    lbl.setFixedWidth(val_w)
            elif isinstance(row, QueueInlineRow):
                for lbl in widget.findChildren(QLabel, "value"):
                    if lbl.wordWrap():
                        lbl.setFixedWidth(val_w)
        self.updateGeometry()

    def refresh_theme_styles(self) -> None:
        if self._last_view is not None and self._content_width > 0:
            self.set_status_view(self._last_view, self._content_width)

    def set_status_view(self, view: QueueJobStatusView, content_width: int) -> None:
        self._content_width = max(80, int(content_width))
        self._last_view = view
        self._displayed_prompt_text = ""
        self._clear_rows()
        for row in view.rows:
            self._add_row(row, view)
        self._apply_mouse_transparency()
        self._sync_skip_button(view)
        self.updateGeometry()

    def update_live_fields(self, view: QueueJobStatusView) -> None:
        if not self._row_widgets:
            self.set_status_view(view, self._content_width or 80)
            return
        self._last_view = view
        for widget, row in zip(self._row_widgets, view.rows):
            if isinstance(row, QueueInlineRow):
                parts = _split_cooldown_primary(row.primary_value)
                skip_lbl = widget.findChild(CooldownSkipLabel)
                if skip_lbl is not None and parts is not None:
                    skip_lbl.set_count(parts[1])
                elif parts is not None:
                    prefix, _count = parts
                    for lbl in widget.findChildren(QLabel, "value"):
                        if lbl.property("inline_part") != "value":
                            lbl.setText(prefix)
                            break
                else:
                    for lbl in widget.findChildren(QLabel, "value"):
                        if lbl.property("inline_part") != "value":
                            lbl.setText(row.primary_value)
                            break
                for part_label, part_value in row.inline_parts:
                    for lbl in widget.findChildren(QLabel):
                        if (
                            lbl.property("inline_part") == "value"
                            and lbl.property("inline_label") == part_label
                        ):
                            lbl.setText(part_value)
                            break
        self._sync_skip_button(view)
        self.updateGeometry()

    def _sync_skip_button(self, view: QueueJobStatusView) -> None:
        if self._skip_btn is not None:
            self._skip_btn.set_show_skip(view.show_skip_cooldown)

    def _apply_mouse_transparency(self) -> None:
        """Let JobCard receive press/drag on status text (QTextBrowser did this as one surface)."""
        skip = self._skip_btn
        for widget in self.findChildren(QWidget):
            if isinstance(widget, (QPushButton, CooldownSkipLabel)):
                continue
            if skip is not None and (widget is skip or skip.isAncestorOf(widget)):
                continue
            widget.setAttribute(
                Qt.WidgetAttribute.WA_TransparentForMouseEvents, True
            )

    def _clear_rows(self) -> None:
        while self._rows_layout.count():
            item = self._rows_layout.takeAt(0)
            widget = item.widget() if item is not None else None
            if widget is not None:
                widget.deleteLater()
        self._row_widgets.clear()
        self._skip_btn = None

    def _make_label(self, text: str, *, bold: bool = False, muted: bool = True) -> QLabel:
        label = QLabel(text)
        label.setObjectName("label")
        _apply_label_palette(label, muted=muted, bold=bold)
        label.setFixedWidth(_LABEL_WIDTH)
        label.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Preferred)
        return label

    def _make_value(self, text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("value")
        _apply_label_palette(label, muted=False)
        label.setWordWrap(True)
        label.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        return label

    def _value_column_width(self) -> int:
        return max(40, self._content_width - _LABEL_WIDTH)

    def _row_height(self, widget: QWidget) -> int:
        return max(widget.sizeHint().height(), widget.height())

    def _add_field_row(
        self,
        label_text: str,
        value_text: str,
        *,
        prompt_padding: bool = False,
    ) -> None:
        outer = QWidget()
        layout = QHBoxLayout(outer)
        top = TASK_STATUS_PROMPT_MARGIN_PX if prompt_padding else 0
        bottom = TASK_STATUS_PROMPT_MARGIN_PX if prompt_padding else 0
        layout.setContentsMargins(0, top, 0, bottom)
        layout.setSpacing(2)
        layout.addWidget(self._make_label(label_text))
        value = self._make_value(value_text)
        value.setFixedWidth(self._value_column_width())
        layout.addWidget(value, 1)
        self._rows_layout.addWidget(outer)
        self._row_widgets.append(outer)

    def _add_inline_row(self, row: QueueInlineRow, view: QueueJobStatusView) -> None:
        outer = QWidget()
        layout = QHBoxLayout(outer)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        show_skip = view.show_skip_cooldown
        cooldown_parts = (
            _split_cooldown_primary(row.primary_value)
            if show_skip and _inline_row_shows_cooldown(row)
            else None
        )
        if show_skip and self._skip_btn is None and cooldown_parts is not None:
            skip_lbl = CooldownSkipLabel(
                prefix_text=row.label,
                count=cooldown_parts[1],
                text_color_hex=_bright_color(),
                font_px=_FONT_PX,
                prefix_muted=True,
                on_clicked=self._on_skip_cooldown,
            )
            skip_lbl.setObjectName("cooldown_skip_label")
            self._skip_btn = skip_lbl
            layout.addWidget(skip_lbl, 0, Qt.AlignmentFlag.AlignLeft)
        else:
            layout.addWidget(self._make_label(row.label))

        value_area_w = max(40, self._value_column_width())

        value_layout = QHBoxLayout()
        value_layout.setContentsMargins(0, 0, 0, 0)
        value_layout.setSpacing(_INLINE_GAP_PX)
        primary_text = cooldown_parts[0] if cooldown_parts else row.primary_value
        has_primary = bool(primary_text)
        if has_primary:
            primary = self._make_value(primary_text)
            if row.inline_parts or show_skip:
                primary.setMaximumWidth(value_area_w)
                primary.setSizePolicy(
                    QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Preferred
                )
            else:
                primary.setFixedWidth(value_area_w)
            value_layout.addWidget(primary, 0)

        for part_label, part_value in row.inline_parts:
            part_lbl = self._make_label(part_label, muted=True)
            part_lbl.setProperty("inline_part", "label")
            part_lbl.setFixedWidth(QFontMetrics(part_lbl.font()).horizontalAdvance(part_label) + 4)
            value_layout.addWidget(part_lbl)
            part_val = self._make_value(part_value)
            part_val.setProperty("inline_part", "value")
            part_val.setProperty("inline_label", part_label)
            part_val.setSizePolicy(QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Preferred)
            value_layout.addWidget(part_val)

        if has_primary or row.inline_parts:
            layout.addLayout(value_layout, 1)
        elif cooldown_parts is None:
            layout.addStretch(1)
        self._rows_layout.addWidget(outer)
        self._row_widgets.append(outer)

    def _on_skip_cooldown(self) -> None:
        from imagegen_plugins.image_gen_controller import get_imagegen_controller

        get_imagegen_controller(self._main_window).skip_copy_cooldown()

    def _add_title_row(self, row: QueueTitleRow) -> None:
        display = f"{row.title} (Running)" if row.running else row.title
        label = QLabel(display)
        _apply_label_palette(label, muted=False, bold=True)
        label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._rows_layout.addWidget(label)
        self._row_widgets.append(label)

    def _add_banner_row(self, row: QueueBannerRow) -> None:
        label = QLabel(row.text)
        _apply_label_palette(label, muted=False)
        label.setWordWrap(True)
        self._rows_layout.addWidget(label)
        self._row_widgets.append(label)

    def _add_unavailable_block(self, row: QueueUnavailableRow) -> None:
        block = QWidget()
        layout = QVBoxLayout(block)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)
        for text, bold in (
            (row.heading, True),
            (row.copies_line, False),
            (row.prompt_line, False),
        ):
            lbl = QLabel(text)
            _apply_label_palette(lbl, muted=False, bold=bold)
            lbl.setWordWrap(True)
            layout.addWidget(lbl)
        self._rows_layout.addWidget(block)
        self._row_widgets.append(block)

    def _add_row(self, row: QueueStatusRow, view: QueueJobStatusView) -> None:
        if isinstance(row, QueueTitleRow):
            self._add_title_row(row)
        elif isinstance(row, QueueLabelValueRow):
            self._add_field_row(row.label, row.value)
        elif isinstance(row, QueuePromptRow):
            font = job_card_prompt_font(self.font())
            clamped = clamp_prompt_for_display(
                row.value,
                font,
                self._value_column_width(),
            )
            self._displayed_prompt_text = clamped
            self._add_field_row(row.label, clamped, prompt_padding=True)
        elif isinstance(row, QueueInlineRow):
            self._add_inline_row(row, view)
        elif isinstance(row, QueueUnavailableRow):
            self._add_unavailable_block(row)
        elif isinstance(row, QueueBannerRow):
            self._add_banner_row(row)

    def sizeHint(self):
        h = 0
        for i in range(self._rows_layout.count()):
            item = self._rows_layout.itemAt(i)
            w = item.widget() if item is not None else None
            if w is not None:
                h += self._row_height(w)
        return QSize(0, max(h, 1))
