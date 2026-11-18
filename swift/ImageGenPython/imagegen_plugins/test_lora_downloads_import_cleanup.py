#!/usr/bin/env python3
"""Unit tests for Downloads cleanup after Test LoRAs import."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from imagegen_plugins.lora_compatibility_checker import (
    DOWNLOADS_LORA_DIR,
    _remove_downloads_source_after_import,
)


class RemoveDownloadsSourceAfterImportTests(unittest.TestCase):
    def test_removes_matching_top_level_download(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            downloads = Path(tmp) / "Downloads"
            downloads.mkdir()
            src = downloads / "lora.safetensors"
            dest = Path(tmp) / "cache" / "user" / "id" / "lora.safetensors"
            dest.parent.mkdir(parents=True)
            payload = b"x" * 2048
            src.write_bytes(payload)
            dest.write_bytes(payload)
            original_downloads = DOWNLOADS_LORA_DIR
            try:
                import imagegen_plugins.lora_compatibility_checker as checker

                checker.DOWNLOADS_LORA_DIR = downloads
                self.assertTrue(_remove_downloads_source_after_import(src, dest))
            finally:
                checker.DOWNLOADS_LORA_DIR = original_downloads
            self.assertFalse(src.exists())
            self.assertTrue(dest.exists())

    def test_refuses_wrong_parent_or_size_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / "nested" / "lora.safetensors"
            src.parent.mkdir()
            dest = root / "dest.safetensors"
            src.write_bytes(b"a" * 2048)
            dest.write_bytes(b"b" * 2048)
            self.assertFalse(_remove_downloads_source_after_import(src, dest))
            self.assertTrue(src.exists())


if __name__ == "__main__":
    unittest.main()