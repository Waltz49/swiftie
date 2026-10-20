"""Worker helpers for vendored pipeline scripts and the persistent imagegen worker."""
from __future__ import annotations

import ctypes
import ctypes.util
import gc
import json
import os
import sys
import queue
import threading
import time
import traceback
from typing import Any, Callable, Dict, Optional

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

_APPLIED = False
_MFLUX_TQDM_SHIM_APPLIED = False
_MFLUX_LORA_QUIET_APPLIED = False
_generation_cancel = threading.Event()
_perf_debug = False
_active_emit: Optional[Callable[[Dict[str, Any]], None]] = None
_active_job_id: Optional[str] = None
_LOADED_KIND: Optional[str] = None
_SHUTDOWN = object()


class GenerationCancelledError(RuntimeError):
    """Raised when the UI requests stop during an in-flight diffusion job."""


def request_generation_cancel() -> None:
    _generation_cancel.set()


def clear_generation_cancel() -> None:
    _generation_cancel.clear()


def generation_cancel_requested() -> bool:
    return _generation_cancel.is_set()


def abort_if_generation_cancelled() -> None:
    if generation_cancel_requested():
        raise GenerationCancelledError("Cancelled")


class _MfluxTimeSteps:
    __slots__ = ("_iter", "_start", "format_dict", "n")

    def __init__(self, start: int, stop: int) -> None:
        self._iter = range(start, stop)
        self._start = time.perf_counter()
        self.format_dict = {"elapsed": 0.0}
        self.n = max(0, stop - start)

    def __iter__(self):
        for t in self._iter:
            if generation_cancel_requested():
                raise GenerationCancelledError("Cancelled")
            self.format_dict["elapsed"] = time.perf_counter() - self._start
            yield t
        self.format_dict["elapsed"] = time.perf_counter() - self._start

    def __len__(self) -> int:
        return self.n


def apply_mflux_worker_tqdm_shim() -> None:
    global _MFLUX_TQDM_SHIM_APPLIED
    if _MFLUX_TQDM_SHIM_APPLIED:
        return
    try:
        from mflux.models.common.config.config import Config
    except ImportError:
        return
    _MFLUX_TQDM_SHIM_APPLIED = True

    def _time_steps_fget(self):
        if self._time_steps is None:
            self._time_steps = _MfluxTimeSteps(
                self.init_time_step,
                self.num_inference_steps,
            )
        return self._time_steps

    Config.time_steps = property(_time_steps_fget)


def apply_mflux_worker_lora_quiet_shim() -> None:
    global _MFLUX_LORA_QUIET_APPLIED
    if _MFLUX_LORA_QUIET_APPLIED:
        return
    try:
        from mflux.models.common.lora.mapping.lora_loader import LoRALoader
    except ImportError:
        return
    _MFLUX_LORA_QUIET_APPLIED = True
    _orig_load = LoRALoader.load_and_apply_lora

    @staticmethod
    def _load_and_apply_lora_quiet(*args, **kwargs):
        return _orig_load(*args, **kwargs)

    LoRALoader.load_and_apply_lora = _load_and_apply_lora_quiet


def _sysctl_string(name: str) -> str:
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    key = name.encode()
    size = ctypes.c_size_t(0)
    libc.sysctlbyname(key, None, ctypes.byref(size), None, 0)
    buf = ctypes.create_string_buffer(size.value)
    libc.sysctlbyname(key, buf, ctypes.byref(size), None, 0)
    return buf.value.decode()


def apply_mflux_macos_subprocess_shim() -> None:
    global _APPLIED
    if _APPLIED:
        return
    try:
        from mflux.callbacks.instances import battery_saver as battery_mod
        from mflux.utils import apple_silicon as apple_mod
    except ImportError:
        return
    _APPLIED = True

    @classmethod
    def _get_chip_name_no_subprocess(cls) -> str:
        if cls._chip_name is not None:
            return cls._chip_name
        try:
            cls._chip_name = _sysctl_string("machdep.cpu.brand_string")
        except OSError:
            cls._chip_name = ""
        return cls._chip_name

    apple_mod.AppleSiliconUtil._get_chip_name = _get_chip_name_no_subprocess

    @classmethod
    def _is_machine_battery_powered_noop(cls) -> bool:
        return False

    battery_mod.BatterySaver._is_machine_battery_powered = _is_machine_battery_powered_noop

    def _call_before_loop_noop(self, **kwargs) -> None:
        return

    battery_mod.BatterySaver.call_before_loop = _call_before_loop_noop


