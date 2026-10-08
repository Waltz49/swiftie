#!/usr/bin/env python3
"""Tools > Manage models — model picker and per-model install/delete."""

from __future__ import annotations

import html
import os
from typing import Optional

from PySide6.QtCore import QByteArray, QEvent, Qt, QTimer, QSize
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPlainTextEdit,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from config import get_config
from imagegen_plugins.image_gen_model_availability import download_model_weights
from imagegen_plugins.model_download_progress import ModelDownloadCancelled
from imagegen_plugins.debug_download_scripts import (
    build_single_model_download_script,
)
from imagegen_plugins.model_download_catalog import (
    ModelDownloadCatalogEntry,
    build_model_download_catalog,
    delete_model_from_hf_cache,
    format_download_size_estimate,
    model_is_installed,
)
from theme.theme_service import get_active_theme
from thumbnails.thumbnail_constants import (
    BORDER_DEFAULT_HEX,
    BUTTON_BG_DEFAULT_HEX,
    BUTTON_TEXT_HOVER_HEX,
    DIALOG_TEXT_COLOR_HEX,
    TEXT_DISABLED_HEX,
    VALIDATION_SUCCESS_COLOR_HEX,
)
from widgets.icon_hover_swap import attach_icon_hover_swap, icon_pair_from_assets
from utils import (
    ensure_dialog_fits_screen,
    get_button_style,
    get_dialog_shell_stylesheet,
    show_styled_critical,
    show_styled_information,
    show_styled_question,
    show_styled_warning,
)

_LIST_GEOMETRY_KEY = "debug_download_models_list_dialog_geometry"
_DETAIL_GEOMETRY_KEY = "debug_download_models_detail_dialog_geometry"


def _hf_model_page_url(repo_id: str) -> str:
    return f"https://huggingface.co/{repo_id}"


def _confirm_model_download(
    parent,
    entry: ModelDownloadCatalogEntry,
    *,
    proceed_label: str,
    force_download: bool,
) -> bool:
    """Warn about size/availability; return True if the user chooses to proceed."""
    size_text = format_download_size_estimate(entry.repo_id)
    model_url = html.escape(_hf_model_page_url(entry.repo_id), quote=True)
    model_name = html.escape(entry.display_name)
    repo_id = html.escape(entry.repo_id)

    force_note = ""
    if force_download:
        force_note = (
            "<p style='margin: 0 0 10px 0;'>"
            "All cached files will be re-downloaded (<code>--force-download</code>)."
            "</p>"
        )

    body_html = (
        f"<p style='margin: 0 0 10px 0;'>"
        f"<b>{model_name}</b> may be large (estimated {html.escape(size_text)})."
        f"</p>"
        f"<p style='margin: 0 0 10px 0;'>"
        f"The model may no longer be available on Hugging Face, or its license terms "
        f"may have changed. Check the model page before proceeding."
        f"</p>"
        f"<p style='margin: 0 0 10px 0;'>"
        f'<a href="{model_url}">{repo_id}</a>'
        f"</p>"
        f"{force_note}"
        "<p style='margin: 0 0 10px 0;'>"
        "The download runs in the background so Prowser stays responsive. "
        "A progress window will appear and you can cancel if needed. "
        "Partial downloads resume later."
        "</p>"
        f"<p style='margin: 0;'>Proceed with {html.escape(proceed_label.lower())}?</p>"
    )

    dialog = QDialog(parent)
    dialog.setWindowTitle(f"{proceed_label} model?")
    dialog.setMinimumWidth(420)
    layout = QVBoxLayout(dialog)
    layout.setContentsMargins(20, 16, 20, 16)
    layout.setSpacing(14)

    message = QLabel(body_html)
    message.setWordWrap(True)
    message.setTextFormat(Qt.TextFormat.RichText)
    message.setOpenExternalLinks(True)
    message.setTextInteractionFlags(
        Qt.TextInteractionFlag.TextBrowserInteraction
    )
    layout.addWidget(message)

    btn_row = QHBoxLayout()
    btn_row.addStretch()
    cancel_btn = QPushButton("Cancel")
    cancel_btn.setDefault(True)
    cancel_btn.clicked.connect(dialog.reject)
    btn_row.addWidget(cancel_btn)
    proceed_btn = QPushButton(proceed_label)
    proceed_btn.clicked.connect(dialog.accept)
    btn_row.addWidget(proceed_btn)
    btn_row.addStretch()
    layout.addLayout(btn_row)

    return dialog.exec() == QDialog.DialogCode.Accepted


