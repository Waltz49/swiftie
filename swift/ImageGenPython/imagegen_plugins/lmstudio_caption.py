#!/usr/bin/env python3
"""
LMStudio integration for AI-generated image captions.

Requires the 'lmstudio' Python SDK (pip install lmstudio) and
LMStudio running on localhost:1234 with a vision-capable model loaded.

Availability is event-driven (probe on dialog open, user AI actions, settings
changes, generation_finished). Do not call probe helpers from UI timers.

Other intentional polling elsewhere (unrelated to LM Studio):
- image_gen_controller._live_status_timer (500ms): local job timing/progress UI
- image_gen_controller._GPU_CLEANUP_POLL_MS (2s): GPU cleanup between copies
- background_clip_controller.status_check_timer: CLIP index build status
- mflux_stepwise_progress worker sleeps: inference step callbacks
- cache_prepopulator 50ms QTimer: cache warm progress dialog
- job_queue_panel / active_job_strip debounce timers: layout reflow only
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Literal, Optional

from config import get_config, CAPTION_DEFAULTS
from imagegen_plugins.ai_prompt_exit import apply_text_ai_exit
from print_call_decorator import log_exception, print_call
from thumbnails.thumbnail_constants import (
    VISION_REQUIRED_MSG,
    lmstudio_exception_implies_vision_required,
)


_CHANNEL_MARKER = '<channel|>'

# Unicode punctuation often emitted by LLMs → ASCII equivalents.
_LMSTUDIO_ASCII_TRANSLATION = str.maketrans({
    '\u2013': '-',   # en dash
    '\u2014': '-',   # em dash
    '\u2018': "'",   # left single quotation mark
    '\u2019': "'",   # right single quotation mark
    '\u201a': "'",   # single low-9 quotation mark
    '\u201b': "'",   # single high-reversed-9 quotation mark
    '\u201c': '"',   # left double quotation mark
    '\u201d': '"',   # right double quotation mark
    '\u201e': '"',   # double low-9 quotation mark
    '\u201f': '"',   # double high-reversed-9 quotation mark
})


def normalize_lmstudio_output_text(text: str) -> str:
    """Replace common Unicode dashes and quotes with ASCII punctuation."""
    if not text:
        return text
    if text.isascii():
        return text
    return text.translate(_LMSTUDIO_ASCII_TRANSLATION)


def _strip_think_tags(text: str) -> str:
    """
    Remove model routing/thinking artifacts from caption text:
    - Content between the first <think (or <think1, <think8, etc.) and the last </think>.
    - Everything before and including the last <channel|> marker.
    If a <think opening tag exists but no </think closing tag follows it, keep the text as-is.
    """
    first_open = text.find('<think')
    if first_open != -1:
        last_close = text.rfind('</think')
        if last_close != -1 and last_close >= first_open:
            end_of_closing = text.find('>', last_close)
            if end_of_closing != -1:
                text = text[:first_open] + text[end_of_closing + 1:]

    channel_pos = text.rfind(_CHANNEL_MARKER)
    if channel_pos != -1:
        text = text[channel_pos + len(_CHANNEL_MARKER):]

    return normalize_lmstudio_output_text(text)


def _get_caption_settings():
    """Load caption settings from config (uses system defaults if not set)."""
    settings = get_config().load_settings()
    return {
        'lms_host': settings.get('caption_lms_host') or CAPTION_DEFAULTS['caption_lms_host'],
        'system_prompt': settings.get('caption_system_prompt') or CAPTION_DEFAULTS['caption_system_prompt'],
        'user_prompt': settings.get('caption_user_prompt') or CAPTION_DEFAULTS['caption_user_prompt'],
        'max_words': settings.get('caption_max_words', CAPTION_DEFAULTS['caption_max_words']),
        'temperature': settings.get('caption_temperature', CAPTION_DEFAULTS['caption_temperature']),
    }


def _get_last_lm_model_key() -> Optional[str]:
    settings = get_config().load_settings()
    key = (settings.get("caption_last_lm_model_key") or "").strip()
    if not key:
        key = (CAPTION_DEFAULTS.get("caption_last_lm_model_key") or "").strip()
    return key or None


def _persist_last_lm_model_key(model_key: str) -> None:
    model_key = (model_key or "").strip()
    if not model_key:
        return
    if _get_last_lm_model_key() == model_key:
        return
    get_config().update_setting("caption_last_lm_model_key", model_key)


def _model_key_from_handle(model) -> Optional[str]:
    try:
        info = model.get_info()
        return (getattr(info, "model_key", None) or "").strip() or None
    except Exception:
        return None


def _loaded_model_supports_vision(model) -> bool | None:
    """Return True/False from LM Studio model info, or None if unknown."""
    try:
        info = model.get_info()
    except Exception:
        return None
    if info is None:
        return None
    vision = getattr(info, "vision", None)
    if vision is None:
        return None
    return bool(vision)


def _require_vision_capable_model(model) -> None:
    """Raise RuntimeError when the loaded LLM cannot accept images."""
    supports = _loaded_model_supports_vision(model)
    if supports is not False:
        return
    display_name = ""
    try:
        info = model.get_info()
        display_name = (getattr(info, "display_name", None) or "").strip()
    except Exception:
        pass
    if display_name:
        raise RuntimeError(f"{VISION_REQUIRED_MSG}\n\nLoaded model: {display_name}")
    raise RuntimeError(VISION_REQUIRED_MSG)


def _remember_loaded_lm_model_keys(client) -> None:
    """Persist modelKey of the first loaded LLM (used before unload / after caption)."""
    try:
        for model in client.llm.list_loaded():
            key = _model_key_from_handle(model)
            if key:
                _persist_last_lm_model_key(key)
                return
    except Exception:
        pass


def _ensure_caption_model(client):
    """Return a loaded LLM handle, reloading the last persisted model if needed."""
    loaded_models = client.llm.list_loaded()
    if loaded_models:
        model = loaded_models[0]
        key = _model_key_from_handle(model)
        if key:
            _persist_last_lm_model_key(key)
        mark_lmstudio_available()
        return model

    saved_key = _get_last_lm_model_key()
    if not saved_key:
        raise RuntimeError(
            "No model is currently loaded in LMStudio.\n\n"
            "Please load a vision-capable model (VLM) before using AI captioning."
        )
    try:
        model = client.llm.model(saved_key)
    except Exception as e:
        raise RuntimeError(
            f"Could not reload the last LM Studio caption model.\n\n"
            f"Saved model: {saved_key}\n\nDetail: {e}"
        ) from e
    _persist_last_lm_model_key(saved_key)
    mark_lmstudio_available()
    return model



def unload_all_lmstudio_models() -> None:
    """Unload every LLM currently loaded in the LM Studio server (frees RAM for image models)."""
    mark_lmstudio_unavailable(reason="image_gen_unload")
    try:
        from chat_plugins.chat_lmstudio_activity import is_chat_lmstudio_prediction_active

        if is_chat_lmstudio_prediction_active():
            print(
                "[lmstudio] skipping model unload while chat prediction is active",
                flush=True,
            )
            return
    except ImportError:
        pass
    try:
        import lmstudio as lms
    except ImportError:
        return
    cap_settings = _get_caption_settings()
    lms_host = cap_settings["lms_host"]
    try:
        if not lms.Client.is_valid_api_host(lms_host):
            return
    except Exception:
        return
    try:
        with lms.Client(lms_host) as client:
            _remember_loaded_lm_model_keys(client)
            for model in list(client.llm.list_loaded()):
                try:
                    ident = getattr(model, "identifier", None) or str(model)
                    client.llm.unload(ident)
                except Exception:
                    try:
                        model.unload()
                    except Exception:
                        pass
    except Exception:
        pass


def is_lmstudio_sdk_installed() -> bool:
    """True when the LM Studio Python SDK is importable and UI is enabled."""
    try:
        from bundle_capabilities import lmstudio_ui_enabled

        if not lmstudio_ui_enabled():
            return False
    except ImportError:
        pass
    try:
        import lmstudio as lms  # noqa: F401
    except ImportError:
        return False
    return True


LmStudioSessionState = Literal["unknown", "unavailable", "available"]

_session_lock = threading.Lock()
_session_state: LmStudioSessionState = "unknown"
_availability_listeners: list[Callable[[], None]] = []


def _set_session_state(state: LmStudioSessionState) -> None:
    global _session_state
    with _session_lock:
        if _session_state == state:
            return
        _session_state = state
    _notify_availability_changed()


def _notify_availability_changed() -> None:
    with _session_lock:
        listeners = list(_availability_listeners)

    def _invoke() -> None:
        for callback in listeners:
            try:
                callback()
            except Exception:
                pass

    try:
        from PySide6.QtCore import QThread, QTimer
        from PySide6.QtWidgets import QApplication

        app = QApplication.instance()
        if app is not None and QThread.currentThread() is not app.thread():
            QTimer.singleShot(0, _invoke)
            return
    except Exception:
        pass
    _invoke()


def register_lmstudio_availability_listener(callback: Callable[[], None]) -> None:
    """Register a callback invoked on the main thread when session state changes."""
    with _session_lock:
        if callback not in _availability_listeners:
            _availability_listeners.append(callback)


def unregister_lmstudio_availability_listener(callback: Callable[[], None]) -> None:
    with _session_lock:
        try:
            _availability_listeners.remove(callback)
        except ValueError:
            pass


def get_lmstudio_session_state() -> LmStudioSessionState:
    with _session_lock:
        return _session_state


def get_lmstudio_ui_available() -> bool:
    """Return cached availability for UI gating; never contacts LM Studio."""
    with _session_lock:
        return _session_state == "available"


def reset_lmstudio_session_state() -> None:
    """Mark state unknown (e.g. after caption host settings change)."""
    _set_session_state("unknown")


def mark_lmstudio_unavailable(*, reason: str = "") -> None:
    """Record that LM Studio is not usable without probing."""
    _set_session_state("unavailable")


def mark_lmstudio_available() -> None:
    """Record successful LM Studio contact / model load."""
    _set_session_state("available")


def invalidate_lmstudio_services_availability_cache() -> None:
    """Legacy alias: mark session unavailable without probing."""
    mark_lmstudio_unavailable(reason="invalidate_cache")


def _network_probe_lmstudio_services_available() -> bool:
    """Return True if LMStudio server is reachable and a model is loaded or remembered."""
    if not is_lmstudio_sdk_installed():
        return False
    import lmstudio as lms

    cap_settings = _get_caption_settings()
    lms_host = cap_settings["lms_host"]
    try:
        if not lms.Client.is_valid_api_host(lms_host):
            return False
    except Exception:
        return False
    try:
        with lms.Client(lms_host) as client:
            if client.llm.list_loaded():
                return True
            return bool(_get_last_lm_model_key())
    except Exception:
        return False


def probe_lmstudio_services(*, reason: str = "") -> bool:
    """Explicit network check; updates session state. Single-flight under _session_lock."""
    with _session_lock:
        result = _network_probe_lmstudio_services_available()
        new_state: LmStudioSessionState = "available" if result else "unavailable"
        global _session_state
        changed = _session_state != new_state
        _session_state = new_state
    if changed:
        _notify_availability_changed()
    return result


def is_lmstudio_services_available(*, force_refresh: bool = False) -> bool:
    """Return cached LM Studio availability; use probe_lmstudio_services() to refresh."""
    if force_refresh:
        return probe_lmstudio_services(reason="force_refresh")
    return get_lmstudio_ui_available()


def get_image_caption_stream(file_path: str, user_prompt_override: str | None = None):
    """
    Generator that yields text chunks as they stream from LMStudio.
    The caller should accumulate chunks and apply _strip_think_tags to the final result.
    Raises RuntimeError for the same cases as get_image_caption.
    """
    try:
        import lmstudio as lms
    except ImportError:
        raise RuntimeError(
            "The LMStudio Python SDK is not installed.\n\n"
            "Install it with:  pip install lmstudio"
        )

    cap_settings = _get_caption_settings()
    lms_host = cap_settings['lms_host']

    try:
        available = lms.Client.is_valid_api_host(lms_host)
    except Exception as e:
        mark_lmstudio_unavailable(reason="caption_host_check_failed")
        raise RuntimeError(
            f"Could not contact LMStudio server at {lms_host}.\n\nDetail: {e}"
        )

    if not available:
        mark_lmstudio_unavailable(reason="caption_host_invalid")
        raise RuntimeError(
            f"LMStudio server is not running at {lms_host}.\n\n"
            "Please start LMStudio and enable the local API server."
        )

    with lms.Client(lms_host) as client:
        try:
            model = _ensure_caption_model(client)
        except RuntimeError:
            mark_lmstudio_unavailable(reason="caption_no_model")
            raise
        except Exception as e:
            mark_lmstudio_unavailable(reason="caption_model_load_failed")
            raise RuntimeError(
                f"Could not retrieve or load a model from LMStudio.\n\nDetail: {e}"
            )

        mark_lmstudio_available()

        _require_vision_capable_model(model)

        word_count = cap_settings['max_words']
        system_prompt = cap_settings['system_prompt'].format(CAPTION_WORD_COUNT=word_count)
        if user_prompt_override and user_prompt_override.strip():
            user_prompt = user_prompt_override.strip()
        else:
            user_prompt = cap_settings['user_prompt'].format(CAPTION_WORD_COUNT=word_count)
        temperature = cap_settings['temperature']
        system_prompt = apply_text_ai_exit(system_prompt)
        user_prompt = apply_text_ai_exit(user_prompt)

        from model_debug_log import log_model_input

        log_model_input(
            "imagegen_plugins.lmstudio_caption",
            {
                "system_prompt": system_prompt,
                "user_prompt": user_prompt,
                "image_path": file_path,
                "config": {"temperature": temperature},
            },
        )

        try:
            image_handle = client.files.prepare_image(file_path)
        except Exception as e:
            raise RuntimeError(
                f"Could not prepare image for the model.\n\nDetail: {e}"
            )

        chat = lms.Chat(system_prompt)
        chat.add_user_message(user_prompt, images=[image_handle])

        try:
            respond_stream = print_call(model.respond_stream, wrap=True)
            prediction_stream = respond_stream(
                chat,
                config={"temperature": temperature},
            )
            for fragment in prediction_stream:
                yield fragment.content
        except Exception as e:
            log_exception(e)
            if lmstudio_exception_implies_vision_required(e):
                raise RuntimeError(VISION_REQUIRED_MSG) from e
            raise RuntimeError(f"Caption generation failed.\n\nDetail: {e}") from e