def set_perf_debug(enabled: bool) -> None:
    global _perf_debug
    _perf_debug = bool(enabled)


def perf_log(message: str) -> None:
    if _perf_debug:
        try:
            from debug_log import debug_timestamp

            print(
                f"{debug_timestamp()} [imagegen-perf] {message}",
                file=sys.stderr,
                flush=True,
            )
        except Exception:
            print(f"[imagegen-perf] {message}", file=sys.stderr, flush=True)


def perf_log_kv(event: str, **fields: Any) -> None:
    if not _perf_debug:
        return
    parts = [event]
    for key, value in fields.items():
        if value is None:
            continue
        if isinstance(value, float):
            parts.append(f"{key}={value:.3f}s")
        else:
            parts.append(f"{key}={value}")
    perf_log(" ".join(parts))


class PerfTimer:
    def __init__(self, event: str, **fields: Any) -> None:
        self._event = event
        self._fields = dict(fields)
        self._t0: Optional[float] = None

    def __enter__(self) -> PerfTimer:
        self._t0 = time.perf_counter()
        perf_log_kv(f"{self._event}_start", **self._fields)
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self._t0 is None:
            return
        elapsed = time.perf_counter() - self._t0
        status = "error" if exc is not None else "ok"
        perf_log_kv(self._event, elapsed=elapsed, status=status, **self._fields)


def _stdout_emit(msg: Dict[str, Any]) -> None:
    print(json.dumps(msg, ensure_ascii=False), flush=True)


def emit_worker_message(msg: Dict[str, Any]) -> None:
    """Persistent worker: stdout NDJSON. One-shot pipeline scripts: stderr progress only."""
    if not msg:
        return
    out = msg
    if (
        msg.get("type") == "progress"
        and _active_job_id
        and not str(msg.get("job_id") or "").strip()
    ):
        out = dict(msg)
        out["job_id"] = _active_job_id
    if _active_emit is not None:
        _active_emit(out)
        return
    if out.get("type") == "progress":
        print(json.dumps(out, ensure_ascii=False), file=sys.stderr, flush=True)


def _emit(msg: Dict[str, Any]) -> None:
    emit_worker_message(msg)


def flux_prompt_system_message() -> str:
    return ""


def _log_worker_error(context: str, exc: BaseException) -> None:
    try:
        print(f"[imagegen_generate_worker] {context}: {exc}", file=sys.stderr, flush=True)
        traceback.print_exc()
    except Exception:
        pass


def _unload_image_model(*, reason: str = "explicit") -> None:
    global _LOADED_KIND
    try:
        from imagegen_plugins.mflux_model_session import release_all_mflux_sessions

        release_all_mflux_sessions(reason=reason)
    except Exception:
        pass
    try:
        from imagegen_plugins.pipelines.sana_sprint import unload_pipeline as unload_sana

        unload_sana()
    except Exception:
        pass
    try:
        from imagegen_plugins.pipelines.sd15_diffusers import unload_pipeline as unload_sd15

        unload_sd15()
    except Exception:
        pass
    try:
        from imagegen_plugins.pipelines.sdxl_diffusers import unload_pipeline as unload_sdxl

        unload_sdxl(force=True)
    except Exception:
        pass
    try:
        from imagegen_plugins.pipelines.z_image_turbo import unload_pipeline as unload_z_image

        unload_z_image()
    except Exception:
        pass
    gc.collect()
    if _LOADED_KIND == "image":
        _LOADED_KIND = None


