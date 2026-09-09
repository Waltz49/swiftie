#!/usr/bin/env python3
"""
Delete EXIF User Comment Dialog
Shows a warning dialog with files that will have their EXIF UserComment permanently deleted
"""

from typing import List, Optional, Tuple

from PySide6.QtWidgets import QDialog

from browser_window.dialogs.file_list_confirmation_dialog import (
    FileListConfirmationDialog,
    escape_html_text,
)
from exif.exif_utils import truncate_usercomment_before_prompt
from theme.theme_service import get_active_theme
from utils import file_string

_COMMENT_PREVIEW_MAX_LEN = 200


class DeleteUserCommentDialog(FileListConfirmationDialog):
    """Dialog showing warning for files that will have EXIF UserComment permanently deleted"""

    def __init__(self, files_to_delete: List[Tuple[str, Optional[str]]], parent=None):
        th = get_active_theme()
        error_color = th.error_color_hex
        count = len(files_to_delete)

        warning_text = (
            f"⚠️ WARNING: EXIF user comment data will be PERMANENTLY DELETED from "
            f"{count} {file_string(count)}.\n\n"
            f"This action CANNOT be undone. The EXIF user comment will be "
            f"completely removed from these files."
        )
        info_text = (
            f"The following {count} {file_string(count)} will have their EXIF "
            f"user comment deleted:"
        )

        super().__init__(
            title="Delete User Comment",
            info_text=info_text,
            parent=parent,
            warning_text=warning_text,
            warning_style=f"color: {error_color}; font-weight: normal; font-size: 14px;",
            ok_text="Delete",
        )
        self.files_to_delete = files_to_delete
        self.set_html_content(self._build_html())

    def _build_html(self) -> str:
        entries = []
        for file_path, comment_text in self.files_to_delete:
            path_escaped = escape_html_text(file_path)
            block = f"<div>{path_escaped}</div>"
            if comment_text is not None and comment_text.strip():
                preview = truncate_usercomment_before_prompt(comment_text).replace("\n", " ").strip()
                if len(preview) > _COMMENT_PREVIEW_MAX_LEN:
                    preview = preview[:_COMMENT_PREVIEW_MAX_LEN] + "..."
                block += f"<div>{escape_html_text(preview)}</div>"
            entries.append(block)
        return "<br>".join(entries)

    @staticmethod
    def show_confirmation(files_to_delete: List[Tuple[str, Optional[str]]], parent=None) -> bool:
        if not files_to_delete:
            return False
        dialog = DeleteUserCommentDialog(files_to_delete, parent)
        return dialog.exec() == QDialog.Accepted
