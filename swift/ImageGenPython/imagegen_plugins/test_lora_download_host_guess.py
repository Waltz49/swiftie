#!/usr/bin/env python3
"""Unit tests for Downloads LoRA host inference (Check LoRAs)."""

from __future__ import annotations

import unittest
from pathlib import Path

from imagegen_plugins.hf_model_ids import (
    FLUX1_DEV,
    FLUX2_KLEIN_4B,
    FLUX2_KLEIN_9B_KV,
    SD15_BASE_V1_5,
)
from imagegen_plugins.lora_download_host_guess import (
    classify_lora_host_from_hints,
    guess_host_and_base_model_for_download,
)
from imagegen_plugins.lora_host_registry import (
    HOST_FLUX1_T2I,
    HOST_FLUX2_KLEIN,
    HOST_SD15,
)


class ClassifyLoraHostFromHintsTests(unittest.TestCase):
    def test_flux2_klein_9b_metadata_and_k9b_filename(self) -> None:
        hints = ("flux2_klein_9b", "RealRubber_v2_K9B_000001008")
        host, base = classify_lora_host_from_hints(hints)
        self.assertEqual(host, HOST_FLUX2_KLEIN)
        self.assertEqual(base, FLUX2_KLEIN_9B_KV)

    def test_flux2_klein_4b(self) -> None:
        host, base = classify_lora_host_from_hints(
            ("flux2_klein_4b", "vintage_book_cover_4b")
        )
        self.assertEqual(host, HOST_FLUX2_KLEIN)
        self.assertEqual(base, FLUX2_KLEIN_4B)

    def test_sd15(self) -> None:
        host, base = classify_lora_host_from_hints(("stable-diffusion-v1-5",))
        self.assertEqual(host, HOST_SD15)
        self.assertEqual(base, SD15_BASE_V1_5)

    def test_defaults_flux1_when_unknown(self) -> None:
        host, base = classify_lora_host_from_hints(("some_random_style",))
        self.assertEqual(host, HOST_FLUX1_T2I)
        self.assertEqual(base, FLUX1_DEV)


class GuessHostForRealFileTests(unittest.TestCase):
    def test_real_rubber_downloads_file_when_present(self) -> None:
        path = Path(
            "/Users/douglasnadel/Downloads/RealRubber_v2_K9B_000001008.safetensors"
        )
        if not path.is_file():
            self.skipTest("RealRubber fixture not on disk")
        host, base = guess_host_and_base_model_for_download(path)
        self.assertEqual(host, HOST_FLUX2_KLEIN)
        self.assertEqual(base, FLUX2_KLEIN_9B_KV)


if __name__ == "__main__":
    unittest.main()