def _ensure_mlx_ready(pipeline_id: str) -> None:
    if not pipeline_id.startswith("mflux") and pipeline_id != "flux_schnell_mflux_play":
        return
    try:
        import mlx.core as mx

        mx.default_device()
    except Exception as e:
        _log_worker_error("MLX native extension failed to load", e)
        raise RuntimeError(
            f"{e} Install MLX/MFLUX in the imagegen venv (Settings → Image Generation)."
        ) from e


def _resolve_run_from_payload(pipeline_id: str):
    if pipeline_id == "flux_schnell_mflux_play":
        _ensure_mlx_ready(pipeline_id)
        from imagegen_plugins.pipelines.mflux_schnell import run_from_payload

        return run_from_payload
    if pipeline_id == "sana_sprint_600m":
        from imagegen_plugins.pipelines.sana_sprint import run_from_payload

        return run_from_payload
    if pipeline_id == "sd15_diffusers":
        from imagegen_plugins.pipelines.sd15_diffusers import run_from_payload

        return run_from_payload
    if pipeline_id == "sdxl_diffusers":
        from imagegen_plugins.pipelines.sdxl_diffusers import run_from_payload

        return run_from_payload
    if pipeline_id == "z_image_turbo_sdnq":
        from imagegen_plugins.pipelines.z_image_turbo import run_from_payload

        return run_from_payload
    if pipeline_id == "mflux_z_image_turbo":
        _ensure_mlx_ready(pipeline_id)
        from imagegen_plugins.pipelines.mflux_z_image_turbo import run_from_payload

        return run_from_payload
    if pipeline_id in ("mflux_fill_expand", "mflux_fill_infill"):
        _ensure_mlx_ready(pipeline_id)
        from imagegen_plugins.pipelines.mflux_fill_expand import run_from_payload

        return run_from_payload
    if pipeline_id == "mflux_flux2_klein_create":
        _ensure_mlx_ready(pipeline_id)
        from imagegen_plugins.pipelines.mflux_flux2_klein_create import run_from_payload

        return run_from_payload
    if pipeline_id in ("mflux_flux2_klein_edit", "mflux_flux2_klein_expand"):
        _ensure_mlx_ready(pipeline_id)
        from imagegen_plugins.pipelines.mflux_flux2_klein_edit import run_from_payload

        return run_from_payload
    raise ValueError(f"Unknown imagegen pipeline_id: {pipeline_id!r}")


def run_generate_from_payload(payload: Dict[str, Any], job_id: str) -> Dict[str, Any]:
    global _LOADED_KIND, _active_job_id

    _active_job_id = job_id
    clear_generation_cancel()
    apply_mflux_macos_subprocess_shim()
    apply_mflux_worker_tqdm_shim()
    apply_mflux_worker_lora_quiet_shim()

    set_perf_debug(bool(payload.get("debug_mode")))
    _emit({"type": "job_started", "job_id": job_id, "command": "generate"})
    pipeline_id = str(payload.get("pipeline_id") or "flux_schnell_mflux_play")
    run_from_payload = _resolve_run_from_payload(pipeline_id)

    from imagegen_plugins.mflux_model_session import (
        note_image_model_loaded,
        prepare_image_model_for_payload,
    )

    prepare_image_model_for_payload(payload)
    _LOADED_KIND = "image"
    if pipeline_id == "mflux_fill_infill":
        print(
            "[imagegen_generate_worker] infill job payload: "
            f"base={str(payload.get('pixelmator_base_path') or '')!r} "
            f"mask={str(payload.get('pixelmator_mask_path') or '')!r} "
            f"source={str(payload.get('pixelmator_doc_path') or '')!r}",
            file=sys.stderr,
            flush=True,
        )
    perf_log_kv("worker_generate", job_id=job_id, pipeline=pipeline_id)
    try:
        from model_debug_log import log_imagegen_payload

        log_imagegen_payload(payload)
    except Exception:
        pass

    job_t0 = time.perf_counter()
    try:
        with PerfTimer("worker_job", job_id=job_id, pipeline=pipeline_id):
            result = run_from_payload(payload)
        if not isinstance(result, dict):
            result = {"output_path": str(result)}
        _emit({"type": "result", "job_id": job_id, "command": "generate", **result})
        return result
    except GenerationCancelledError:
        raise
    except Exception as e:
        _log_worker_error("generate failed", e)
        raise
    finally:
        _active_job_id = None
        note_image_model_loaded(payload)
        perf_log_kv(
            "worker_job_done",
            job_id=job_id,
            pipeline=pipeline_id,
            elapsed=time.perf_counter() - job_t0,
        )


