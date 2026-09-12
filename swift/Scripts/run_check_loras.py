#!/usr/bin/env python3
"""Headless Check LoRAs runner for Swift Tools → Debug menu."""

from __future__ import annotations

import json
import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)


def main() -> int:
    from imagegen_plugins.lora_compatibility_checker import (
        check_loras_options_from_settings,
        run_lora_compatibility_check,
    )
    from config import get_config

    config = get_config()
    settings = config.load_settings()
    options = check_loras_options_from_settings(settings)
    result = run_lora_compatibility_check(options, progress_callback=None)
    summary = {
        "passed": getattr(result, "passed_count", 0),
        "failed": getattr(result, "failed_count", 0),
        "skipped": getattr(result, "skipped_count", 0),
    }
    print(json.dumps(summary), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
