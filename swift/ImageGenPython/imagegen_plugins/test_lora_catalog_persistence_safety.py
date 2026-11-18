#!/usr/bin/env python3
"""Guarantees for Test LoRAs / save_lora_catalog_state (no association wipe)."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch

from imagegen_plugins.image_gen_persistence import _merge_nonempty_lora_model_list
from imagegen_plugins.lora_model_registry import entry_matches_lora_model
from imagegen_plugins.lora_user_entries import FluxLoraEntry


class TestMergeNonemptyModelList(unittest.TestCase):
    def test_empty_incoming_keeps_prev(self):
        prev = ["Tongyi-MAI/Z-Image-Turbo"]
        self.assertEqual(_merge_nonempty_lora_model_list(prev, []), prev)

    def test_nonempty_incoming_replaces(self):
        prev = ["black-forest-labs/FLUX.1-dev"]
        inc = ["black-forest-labs/FLUX.1-schnell"]
        self.assertEqual(_merge_nonempty_lora_model_list(prev, inc), inc)


class TestApplyLoraCheckCancelled(unittest.TestCase):
    def test_cancelled_skips_persist(self) -> None:
        from imagegen_plugins.check_loras_debug import apply_lora_check_result
        from imagegen_plugins.lora_compatibility_checker import LoraCheckResult

        result = LoraCheckResult()
        result.cancelled = True
        result.model_support = {"user_antiplastic": []}

        with patch("imagegen_plugins.check_loras_debug.persist_lora_check_catalog_slice") as mock:
            with patch("imagegen_plugins.check_loras_debug.write_check_loras_report", return_value=Path("/tmp/x.txt")):
                apply_lora_check_result(result)
        mock.assert_not_called()


class TestEntryMatchesUserLora(unittest.TestCase):
    def test_user_lora_same_host_matches_settings_model(self) -> None:
        entry = FluxLoraEntry(
            host_id="z_image_turbo",
            lora_id="user_antiplastic",
            display_name="AntiPlastic",
            repo_id="",
            filename="",
            scale=1.0,
            best_guess=1.0,
            local_path="/tmp/x.safetensors",
            base_hf_model_id="filipstrand/Z-Image-Turbo-mflux-4bit",
        )
        self.assertTrue(
            entry_matches_lora_model(
                entry,
                "Tongyi-MAI/Z-Image-Turbo",
                model_support={},
            )
        )


if __name__ == "__main__":
    unittest.main()