def handle_imagegen_command(cmd: Dict[str, Any]) -> Any:
    command = cmd.get("command")
    job_id = str(cmd.get("job_id") or "")

    from imagegen_plugins.mflux_model_session import maybe_unload_idle_image_model

    maybe_unload_idle_image_model()

    if command == "shutdown":
        _unload_image_model(reason="shutdown")
        return _SHUTDOWN

    if command == "cancel":
        request_generation_cancel()
        return None

    if command == "unload_image":
        _unload_image_model(reason="queue_held")
        return None

    if command == "generate":
        payload = cmd.get("payload")
        if not isinstance(payload, dict):
            raise ValueError("generate requires payload dict")
        run_generate_from_payload(payload, job_id)
        return None

    raise ValueError(f"Unknown command: {command!r}")


def _start_generate_in_background(
    cmd: Dict[str, Any],
    emit_fn: Callable[[Dict[str, Any]], None],
) -> None:
    """Run generate off the command loop so ``cancel`` can be handled while diffusing."""

    job_id = str(cmd.get("job_id") or "")

    def _work() -> None:
        try:
            payload = cmd.get("payload")
            if not isinstance(payload, dict):
                emit_fn(
                    {
                        "type": "error",
                        "job_id": job_id,
                        "message": "generate requires payload dict",
                    }
                )
                return
            run_generate_from_payload(payload, job_id)
        except GenerationCancelledError:
            emit_fn(
                {
                    "type": "error",
                    "job_id": _active_job_id or job_id,
                    "message": "Cancelled",
                }
            )
        except Exception as e:
            _log_worker_error("generate failed", e)
            emit_fn({"type": "error", "job_id": job_id, "message": str(e)})

    threading.Thread(
        target=_work,
        name=f"imagegen-generate-{job_id[:8]}",
        daemon=True,
    ).start()


def run_imagegen_worker_event_loop(
    read_line_fn: Callable[[], Optional[str]],
    emit_fn: Callable[[Dict[str, Any]], None],
) -> None:
    global _active_emit

    if emit_fn is _emit:
        raise RuntimeError("run_imagegen_worker_event_loop: pass _stdout_emit, not _emit")
    apply_mflux_macos_subprocess_shim()
    apply_mflux_worker_tqdm_shim()
    apply_mflux_worker_lora_quiet_shim()
    _active_emit = emit_fn
    inbound: queue.Queue[str | None] = queue.Queue()

    def _reader() -> None:
        try:
            while True:
                line = read_line_fn()
                inbound.put(line)
                if line is None:
                    break
        except Exception:
            inbound.put(None)

    threading.Thread(
        target=_reader,
        name="imagegen-cmd-reader",
        daemon=True,
    ).start()
    try:
        emit_fn({"type": "ready"})
        while True:
            line = inbound.get()
            if line is None:
                break
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError as e:
                emit_fn({"type": "error", "message": f"Invalid JSON command: {e}"})
                continue
            if not isinstance(cmd, dict):
                emit_fn({"type": "error", "message": "command must be a JSON object"})
                continue
            job_id = str(cmd.get("job_id") or "")
            command = cmd.get("command")
            try:
                if command == "generate":
                    _start_generate_in_background(cmd, emit_fn)
                    continue
                if handle_imagegen_command(cmd) is _SHUTDOWN:
                    break
            except GenerationCancelledError:
                target_job = _active_job_id or job_id
                emit_fn({"type": "error", "job_id": target_job, "message": "Cancelled"})
            except Exception as e:
                _log_worker_error(f"command {cmd.get('command')!r} failed", e)
                emit_fn({"type": "error", "job_id": job_id, "message": str(e)})
    finally:
        _active_emit = None
        _unload_image_model(reason="worker_exit")