_COPY_SCRIPT_BTN_ICON_PX = 18


class _CopyScriptButton(QPushButton):
    """Clipboard copy control using copy.png / copy_hover.png."""

    def __init__(self, parent=None):
        super().__init__("", parent)
        self.setObjectName("modelDownloadCopyBtn")
        self.setToolTip("Copy script to clipboard")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setAttribute(Qt.WidgetAttribute.WA_Hover, True)
        self.setFixedSize(34, 34)
        self.setIconSize(QSize(_COPY_SCRIPT_BTN_ICON_PX, _COPY_SCRIPT_BTN_ICON_PX))
        normal, hover = icon_pair_from_assets("copy.png", "copy_hover.png")
        attach_icon_hover_swap(self, normal, hover)
        th = get_active_theme()
        self._normal_style = (
            f"QPushButton#modelDownloadCopyBtn {{"
            f" border: 1px solid {BORDER_DEFAULT_HEX};"
            f" border-radius: 6px;"
            f" padding: 0;"
            f" background: {BUTTON_BG_DEFAULT_HEX};"
            f"}}"
        )
        self._hover_style = (
            f"QPushButton#modelDownloadCopyBtn {{"
            f" border: 1px solid {BUTTON_TEXT_HOVER_HEX};"
            f" border-radius: 6px;"
            f" padding: 0;"
            f" background: {BUTTON_BG_DEFAULT_HEX};"
            f"}}"
        )
        self.setStyleSheet(self._normal_style)
        self.installEventFilter(self)

    def eventFilter(self, obj, event):
        if obj is self:
            if event.type() == QEvent.Type.Enter:
                self.setStyleSheet(self._hover_style)
            elif event.type() == QEvent.Type.Leave:
                self.setStyleSheet(self._normal_style)
        return super().eventFilter(obj, event)


class _ModelListButton(QFrame):
    """One selectable model row: title + up to two description lines."""

    def __init__(
        self,
        entry: ModelDownloadCatalogEntry,
        *,
        on_clicked,
        parent=None,
    ):
        super().__init__(parent)
        self._entry = entry
        self.setObjectName("modelDownloadListRow")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        th = get_active_theme()
        self.setStyleSheet(
            f"""
            QFrame#modelDownloadListRow {{
                background: {BUTTON_BG_DEFAULT_HEX};
                border: 1px solid {BORDER_DEFAULT_HEX};
                border-radius: 8px;
            }}
            QFrame#modelDownloadListRow:hover {{
                border: 1px solid {th.button_border_hover_hex};
            }}
            """
        )

        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 10, 12, 10)
        layout.setSpacing(2)

        title_row = QHBoxLayout()
        title_row.setSpacing(8)

        title = QLabel(entry.display_name)
        title_font = QFont()
        title_font.setBold(True)
        title_font.setPointSize(13)
        title.setFont(title_font)
        title.setStyleSheet(f"color: {DIALOG_TEXT_COLOR_HEX};")
        title_row.addWidget(title, stretch=1)

        installed = model_is_installed(entry)
        status_text = "Installed" if installed else "Not installed"
        size_text = format_download_size_estimate(entry.repo_id)
        status = QLabel(f"{status_text} · {size_text}")
        status.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        status_color = (
            VALIDATION_SUCCESS_COLOR_HEX if installed else th.information_action_icon_muted_hex
        )
        status.setStyleSheet(f"color: {status_color}; font-size: 12px;")
        title_row.addWidget(status)
        layout.addLayout(title_row)

        for line in entry.description_lines[:2]:
            desc = QLabel(line)
            desc.setWordWrap(True)
            if line.startswith("Used by:"):
                desc.setTextFormat(Qt.TextFormat.RichText)
            desc.setStyleSheet(
                f"color: {th.information_action_icon_muted_hex}; font-size: 12px;"
            )
            layout.addWidget(desc)

        self._on_clicked = on_clicked

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._on_clicked(self._entry)
            event.accept()
            return
        super().mouseReleaseEvent(event)


