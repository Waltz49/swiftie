#!/usr/bin/env python3
"""Headless subset of monorepo ``utils.py`` for the Swift ImageGenPython bundle.

Full ``utils.py`` depends on PySide6; LoRA import/validation only needs path helpers here.
"""

from __future__ import annotations

import os


def display_to_path(display_path: str) -> str:
    """Expand ``~`` and normalize a path entered in the UI."""
    if not display_path:
        return display_path
    display_path = display_path.strip()
    if not display_path:
        return display_path
    return os.path.expanduser(display_path)


def normalize_path_for_display(path: str) -> str:
    """Show ``~/…`` instead of the full home path when applicable."""
    if not path:
        return path
    text = str(path).strip()
    if not text:
        return text
    home = os.path.expanduser("~")
    if text.startswith(home + os.sep):
        return "~" + text[len(home) :]
    if text == home:
        return "~"
    return text
