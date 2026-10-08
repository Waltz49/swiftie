#!/usr/bin/env python3
"""Skip-cooldown label: prefix text, arrow, and (N) drawn as one tight unit."""

from __future__ import annotations

import math
from typing import Callable

from PySide6.QtCore import Qt, QPointF, QRect, QSize
from PySide6.QtGui import QColor, QFont, QFontMetrics, QPainter, QPolygonF
from PySide6.QtWidgets import QSizePolicy, QWidget

from theme.theme_service import get_active_theme

SKIP_COOLDOWN_BTN_PX = 16
_FONT_PX = 12


def format_cooldown_count_label(count: int | str) -> str:
    """Parenthesized countdown with leading space (e.g. ' (3)')."""
    text = str(count).strip()
    if text.startswith("("):
        return f" {text}"
    return f" ({text})"


def _equilateral_play_triangle(
    width: int, height: int, *, margin: int = 2
) -> QPolygonF:
    avail_w = max(1, width - 2 * margin)
    avail_h = max(1, height - 2 * margin)
    side = min(avail_h, avail_w * 2.0 / math.sqrt(3.0))
    cx = width / 2.0
    cy = height / 2.0
    x0 = cx - (side * math.sqrt(3.0) / 4.0)
    return QPolygonF(
        [
            QPointF(x0, cy - side / 2.0),
            QPointF(x0, cy + side / 2.0),
            QPointF(x0 + side * math.sqrt(3.0) / 2.0, cy),
        ]
    )


def skip_cooldown_arrow_color(*, hovered: bool = False) -> QColor:
    import thumbnails.thumbnail_constants as tc

    hex_color = tc.CURRENT_IMAGE_BORDER_COLOR_HEX
    if not hex_color:
        hex_color = get_active_theme().current_image_border_color_hex
    color = QColor(hex_color)
    if hovered:
        color = color.lighter(125)
    return color


class CooldownSkipLabel(QWidget):
    """Paint 'Prefix ▶ (N)' on one surface; arrow region is clickable."""

    def __init__(
        self,
        *,
        prefix_text: str,
        count: int | str,
        text_color_hex: str,
        font_px: int = _FONT_PX,
        prefix_muted: bool = False,
        show_skip: bool = True,
        on_hovered: Callable[[bool], None] | None = None,
        on_clicked: Callable[[], None] | None = None,
        parent=None,
    ):
        super().__init__(parent)
        self._prefix_text = prefix_text or ""
        self._count = count
        self._text_color_hex = text_color_hex
        self._prefix_muted = bool(prefix_muted)
        self._show_skip = bool(show_skip)
        self._hovered = False
        self._on_hovered = on_hovered
        self._on_clicked = on_clicked
        self._arrow_rect = QRect()
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self.setToolTip("Skip cooldown" if show_skip else "")
        self._apply_font(font_px)

    def _apply_font(self, font_px: int) -> None:
        font = QFont()
        font.setPixelSize(font_px)
        self.setFont(font)

    def _text_color(self) -> QColor:
        return QColor(self._text_color_hex)

    def _prefix_color(self) -> QColor:
        if not self._prefix_muted:
            return self._text_color()
        return QColor(get_active_theme().job_queue_text_muted_hex(running=True))

    def set_prefix(self, text: str) -> None:
        text = text or ""
        if text == self._prefix_text:
            return
        self._prefix_text = text
        self._relayout()

    def set_count(self, count: int | str) -> None:
        if str(count).strip() == str(self._count).strip():
            return
        self._count = count
        self._relayout()

    def set_show_skip(self, show: bool) -> None:
        show = bool(show)
        if show == self._show_skip:
            return
        self._show_skip = show
        self.setToolTip("Skip cooldown" if show else "")
        self._relayout()

    def set_hovered(self, hovered: bool) -> None:
        hovered = bool(hovered)
        if hovered == self._hovered:
            return
        self._hovered = hovered
        self.setCursor(
            Qt.CursorShape.PointingHandCursor
            if hovered and self._show_skip
            else Qt.CursorShape.ArrowCursor
        )
        self.update()

    def _relayout(self) -> None:
        self.setFixedSize(self.sizeHint())
        self.update()

    def _layout(self, fm: QFontMetrics) -> tuple[int, int, QRect]:
        """Return total width, widget height, arrow rect in widget coords."""
        space_w = fm.horizontalAdvance(" ")
        prefix_w = fm.horizontalAdvance(self._prefix_text)
        count_w = fm.horizontalAdvance(format_cooldown_count_label(self._count))
        arrow_w = SKIP_COOLDOWN_BTN_PX if self._show_skip else 0
        total_w = prefix_w
        arrow_rect = QRect()
        if self._show_skip:
            total_w += space_w + arrow_w + count_w
            top = max(0, (fm.height() - SKIP_COOLDOWN_BTN_PX) // 2)
            arrow_rect = QRect(prefix_w + space_w, top, arrow_w, SKIP_COOLDOWN_BTN_PX)
        else:
            total_w += count_w
        return total_w, fm.height(), arrow_rect

    def sizeHint(self) -> QSize:
        fm = QFontMetrics(self.font())
        total_w, total_h, _ = self._layout(fm)
        return QSize(max(1, total_w), max(1, total_h))

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        fm = QFontMetrics(self.font())
        _, total_h, arrow_rect = self._layout(fm)
        self._arrow_rect = arrow_rect
        baseline = (total_h + fm.ascent() - fm.descent()) // 2
        x = 0

        painter.setPen(self._prefix_color())
        painter.drawText(x, baseline, self._prefix_text)
        x += fm.horizontalAdvance(self._prefix_text)

        if self._show_skip:
            x += fm.horizontalAdvance(" ")
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(skip_cooldown_arrow_color(hovered=self._hovered))
            painter.save()
            painter.translate(float(arrow_rect.x()), float(arrow_rect.y()))
            painter.drawPolygon(
                _equilateral_play_triangle(arrow_rect.width(), arrow_rect.height())
            )
            painter.restore()
            x = arrow_rect.right() + 1

        painter.setPen(self._text_color())
        painter.drawText(x, baseline, format_cooldown_count_label(self._count))

    def _arrow_hit(self, pos) -> bool:
        return self._show_skip and self._arrow_rect.contains(
            int(pos.x()), int(pos.y())
        )

    def enterEvent(self, event) -> None:
        if self._arrow_hit(event.position().toPoint()):
            self.set_hovered(True)
            if self._on_hovered is not None:
                self._on_hovered(True)
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self.set_hovered(False)
        if self._on_hovered is not None:
            self._on_hovered(False)
        super().leaveEvent(event)

    def mouseMoveEvent(self, event) -> None:
        hovered = self._arrow_hit(event.position())
        self.set_hovered(hovered)
        if self._on_hovered is not None:
            self._on_hovered(hovered)
        super().mouseMoveEvent(event)

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self._arrow_hit(
            event.position()
        ):
            if self._on_clicked is not None:
                self._on_clicked()
            event.accept()
            return
        super().mousePressEvent(event)
