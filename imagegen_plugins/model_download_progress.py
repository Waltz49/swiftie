#!/usr/bin/env python3
"""Qt progress UI for in-process Hugging Face model downloads."""

from __future__ import annotations

import threading
from typing import Any, Callable, TypeVar

from PySide6.QtCore import QEventLoop, QThread, Signal
from PySide6.QtWidgets import QApplication

from utils import create_titled_progress_dialog

_T = TypeVar("_T")

_DOWNLOAD_NOTE = (
    "The download runs in the background so Prowser stays responsive. "
    "Progress will update below when Hugging Face reports it."
)
_CANCEL_NOTE = "You can cancel anytime; partial downloads resume later."


class ModelDownloadCancelled(Exception):
    """Raised when the user cancels a model download."""


def _format_bytes(num: float) -> str:
    if num <= 0:
        return "0 B"
    if num < 1_000_000:
        return f"{num / 1_000:.1f} KB"
    if num < 1_000_000_000:
        return f"{num / 1_000_000:.1f} MB"
    return f"{num / 1_000_000_000:.1f} GB"


def _build_tqdm_class(
    *,
    emit_progress: Callable[[float, float, str], None],
    is_cancelled: Callable[[], bool],
) -> type:
    def _notify(bar: Any) -> None:
        if is_cancelled():
            return
        emit_progress(float(bar._n), float(bar._total), str(bar.desc or ""))

    class _QtSnapshotDownloadProgress:
        """Minimal tqdm stand-in for huggingface_hub.snapshot_download."""

        def __init__(self, *args: Any, **kwargs: Any) -> None:
            self.desc = str(kwargs.pop("desc", "") or "")
            self._n = float(kwargs.pop("initial", 0) or 0)
            self._total = float(kwargs.pop("total", 0) or 0)
            self.format_dict: dict[str, Any] = {"rate": None}
            for key in (
                "disable",
                "name",
                "log_level",
                "unit",
                "unit_scale",
                "unit_divisor",
                "file",
                "mininterval",
                "maxinterval",
                "miniters",
                "ascii",
                "position",
                "leave",
                "dynamic_ncols",
                "smoothing",
                "bar_format",
            ):
                kwargs.pop(key, None)
            _notify(self)

        @property
        def total(self) -> float:
            return self._total

        @total.setter
        def total(self, value: float | int | None) -> None:
            self._total = float(value or 0)
            _notify(self)

        @property
        def n(self) -> float:
            return self._n

        def update(self, n: float | int | None = 1) -> float:
            if is_cancelled():
                return self._n
            if n is None:
                return self._n
            self._n += float(n)
            _notify(self)
            return self._n

        def refresh(self) -> None:
            if is_cancelled():
                return
            _notify(self)

        def set_description(self, desc: str | None = None, refresh: bool = True) -> None:
            self.desc = str(desc or "")
            if refresh:
                self.refresh()

        def set_postfix_str(self, postfix: str, refresh: bool = False) -> None:
            pass

        def set_transfer_postfix_str(self, postfix: str, refresh: bool = False) -> None:
            pass

        def update_transfer(self, n: int | float | None = 1) -> None:
            pass

        def close(self, *args: Any, **kwargs: Any) -> None:
            pass

        def __enter__(self) -> _QtSnapshotDownloadProgress:
            return self

        def __exit__(self, *args: Any) -> None:
            pass

    return _QtSnapshotDownloadProgress


class _ModelDownloadWorker(QThread):
    progress = Signal(float, float, str)
    finished_ok = Signal(object)
    finished_failed = Signal(object)

    def __init__(
        self,
        download_fn: Callable[[type], _T],
        cancel_event: threading.Event,
    ) -> None:
        super().__init__()
        self._download_fn = download_fn
        self._cancel_event = cancel_event

    def run(self) -> None:
        tqdm_class = _build_tqdm_class(
            emit_progress=self.progress.emit,
            is_cancelled=self._cancel_event.is_set,
        )
        done = threading.Event()
        outcome: dict[str, Any] = {}

        def _download() -> None:
            try:
                outcome["result"] = self._download_fn(tqdm_class)
                outcome["ok"] = True
            except Exception as exc:
                outcome["exc"] = exc
                outcome["ok"] = False
            finally:
                done.set()

        thread = threading.Thread(
            target=_download,
            name="ModelDownloadInner",
            daemon=True,
        )
        thread.start()
        while not done.wait(0.05):
            if self._cancel_event.is_set():
                self.finished_failed.emit(ModelDownloadCancelled())
                return
        if outcome.get("ok"):
            self.finished_ok.emit(outcome["result"])
        else:
            self.finished_failed.emit(
                outcome.get("exc", RuntimeError("Model download failed."))
            )


class _ModelDownloadProgressSession:
    """Modal progress dialog while a background thread downloads."""

    def __init__(self, parent, *, title: str, repo_id: str) -> None:
        self._base_label = (
            f"Downloading {repo_id}.\n\n{_DOWNLOAD_NOTE}\n\n{_CANCEL_NOTE}"
        )
        self._dialog = create_titled_progress_dialog(
            parent,
            f"Downloading {title}",
            total=0,
            label=self._base_label,
            cancellable=True,
            indeterminate=True,
            fit_content_width=True,
        )

    def on_progress(self, n: float, total: float, desc: str) -> None:
        if total > 0:
            pct = min(100, max(0, int(n * 100 / total)))
            if self._dialog.maximum() != 100:
                self._dialog.setMaximum(100)
            self._dialog.setValue(pct)
            progress_line = f"{_format_bytes(n)} / {_format_bytes(total)}"
            if desc and desc != "Downloading (incomplete total...)":
                progress_line = f"{desc}\n{progress_line}"
            self._dialog.setLabelText(f"{self._base_label}\n\n{progress_line}")
        elif desc and desc != "Downloading (incomplete total...)":
            self._dialog.setLabelText(f"{self._base_label}\n\n{desc}")

    def close(self) -> None:
        self._dialog.close()
        QApplication.processEvents()


def run_model_download_with_progress(
    parent,
    *,
    title: str,
    repo_id: str,
    download_fn: Callable[[type], _T],
) -> _T:
    """Run ``download_fn(tqdm_class)`` on a worker thread with a modal progress dialog."""
    cancel_event = threading.Event()
    session = _ModelDownloadProgressSession(parent, title=title, repo_id=repo_id)
    worker = _ModelDownloadWorker(download_fn, cancel_event)
    if parent is not None:
        worker.setParent(parent)

    loop = QEventLoop(parent)
    result_box: list[_T] = []
    error_box: list[BaseException] = []

    def _on_ok(value: object) -> None:
        result_box.append(value)
        loop.quit()

    def _on_failed(exc: object) -> None:
        if isinstance(exc, BaseException):
            error_box.append(exc)
        else:
            error_box.append(RuntimeError(str(exc)))
        loop.quit()

    def _on_cancel() -> None:
        cancel_event.set()

    worker.progress.connect(session.on_progress)
    worker.finished_ok.connect(_on_ok)
    worker.finished_failed.connect(_on_failed)
    session._dialog.canceled.connect(_on_cancel)
    worker.finished.connect(worker.deleteLater)

    worker.start()
    loop.exec()
    worker.wait()

    try:
        session._dialog.canceled.disconnect(_on_cancel)
    except (TypeError, RuntimeError):
        pass

    session.close()

    if cancel_event.is_set() and not result_box:
        raise ModelDownloadCancelled()
    if error_box:
        raise error_box[0]
    if not result_box:
        raise RuntimeError("Model download finished without a result.")
    return result_box[0]
