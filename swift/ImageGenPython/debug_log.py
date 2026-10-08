#!/usr/bin/env python3
"""Shared timestamp prefix for debug-mode print lines (View log)."""

from __future__ import annotations

from datetime import datetime


def debug_timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
