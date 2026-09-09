"""Shared helpers for slideshow key 0/9 preset config."""

from __future__ import annotations

from copy import deepcopy
from typing import Any, Dict

DEFAULT_SLIDESHOW_PRESET_0: Dict[str, Any] = {
    'name': 'Slow',
    'rate': 3500,
    'transition_speed': 2000,
    'max_rotation': 90,
    'overlap_delay': 0,
    'direction': 'random',
}

DEFAULT_SLIDESHOW_PRESET_9: Dict[str, Any] = {
    'name': 'Fast',
    'rate': 3500,
    'transition_speed': 1200,
    'max_rotation': 0,
    'overlap_delay': 0,
    'direction': 'none',
}

SLIDESHOW_PRESET_DEFAULTS = {
    '0': DEFAULT_SLIDESHOW_PRESET_0,
    '9': DEFAULT_SLIDESHOW_PRESET_9,
}

SLIDESHOW_PRESET_CONFIG_KEYS = {
    '0': 'slideshow_preset_0',
    '9': 'slideshow_preset_9',
}

VALID_SLIDESHOW_DIRECTIONS = ('right', 'left', 'top', 'bottom', 'random', 'none')


def calculate_overlap_delay(overlap_percent: int, transition_speed: int) -> int:
    """Convert overlap percentage to delay (matches settings dialog math)."""
    try:
        return int((100 - overlap_percent) * transition_speed / 100)
    except Exception:
        return 0


def calculate_overlap_percent(overlap_delay: int, transition_speed: int) -> int:
    """Convert overlap delay to percentage (matches settings dialog math)."""
    try:
        return int(100 - (overlap_delay / transition_speed * 100))
    except Exception:
        return 100


def normalize_slideshow_preset(
    preset: Any,
    preset_key: str,
) -> Dict[str, Any]:
    """Merge a partial preset dict with defaults for key '0' or '9'."""
    defaults = deepcopy(SLIDESHOW_PRESET_DEFAULTS[preset_key])
    if not isinstance(preset, dict):
        return defaults

    name = preset.get('name')
    if isinstance(name, str) and name.strip():
        defaults['name'] = name.strip()

    for field in ('rate', 'transition_speed', 'max_rotation', 'overlap_delay'):
        value = preset.get(field)
        if isinstance(value, (int, float)):
            defaults[field] = int(value)

    direction = preset.get('direction')
    if isinstance(direction, str) and direction in VALID_SLIDESHOW_DIRECTIONS:
        defaults['direction'] = direction

    return defaults


def get_slideshow_preset_from_settings(settings: dict, preset_key: str) -> Dict[str, Any]:
    """Load and normalize a preset from a settings dict."""
    config_key = SLIDESHOW_PRESET_CONFIG_KEYS[preset_key]
    return normalize_slideshow_preset(settings.get(config_key), preset_key)


def preset_overlap_percent(preset: Dict[str, Any]) -> int:
    """Return overlap percent for display from a normalized preset."""
    return calculate_overlap_percent(
        preset.get('overlap_delay', 0),
        preset.get('transition_speed', 1300),
    )


def preset_status_message(preset: Dict[str, Any]) -> str:
    """Build status notification text when a preset is applied."""
    overlap_percent = preset_overlap_percent(preset)
    name = preset.get('name') or 'Preset'
    return (
        f"{name}: {preset['rate']}ms slides, {preset['transition_speed']}ms transitions, "
        f"{preset['max_rotation']}° rotation, {overlap_percent}% overlap, "
        f"direction: {preset['direction']}"
    )