class DownloadModelsListDialog(QDialog):
    """Scrollable list of plugin models for Tools > Manage models."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Manage models")
        self.setMinimumSize(520, 420)
        self.resize(640, 560)
        self.setStyleSheet(get_dialog_shell_stylesheet() + get_button_style())
        self._config = (
            parent.config if (parent and hasattr(parent, "config")) else get_config()
        )
        self._entries = build_model_download_catalog()
        self._list_layout: Optional[QVBoxLayout] = None
        self._setup_ui()
        self.finished.connect(self._save_geometry)

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        host = QWidget()
        self._list_layout = QVBoxLayout(host)
        self._list_layout.setContentsMargins(0, 0, 0, 0)
        self._list_layout.setSpacing(8)

        scroll.setWidget(host)
        layout.addWidget(scroll, stretch=1)

        self._refresh_list()

        btn_row = QHBoxLayout()
        btn_row.addStretch()
        close_btn = QPushButton("Close")
        close_btn.setDefault(True)
        close_btn.clicked.connect(self.accept)
        btn_row.addWidget(close_btn)
        btn_row.addStretch()
        layout.addLayout(btn_row)

    def _refresh_list(self) -> None:
        if self._list_layout is None:
            return
        while self._list_layout.count():
            item = self._list_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

        self._entries = build_model_download_catalog()
        if not self._entries:
            empty = QLabel("No downloadable models are registered in imagegen_plugins.")
            empty.setWordWrap(True)
            self._list_layout.addWidget(empty)
        else:
            for entry in self._entries:
                self._list_layout.addWidget(
                    _ModelListButton(entry, on_clicked=self._open_detail)
                )
        self._list_layout.addStretch()

    def _open_detail(self, entry: ModelDownloadCatalogEntry) -> None:
        dialog = ModelDownloadDetailDialog(entry, parent=self)
        dialog.exec()
        self._refresh_list()

    def _save_geometry(self) -> None:
        try:
            self._config.update_setting(
                _LIST_GEOMETRY_KEY, self.saveGeometry().data().hex()
            )
        except Exception:
            pass

    def showEvent(self, event) -> None:
        super().showEvent(event)
        try:
            geom_hex = self._config.load_settings().get(_LIST_GEOMETRY_KEY)
            if geom_hex:
                self.restoreGeometry(QByteArray(bytes.fromhex(geom_hex)))
                ensure_dialog_fits_screen(self, self.parent())
        except Exception:
            pass


class ModelDownloadDetailDialog(QDialog):
    """Per-model install panel or installed/delete view."""

    def __init__(self, entry: ModelDownloadCatalogEntry, parent=None):
        super().__init__(parent)
        self._entry = entry
        self.setWindowTitle(entry.display_name)
        self.setMinimumSize(480, 280)
        self.resize(560, 360)
        self.setStyleSheet(get_dialog_shell_stylesheet() + get_button_style())
        self._config = (
            parent.config if (parent and hasattr(parent, "config")) else get_config()
        )
        self._script_panel: Optional[QWidget] = None
        self._script_edit: Optional[QPlainTextEdit] = None
        self._hf_token_edit: Optional[QLineEdit] = None
        self.model_uninstalled = False
        self._setup_ui()
        self.finished.connect(self._save_geometry)

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)

        repo_label = QLabel(f"Repository: {self._entry.repo_id}")
        repo_label.setWordWrap(True)
        repo_label.setStyleSheet(
            f"color: {get_active_theme().information_action_icon_muted_hex};"
            " font-family: Menlo, Monaco, monospace; font-size: 12px;"
        )
        layout.addWidget(repo_label)

        if model_is_installed(self._entry):
            self._build_installed_panel(layout)
        else:
            self._build_install_panel(layout)

        layout.addStretch()

        btn_row = QHBoxLayout()
        btn_row.addStretch()
        close_btn = QPushButton("Close")
        close_btn.setDefault(True)
        close_btn.clicked.connect(self.accept)
        btn_row.addWidget(close_btn)
        btn_row.addStretch()
        layout.addLayout(btn_row)

    def _add_hf_token_row(self, layout: QVBoxLayout) -> None:
        token_row = QHBoxLayout()
        token_row.addWidget(QLabel("HF token:"))
        self._hf_token_edit = QLineEdit()
        self._hf_token_edit.setEchoMode(QLineEdit.EchoMode.Password)
        if os.environ.get("HF_TOKEN", "").strip():
            self._hf_token_edit.setPlaceholderText("(HF_TOKEN is set in environment)")
        else:
            self._hf_token_edit.setPlaceholderText("Optional if already logged in")
        self._hf_token_edit.setClearButtonEnabled(True)
        token_row.addWidget(self._hf_token_edit, stretch=1)
        layout.addLayout(token_row)

    def _build_installed_panel(self, layout: QVBoxLayout) -> None:
        status = QLabel("This model is installed on your machine.")
        status.setWordWrap(True)
        status.setStyleSheet(
            f"color: {VALIDATION_SUCCESS_COLOR_HEX}; font-size: 14px; font-weight: bold;"
        )
        layout.addWidget(status)

        if self._entry.gated:
            gated = QLabel(
                "Gated model — accept the license on Hugging Face and provide a token "
                "to reinstall."
            )
            gated.setWordWrap(True)
            gated.setStyleSheet(
                f"color: {get_active_theme().tree_folder_with_images_hex}; font-size: 12px;"
            )
            layout.addWidget(gated)
            self._add_hf_token_row(layout)

        btn_row = QHBoxLayout()
        btn_row.setSpacing(8)

        reinstall_btn = QPushButton("Reinstall…")
        reinstall_btn.setToolTip("Re-download all files (--force-download)")
        reinstall_btn.clicked.connect(self._on_reinstall)
        btn_row.addWidget(reinstall_btn)

        delete_btn = QPushButton("Delete model…")
        delete_btn.clicked.connect(self._on_delete)
        btn_row.addWidget(delete_btn)

        btn_row.addStretch()
        layout.addLayout(btn_row)

    def _build_install_panel(self, layout: QVBoxLayout) -> None:
        size_text = format_download_size_estimate(self._entry.repo_id)
        size_label = QLabel(f"Estimated download size: {size_text}")
        size_label.setStyleSheet(f"color: {DIALOG_TEXT_COLOR_HEX}; font-size: 13px;")
        layout.addWidget(size_label)

        if self._entry.gated:
            gated = QLabel(
                "Gated model — accept the license on Hugging Face and provide a token."
            )
            gated.setWordWrap(True)
            gated.setStyleSheet(
                f"color: {get_active_theme().tree_folder_with_images_hex}; font-size: 12px;"
            )
            layout.addWidget(gated)

        self._add_hf_token_row(layout)

        btn_row = QHBoxLayout()
        btn_row.setSpacing(8)

        download_btn = QPushButton("Download")
        download_btn.clicked.connect(
            lambda: self._start_download(force=False, proceed_label="Download")
        )
        btn_row.addWidget(download_btn)

        full_btn = QPushButton("Full download")
        full_btn.setToolTip("Re-download all files (--force-download)")
        full_btn.clicked.connect(
            lambda: self._start_download(force=True, proceed_label="Full download")
        )
        btn_row.addWidget(full_btn)

        script_btn = QPushButton("Script")
        script_btn.clicked.connect(self._toggle_script_panel)
        btn_row.addWidget(script_btn)

        cancel_btn = QPushButton("Cancel")
        cancel_btn.clicked.connect(self.reject)
        btn_row.addWidget(cancel_btn)

        btn_row.addStretch()
        layout.addLayout(btn_row)

        self._script_panel = QWidget()
        script_layout = QVBoxLayout(self._script_panel)
        script_layout.setContentsMargins(0, 0, 0, 0)
        script_layout.setSpacing(6)

        script_row = QHBoxLayout()
        self._script_edit = QPlainTextEdit()
        self._script_edit.setReadOnly(True)
        self._script_edit.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self._script_edit.setPlainText(self._current_script_text())
        self._script_edit.setStyleSheet(
            """
            QPlainTextEdit {
                border-radius: 6px;
                padding: 8px 10px;
                font-family: Menlo, Monaco, "Courier New", monospace;
                font-size: 12px;
            }
            """
        )
        script_row.addWidget(self._script_edit, stretch=1)

        self._copy_btn = _CopyScriptButton()
        self._copy_btn.clicked.connect(self._copy_script)
        script_row.addWidget(self._copy_btn, alignment=Qt.AlignmentFlag.AlignTop)
        script_layout.addLayout(script_row)
        self._script_panel.hide()
        layout.addWidget(self._script_panel)

    def _token_value(self) -> str:
        if self._hf_token_edit is None:
            return os.environ.get("HF_TOKEN", "").strip()
        typed = self._hf_token_edit.text().strip()
        if typed:
            return typed
        return os.environ.get("HF_TOKEN", "").strip()

    def _current_script_text(self, *, force_download: bool = False) -> str:
        return build_single_model_download_script(
            self._entry.repo_id,
            hf_token=self._token_value() or None,
            force_download=force_download,
        )

    def _toggle_script_panel(self) -> None:
        if self._script_panel is None or self._script_edit is None:
            return
        visible = not self._script_panel.isVisible()
        if visible:
            self._script_edit.setPlainText(self._current_script_text())
        self._script_panel.setVisible(visible)

    def _copy_script(self) -> None:
        if self._script_edit is None:
            return
        from copy_feedback import copy_text_to_clipboard

        copy_text_to_clipboard(
            self._script_edit.toPlainText(),
            anchor=self._script_edit,
        )

    def _start_download(
        self,
        *,
        force: bool,
        proceed_label: str,
    ) -> None:
        if not _confirm_model_download(
            self,
            self._entry,
            proceed_label=proceed_label,
            force_download=force,
        ):
            return

        token = self._token_value()
        if self._entry.gated and not token:
            show_styled_warning(
                self,
                "HF token required",
                "This gated model needs a Hugging Face token. "
                "Enter one in the HF token field or set HF_TOKEN in your environment.",
            )
            return
        try:
            download_model_weights(
                repo_id=self._entry.repo_id,
                pipeline_id=self._entry.pipeline_id,
                parent=self,
                force_download=force,
                hf_token=token or None,
                display_name=self._entry.display_name,
            )
        except ModelDownloadCancelled:
            return
        except Exception as e:
            show_styled_critical(
                self,
                "Download failed",
                str(e)[:4000],
            )
            return
        show_styled_information(
            self,
            "Download complete",
            f"{self._entry.display_name} was downloaded to your Hugging Face cache.",
        )
        self.accept()

    def _on_reinstall(self) -> None:
        self._start_download(force=True, proceed_label="Reinstall")

    def _on_delete(self) -> None:
        from PySide6.QtWidgets import QMessageBox

        entry = self._entry
        size = format_download_size_estimate(entry.repo_id)
        first = show_styled_question(
            self,
            "Delete model?",
            f"Delete {entry.display_name} from your Hugging Face cache?\n\n"
            f"This frees about {size} of disk space.",
            default_no=True,
        )
        if first != QMessageBox.StandardButton.Yes:
            return

        second = show_styled_question(
            self,
            "Confirm delete",
            f"Are you sure you want to permanently delete {entry.display_name}? "
            "You will need to download it again to use it.",
            default_no=True,
        )
        if second != QMessageBox.StandardButton.Yes:
            return

        if not delete_model_from_hf_cache(entry.repo_id):
            show_styled_warning(
                self,
                "Delete failed",
                f"No cached files were found for {entry.repo_id}.",
            )
            return

        show_styled_information(
            self,
            "Model deleted",
            f"{entry.display_name} was removed from the Hugging Face cache.",
        )
        self.model_uninstalled = True
        self.accept()

    def _save_geometry(self) -> None:
        try:
            self._config.update_setting(
                _DETAIL_GEOMETRY_KEY, self.saveGeometry().data().hex()
            )
        except Exception:
            pass

    def showEvent(self, event) -> None:
        super().showEvent(event)
        try:
            geom_hex = self._config.load_settings().get(_DETAIL_GEOMETRY_KEY)
            if geom_hex:
                self.restoreGeometry(QByteArray(bytes.fromhex(geom_hex)))
                ensure_dialog_fits_screen(self, self.parent())
        except Exception:
            pass


def run_download_models_dialog(parent=None) -> None:
    """Tools > Manage models."""
    dialog = DownloadModelsListDialog(parent)
    dialog.show()
