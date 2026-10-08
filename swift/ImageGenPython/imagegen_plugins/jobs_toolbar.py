#!/usr/bin/env python3
"""Job Control pane toolbar: intermediate images, hold queue, skip copy."""

from __future__ import annotations

from typing import Callable, Dict, Optional

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QStackedWidget,
    QWidget,
)

from theme.theme_service import get_active_theme
from thumbnails.information_action_nav import (
    INFO_ACTION_BTN_PX,
    INFO_ACTION_ICON_PX,
    info_action_button_stylesheet,
)
from widgets.icon_hover_swap import IconHoverSwap, attach_icon_hover_swap, icon_pair_from_assets

_TOOLBAR_ACTION = tuple[str, str, str, str, bool]

_TOOLBAR_ACTIONS: tuple[_TOOLBAR_ACTION, ...] = (
    (
        "intermediate_images",
        "jobs_intermediate.png",
        "jobs_intermediate_hover.png",
        "Intermediate Images\nShow progressive images during generation",
        True,
    ),
    (
        "hold_queue",
        "jobs_hold.png",
        "jobs_hold_hover.png",
        "Hold Job Queue\nPause starting new jobs until released",
        True,
    ),
    (
        "skip_copy",
        "jobs_skip_copy.png",
        "jobs_skip_copy_hover.png",
        "Skip This Copy\nEnd the current copy and start the next one in this series",
        False,
    ),
)


class JobPaneToolbar(QWidget):
    """Horizontal toolbar for common Job Control pane actions."""

    _SKIPPING_COPY_TEXT = "Skipping copy..."

    def __init__(self, pane: object, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._pane = pane
        self._buttons: Dict[str, QPushButton] = {}
        self._icon_hovers: Dict[str, IconHoverSwap] = {}
        self._skipping_copy_active = False
        self._stack: QStackedWidget | None = None
        self._skipping_label: QLabel | None = None
        self._setup_ui()

    def _make_icon_button(
        self,
        *,
        action_id: str,
        tooltip: str,
        normal_name: str,
        hover_name: str,
        on_click: Callable[[], None],
        checkable: bool = False,
    ) -> QPushButton:
        btn = QPushButton()
        btn.setToolTip(tooltip)
        btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        btn.setFixedSize(INFO_ACTION_BTN_PX, INFO_ACTION_BTN_PX)
        btn.setIconSize(QSize(INFO_ACTION_ICON_PX, INFO_ACTION_ICON_PX))
        normal, hover = icon_pair_from_assets(normal_name, hover_name)
        self._icon_hovers[action_id] = attach_icon_hover_swap(btn, normal, hover)
        if checkable:
            btn.setCheckable(True)
        btn.clicked.connect(on_click)
        return btn

    def _setup_ui(self) -> None:
        self.setAutoFillBackground(True)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        self._stack = QStackedWidget(self)
        root.addWidget(self._stack)

        actions_host = QWidget(self._stack)
        actions_layout = QHBoxLayout(actions_host)
        actions_layout.setContentsMargins(8, 4, 8, 4)
        actions_layout.setSpacing(4)

        pane = self._pane
        for action_id, normal_name, hover_name, tooltip, checkable in _TOOLBAR_ACTIONS:
            btn = self._make_icon_button(
                action_id=action_id,
                tooltip=tooltip,
                normal_name=normal_name,
                hover_name=hover_name,
                on_click=lambda checked=False, aid=action_id: pane.trigger_jobs_toolbar_action(
                    aid, checked
                ),
                checkable=checkable,
            )
            self._buttons[action_id] = btn
            actions_layout.addWidget(btn)

        actions_layout.addStretch(1)

        skipping_host = QWidget(self._stack)
        skipping_layout = QHBoxLayout(skipping_host)
        skipping_layout.setContentsMargins(8, 4, 8, 4)
        skipping_layout.setSpacing(0)
        self._skipping_label = QLabel(self._SKIPPING_COPY_TEXT, skipping_host)
        self._skipping_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        skipping_layout.addWidget(self._skipping_label, 1)

        self._stack.addWidget(actions_host)
        self._stack.addWidget(skipping_host)
        self._stack.setCurrentIndex(0)
        row_h = max(actions_host.sizeHint().height(), skipping_host.sizeHint().height(), 24)
        self._stack.setMinimumHeight(row_h)
        self.refresh_theme_styles()

    def button(self, action_id: str) -> Optional[QPushButton]:
        return self._buttons.get(action_id)

    def set_intermediate_checked(self, checked: bool) -> None:
        btn = self._buttons.get("intermediate_images")
        if btn is not None:
            btn.blockSignals(True)
            btn.setChecked(bool(checked))
            btn.blockSignals(False)
        swap = self._icon_hovers.get("intermediate_images")
        if swap is not None:
            swap.set_active(bool(checked))

    def set_hold_checked(self, checked: bool) -> None:
        btn = self._buttons.get("hold_queue")
        if btn is not None:
            btn.blockSignals(True)
            btn.setChecked(bool(checked))
            btn.blockSignals(False)
        swap = self._icon_hovers.get("hold_queue")
        if swap is not None:
            swap.set_active(bool(checked))

    def set_action_enabled(self, action_id: str, enabled: bool) -> None:
        btn = self._buttons.get(action_id)
        if btn is not None:
            btn.setEnabled(bool(enabled))

    def set_toolbar_visible(self, visible: bool) -> None:
        self.setVisible(bool(visible))

    def set_skipping_copy_active(self, active: bool) -> None:
        active = bool(active)
        if active == self._skipping_copy_active:
            return
        self._skipping_copy_active = active
        if self._stack is not None:
            self._stack.setCurrentIndex(1 if active else 0)
        if active:
            self.repaint()

    def action_icon(self, action_id: str) -> QIcon:
        btn = self._buttons.get(action_id)
        if btn is not None:
            return btn.icon()
        return QIcon()

    def refresh_theme_styles(self) -> None:
        th = get_active_theme()
        self.setStyleSheet(th.file_tree_nav_container_stylesheet())
        if self._skipping_label is not None:
            self._skipping_label.setStyleSheet(
                f"color: {th.sidebar_text_color_hex}; font-size: 12px;"
            )
        hold_btn = self._buttons.get("hold_queue")
        hold_checked = bool(hold_btn.isChecked()) if hold_btn is not None else False
        inter_btn = self._buttons.get("intermediate_images")
        inter_checked = bool(inter_btn.isChecked()) if inter_btn is not None else False
        for action_id, btn in self._buttons.items():
            btn.setStyleSheet(info_action_button_stylesheet())
        for action_id, normal_name, hover_name, _tooltip, _checkable in _TOOLBAR_ACTIONS:
            normal, hover = icon_pair_from_assets(normal_name, hover_name)
            swap = self._icon_hovers.get(action_id)
            if swap is not None:
                swap.set_icons(normal, hover)
                if action_id == "hold_queue":
                    swap.set_active(hold_checked)
                elif action_id == "intermediate_images":
                    swap.set_active(inter_checked)
