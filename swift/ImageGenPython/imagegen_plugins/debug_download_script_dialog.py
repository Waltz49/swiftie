#!/usr/bin/env python3

"""Tools > Debug — resizable bash script viewers with copy (and optional run)."""
from __future__ import annotations
import os
import shlex
import stat
from PySide6.QtCore import QByteArray, QEvent, Qt, QTimer, QSize
from PySide6.QtGui import QIcon, QPainter, QPen, QColor, QPixmap
from PySide6.QtWidgets import QApplication, QDialog, QHBoxLayout, QPlainTextEdit, QPushButton, QVBoxLayout
from config import get_config
from imagegen_plugins.debug_download_scripts import build_sample_flux_lora_download_script
from macos_process import run_terminal_script_checked
from thumbnails.thumbnail_constants import ACCENT_COLOR_HEX, BORDER_DEFAULT_HEX, BUTTON_BG_DEFAULT_HEX, BUTTON_TEXT_HOVER_HEX, DIALOG_TEXT_COLOR_HEX, TEXT_DISABLED_HEX, VALIDATION_SUCCESS_COLOR_HEX
from utils import (
    ensure_dialog_fits_screen,
    get_button_style,
    get_dialog_shell_stylesheet,
)
_LORA_SCRIPT_PATH = '/tmp/download_sample_flux_loras.sh'

def _create_copy_icon(color: str=ACCENT_COLOR_HEX) -> QIcon:
    pixmap = QPixmap(18, 18)
    pixmap.fill(QColor(0, 0, 0, 0))
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setPen(QPen(QColor(color), 1.5))
    painter.setBrush(Qt.BrushStyle.NoBrush)
    painter.drawRect(2, 2, 8, 8)
    painter.drawRect(6, 6, 8, 8)
    painter.end()
    return QIcon(pixmap)

class DebugDownloadScriptDialog(QDialog):
    """Resizable script viewer with copy button and persisted geometry."""

    def __init__(self, parent=None, *, title: str, script_text: str, geometry_key: str, show_run: bool=False, run_script_path: str=''):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumSize(520, 360)
        self.resize(720, 480)
        self.setStyleSheet(get_dialog_shell_stylesheet() + get_button_style())
        self._config = parent.config if parent and hasattr(parent, 'config') else get_config()
        self._script_text = script_text
        self._geometry_key = geometry_key
        self._show_run = show_run
        self._run_script_path = run_script_path
        self._setup_ui()
        self.finished.connect(self._save_geometry)

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)
        script_row = QHBoxLayout()
        script_row.setSpacing(8)
        self._script_edit = QPlainTextEdit()
        self._script_edit.setReadOnly(True)
        self._script_edit.setPlainText(self._script_text)
        self._script_edit.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self._script_edit.setStyleSheet('\n            QPlainTextEdit {\n                border-radius: 6px;\n                padding: 8px 10px;\n                font-family: Menlo, Monaco, "Courier New", monospace;\n                font-size: 12px;\n            }\n            ')
        script_row.addWidget(self._script_edit, stretch=1)
        btn_col = QVBoxLayout()
        btn_col.setSpacing(8)
        self._copy_btn = QPushButton()
        self._copy_btn.setObjectName('copy_btn')
        self._copy_icon_normal = _create_copy_icon(TEXT_DISABLED_HEX)
        self._copy_icon_hover = _create_copy_icon(BUTTON_TEXT_HOVER_HEX)
        self._copy_btn.setIcon(self._copy_icon_normal)
        self._copy_btn.setIconSize(QSize(16, 16))
        self._copy_btn.setToolTip('Copy script to clipboard')
        self._copy_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._copy_btn.clicked.connect(self._on_copy)
        self._copy_btn.installEventFilter(self)
        btn_col.addWidget(self._copy_btn, alignment=Qt.AlignmentFlag.AlignTop)
        if self._show_run:
            self._run_btn = QPushButton('Run')
            self._run_btn.setToolTip(f'Save to {self._run_script_path}, chmod +x, and run in Terminal')
            self._run_btn.clicked.connect(self._on_run)
            btn_col.addWidget(self._run_btn, alignment=Qt.AlignmentFlag.AlignTop)
        btn_col.addStretch()
        script_row.addLayout(btn_col)
        layout.addLayout(script_row, stretch=1)
        btn_row = QHBoxLayout()
        btn_row.addStretch()
        close_btn = QPushButton('Close')
        close_btn.setDefault(True)
        close_btn.clicked.connect(self.accept)
        btn_row.addWidget(close_btn)
        btn_row.addStretch()
        layout.addLayout(btn_row)

    def eventFilter(self, obj, event):
        if obj is self._copy_btn:
            if event.type() == QEvent.Type.Enter:
                self._copy_btn.setIcon(self._copy_icon_hover)
            elif event.type() == QEvent.Type.Leave:
                self._copy_btn.setIcon(self._copy_icon_normal)
        return super().eventFilter(obj, event)

    def _on_copy(self) -> None:
        from copy_feedback import copy_text_to_clipboard
        copy_text_to_clipboard(self._script_text, anchor=self._script_edit)

    def _on_run(self) -> None:
        path = self._run_script_path
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(self._script_text)
        mode = os.stat(path).st_mode
        os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        ok, detail = run_terminal_script_checked(
            f"bash {shlex.quote(path)}",
            activate=True,
        )
        if not ok:
            from utils import show_styled_warning

            show_styled_warning(
                self,
                "Could not open Terminal",
                "Prowser could not run the script in Terminal.\n\n"
                f"{detail}\n\n"
                "Allow Prowser to control Terminal under "
                "System Settings → Privacy & Security → Automation, "
                "or copy the script and run it manually.",
            )

    def _save_geometry(self) -> None:
        try:
            self._config.update_setting(self._geometry_key, self.saveGeometry().data().hex())
        except Exception:
            pass

    def showEvent(self, event) -> None:
        super().showEvent(event)
        try:
            geom_hex = self._config.load_settings().get(self._geometry_key)
            if geom_hex:
                self.restoreGeometry(QByteArray(bytes.fromhex(geom_hex)))
                ensure_dialog_fits_screen(self, self.parent())
        except Exception:
            pass

def run_flux_lora_download_script_dialog(parent=None) -> None:
    """Tools > Download LoRAs."""
    dialog = DebugDownloadScriptDialog(parent, title='Download LoRAs', script_text=build_sample_flux_lora_download_script(), geometry_key='debug_flux_lora_download_script_dialog_geometry', show_run=True, run_script_path=_LORA_SCRIPT_PATH)
    dialog.show()
