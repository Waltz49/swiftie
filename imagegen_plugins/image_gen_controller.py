#!/usr/bin/env python3
"""Controller for local image generation and LM Studio captions (shared worker)."""

from __future__ import annotations

import os
import time
import uuid
from typing import Any, Dict, List, Optional

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtWidgets import QMessageBox

from imagegen_plugins.edit_aspect_pad import remove_edit_aspect_pad_temps
from imagegen_plugins.expand_base_image import (
    prepare_and_save_expand_base,
    remove_expand_base_temp,
)
from imagegen_plugins.image_gen_naming import (
    format_image_exif_prompt,
    make_readable_user_comment_before_browse,
    next_imagegen_path,
    apply_refinement_source_for_next_copy,
    reference_entries_for_source_paths,
    resolve_source_image_paths,
    source_paths_for_generation_exif,
    resolve_generation_elapsed_seconds,
    write_exif_user_comment,
)
from imagegen_plugins.image_gen_output_format import output_extension_from_settings
from imagegen_plugins.lora_trigger_prompt_guard import prompt_text_for_exif
from imagegen_plugins.generation_timing_stats import (
    build_generation_timing_key,
    lookup_average,
    record_run,
)
from imagegen_plugins.mflux_lora_presets import lora_name_for_exif_from_values
from imagegen_plugins.image_gen_persistence import (
    load_hold_job_queue,
    load_show_progressive_images,
    save_hold_job_queue,
    save_show_progressive_images,
)
from imagegen_plugins.image_gen_pipeline_modes import get_pipeline
from imagegen_plugins.image_gen_registry import ImageGenModelPlugin
from imagegen_plugins.image_gen_seed_persistence import (
    extract_used_seed_from_worker_result,
    parse_worker_stdout,
)
from imagegen_plugins.model_task_queue import (
    QueuedGenerateJob,
    QueueRowSnapshot,
    apply_payload_model_fields_to_values,
    job_references_invalid,
    make_queued_generate_job,
    refresh_queued_job_status,
    restore_queued_generate_job,
    thumbnail_paths_for_values,
)
from imagegen_plugins.job_step_persistence import (
    clear_job_active_running_file,
    load_job_active_pending,
    load_job_active_running,
    load_job_queue_active_display_index,
    load_job_queue_json,
    persist_step_job_files,
    remove_legacy_job_queue_data,
)
from imagegen_plugins.job_step_queue import (
    active_job_step_docs_for_persist,
    append_pending_step,
    build_pending_job_doc,
    build_running_job_doc,
    CONTINUOUS_MODE_KEY,
    CONTINUOUS_TEMPLATE_KEY,
    finalize_pending_doc_for_persist,
    materialize_pending_steps_from_update,
    materialize_steps,
    merge_step_into_values,
    pending_doc_is_continuous,
    pending_step_count,
    pop_pending_step,
    prepare_step_ai_launch,
    prepend_pending_step,
    queued_generate_job_to_step_doc,
    queued_job_from_step_doc,
    replace_pending_steps,
    resolve_step_before_run,
    restore_chain_state_from_pending_doc,
    step_needs_ai,
    step_values,
    sync_chain_state_to_pending_doc,
)
from imagegen_plugins.model_task_status_info import (
    apply_cooldown_to_status_html,
    cooldown_skip_icon_html,
    format_caption_status_html,
    format_image_generation_queue_status_html,
    freeze_status_html_generation_elapsed,
    refresh_expand_task_status_html_for_display,
    remove_elapsed_row,
    strip_cooldown_from_status_html,
    update_status_html_steps_progress,
)
from workers.model_tasks_controller import ModelTasksController, get_model_tasks_controller
from imagegen_plugins.image_gen_dialog import (
    apply_copies_random_seed_choice,
    prompt_enable_random_seed_for_copies,
)
from imagegen_plugins.image_gen_field_blocks import (
    IMAGE_GEN_COPIES_CONTINUOUS,
    is_series_continuous_copies,
)
from thumbnails.thumbnail_constants import STARTUP_QUEUE_RELEASE_DELAY_MS
from utils import show_styled_critical, show_styled_question, styled_message_box

_COPIES_MIN = 1
_COPIES_MAX = 200
_SERIES_CONTINUOUS_COPIES = IMAGE_GEN_COPIES_CONTINUOUS
_CANCEL_PROCEED_NOTE = "Canceling..."
_REMOVE_PROCEED_NOTE = "Removing..."


class ImageGenController(QObject):
    """UI façade for model tasks (generation + caption) on one background worker."""

    generation_started = Signal()
    job_processing_started = Signal(str)
    generation_finished = Signal(bool, str, str)  # success, output_path, error_message
    task_status_info_changed = Signal()
    # Emitted after a copy completes and pending count is final, before inter-copy cooldown.
    active_job_replace_updatability_changed = Signal()
    live_status_tick = Signal()
    queue_changed = Signal()
    hold_job_queue_changed = Signal()
    jobs_pane_title_changed = Signal()

    caption_chunk = Signal(str)
    caption_ready = Signal(str)
    caption_error = Signal(str)
    caption_finished = Signal()

    flux_prompt_chunk = Signal(str)
    flux_prompt_ready = Signal(str)
    flux_prompt_error = Signal(str)
    flux_prompt_finished = Signal()

    def __init__(self, main_window, parent=None):
        super().__init__(parent)
        self.main_window = main_window
        self._tasks = get_model_tasks_controller(self)
        self._tasks.set_generate_progress_callback(self._on_generate_progress)
        self._tasks.generation_started.connect(self._on_generation_started)
        self._tasks.generation_finished.connect(self._on_generation_finished)
        self._tasks.caption_chunk.connect(self.caption_chunk.emit)
        self._tasks.caption_ready.connect(self.caption_ready.emit)
        self._tasks.caption_error.connect(self._on_caption_error)
        self._tasks.flux_prompt_chunk.connect(self._on_flux_prompt_chunk_from_worker)
        self._tasks.flux_prompt_ready.connect(self._on_flux_prompt_ready_from_worker)
        self._tasks.flux_prompt_error.connect(self._on_flux_prompt_error_from_worker)
        self._tasks.task_started.connect(self._on_task_started)
        self._tasks.job_processing_started.connect(self._on_job_processing_started)
        self._tasks.task_finished.connect(self._on_task_finished)

        # Second worker for text tasks (caption, flux prompt) while generation runs.
        self._foreground_tasks = ModelTasksController(self)
        self._foreground_tasks.caption_chunk.connect(self.caption_chunk.emit)
        self._foreground_tasks.caption_ready.connect(self.caption_ready.emit)
        self._foreground_tasks.caption_error.connect(self._on_caption_error)
        self._foreground_tasks.flux_prompt_chunk.connect(self.flux_prompt_chunk.emit)
        self._foreground_tasks.flux_prompt_ready.connect(self.flux_prompt_ready.emit)
        self._foreground_tasks.flux_prompt_error.connect(self._on_flux_prompt_error)
        self._foreground_tasks.task_finished.connect(self._on_foreground_task_finished)

        self._queue: List[QueuedGenerateJob] = []
        self._active_queue_job_id: str = ""
        self._active_display_index: int = 0
        self._active_thumbnail_paths: list[str] = []
        self._selected_job_id: str | None = None

        self._active_plugin: Optional[ImageGenModelPlugin] = None
        self._output_path: str = ""
        self._pending_values: Dict[str, Any] = {}
        self._next_copy_display_values: Dict[str, Any] = {}
        self._progressive_browse_opened = False
        self._task_status_info_html: str = ""
        self._task_status_view = None
        self._step_progress_start_time: Optional[float] = None
        self._step_progress_completed_at: Optional[float] = None
        self._expand_source_path: str = ""
        self._expand_base_path: str = ""
        self._aspect_pad_temp_paths: list[str] = []
        self._task_reference_paths: list[str] = []
        self._copy_cycle_plugin: Optional[ImageGenModelPlugin] = None
        self._copy_cycle_values: Dict[str, Any] = {}
        self._copy_cycle_reference_paths: list[str] = []
        self._copy_cycle_expand_source_path: str = ""
        self._suppress_task_failure_ui = False
        self._copies_total = 0
        self._copies_done = 0
        self._copy_batch_active = False
        self._copy_batch_cancelled = False
        self._skip_series_copy_requested = False
        self._cooldown_timer: Optional[QTimer] = None
        self._cooldown_deadline: Optional[float] = None
        self._cooldown_before_next_job = False
        self._frozen_elapsed_seconds: Optional[float] = None
        self._last_cooldown_ui_second: Optional[int] = None
        self._live_step = 0
        self._live_step_total = 0
        self._live_elapsed_seconds: Optional[float] = None
        self._live_estimate_seconds: Optional[float] = None
        # Seconds per step, frozen when a diffusion step completes (for live ETA).
        self._step_seconds_per_step: Optional[float] = None
        self._generation_timing_key = None
        self._historical_avg_total_seconds: Optional[float] = None
        self._job_ai_stage_active = False
        self._active_job_with_ai = False
        self._launch_refined_prompt: str = ""
        self._job_ai_chars_received = 0
        self._job_ai_last_progress_bucket = -1
        self._step_running_doc: dict | None = None
        self._step_pending_doc: dict | None = None
        self._step_running: dict | None = None
        self._steps_done = 0
        self._last_completed_output_path = ""
        self._last_completed_prompt = ""
        self._last_completed_values: Dict[str, Any] = {}
        self._continuous_step_template: dict | None = None
        self._hold_job_queue = load_hold_job_queue()
        self._startup_queue_hold = False
        self._startup_queue_release_timer: QTimer | None = None
        self._queue_advance_suppressed = False
        self._pending_cancel_job_id = ""
        self._quit_after_current_worker = False
        self._deferred_quit_wait_all_jobs = False
        self._deferred_quit_dialog = None
        self._deferred_quit_status_label = None
        self._deferred_quit_toggle_btn = None
        self._exit_queue_persisted = False
        self._queue_persist_suppressed = False
        self._queue_persist_timer = QTimer(self)
        self._queue_persist_timer.setSingleShot(True)
        self._queue_persist_timer.timeout.connect(self._persist_job_queue_now)
        self._gpu_cleanup_active = False
        self._try_start_next_timer: QTimer | None = None
        # Local job timing/progress/cooldown UI only (500ms). Must not probe external
        # services (LM Studio, model hosts, etc.); see lmstudio_caption module comment.
        self._live_status_timer = QTimer(self)
        self._live_status_timer.setInterval(500)
        self._live_status_timer.timeout.connect(self._on_live_status_tick)
        self._cached_pending_queue_key: tuple[tuple[str, str], ...] | None = None
        self._cached_pending_rows: list[QueueRowSnapshot] | None = None
        self._progress_ui_last_emit_at = 0.0
        self._PROGRESS_UI_MIN_INTERVAL_S = 0.2
        self._progressive_refresh_timer = QTimer(self)
        self._progressive_refresh_timer.setSingleShot(True)
        self._progressive_refresh_timer.timeout.connect(
            self._flush_pending_progressive_refresh
        )
        self._pending_progressive_path = ""
        self._pending_progressive_force_fullscreen = False
        self._restore_persisted_job_queue()

        # Keep background idle scanning paused for the full generation job lifetime.
        self.generation_started.connect(self._sync_idle_detector_generation_busy)
        self.generation_finished.connect(self._sync_idle_detector_generation_busy)
        self.queue_changed.connect(self._sync_idle_detector_generation_busy)
        self.generation_started.connect(self._update_live_status_timer)
        self.generation_finished.connect(self._update_live_status_timer)
        self.generation_finished.connect(self._probe_lmstudio_after_generation)
        self.queue_changed.connect(self._invalidate_pending_queue_snapshot_cache)
        self._tasks.task_finished.connect(self._on_tasks_task_finished_for_hold_unload)

    _GPU_CLEANUP_POLL_MS = 2000
    _GPU_CLEANUP_MAX_ATTEMPTS = 30
    _PROGRESSIVE_REFRESH_MIN_INTERVAL_MS = 750

    def _generation_busy_for_idle(self) -> bool:
        """True while a generation job is active start-to-finish (incl. AI/cooldown/cleanup).

        Uses job-queue identity rather than ``_tasks.is_running()``: finish handlers
        run before the worker clears its active job id, so relying on the task flag
        would leave background idle scanning paused forever after the last job.
        """
        return bool(self._active_queue_job_id) or self._gpu_cleanup_active or (
            self._copy_batch_active and not self._copy_batch_cancelled
        ) or self._is_in_copy_cooldown() or self._job_ai_stage_active

    def _sync_idle_detector_generation_busy(self, *_args) -> None:
        busy = self._generation_busy_for_idle()
        idle = getattr(self.main_window, "idle_detector", None)
        if idle is not None:
            idle.set_generation_busy(busy)
        apply_busy = getattr(
            self.main_window, "_apply_generation_busy_timer_intervals", None
        )
        if apply_busy is not None:
            apply_busy(busy)

    def _release_main_process_gpu_memory(self) -> None:
        """Return Metal pool memory in the UI process after the worker exits."""
        try:
            from imagegen_plugins.mflux_model_session import release_mlx_metal_cache

            release_mlx_metal_cache()
        except Exception:
            pass
        try:
            import gc

            gc.collect()
            import torch

            if (
                getattr(torch.backends, "mps", None) is not None
                and torch.backends.mps.is_available()
            ):
                torch.mps.empty_cache()
        except Exception:
            pass

    def _set_gpu_cleanup_status(self, active: bool) -> None:
        if active == self._gpu_cleanup_active:
            if active:
                self.task_status_info_changed.emit()
            return
        self._gpu_cleanup_active = active
        if active:
            self._task_status_info_html = (
                "<span>Releasing GPU memory before the next job…</span>"
            )
            self._update_status_bar_indicator("cleanup")
        elif not self.is_running():
            self._task_status_info_html = ""
            self._update_status_bar_indicator(None)
        self.task_status_info_changed.emit()
        self._emit_jobs_pane_title_changed()
        self._update_live_status_timer()

    def _abort_queued_job_start(self) -> None:
        """Reset after a queued job failed to start."""
        self._set_gpu_cleanup_status(False)
        job_id = self._active_queue_job_id
        if job_id and self._queued_job_by_id(job_id) is not None:
            self._clear_active_job_head_without_demote()
            self._defer_try_start_next_queued_job(delay_ms=self._GPU_CLEANUP_POLL_MS)
            return
        if self._demote_active_remaining_to_queue():
            self._defer_try_start_next_queued_job(delay_ms=self._GPU_CLEANUP_POLL_MS)
            return
        self._clear_active_job_head_without_demote()
        self._defer_try_start_next_queued_job(delay_ms=self._GPU_CLEANUP_POLL_MS)

    def _clear_active_job_head_without_demote(self) -> None:
        """Drop active-controller state while the queue row (if any) stays put."""
        self._copy_batch_active = False
        self._copies_total = 0
        self._copies_done = 0
        self._copy_batch_cancelled = False
        self._active_queue_job_id = ""
        self._active_display_index = 0
        self._active_thumbnail_paths = []
        self._reset_generation_state()
        self._sync_cancel_menu()
        self.queue_changed.emit()
        self._update_live_status_timer()

    def _pop_queued_job(self, job_id: str) -> bool:
        if not job_id:
            return False
        for idx, job in enumerate(self._queue):
            if job.job_id == job_id:
                self._queue.pop(idx)
                self._invalidate_pending_queue_snapshot_cache()
                self.queue_changed.emit()
                self._schedule_persist_job_queue()
                return True
        return False

    def _generation_worker_active(self) -> bool:
        """True when a worker, AI stage, cooldown, or GPU cleanup is in flight."""
        if self._job_ai_stage_active:
            return True
        if self._tasks.is_running() or self._foreground_tasks.is_running():
            return True
        if self._gpu_cleanup_active:
            return True
        if self._is_in_copy_cooldown():
            return True
        return False

    def is_running(self) -> bool:
        if self._generation_worker_active():
            return True
        if self._copy_batch_active and not self._copy_batch_cancelled:
            return True
        return False

    def pane_shows_generation_progress(self) -> bool:
        """True when the jobs pane should show the active-job strip."""
        return self.is_running()

    def queue_hold_compact_message(self) -> str | None:
        """Compact-mode message when the queue is held with waiting jobs."""
        if not self._hold_job_queue or self.is_running():
            return None
        job_count = len(self.queue_snapshot())
        if job_count <= 0:
            return None
        noun = "job" if job_count == 1 else "jobs"
        return f"Job queue held with {job_count} {noun}"

    def hold_job_queue(self) -> bool:
        return bool(self._hold_job_queue)

    def set_hold_job_queue(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if enabled == self._hold_job_queue:
            return
        self._hold_job_queue = enabled
        save_hold_job_queue(enabled)
        self.hold_job_queue_changed.emit()
        self._schedule_persist_job_queue()
        self._emit_jobs_pane_title_changed()
        if enabled:
            self.schedule_unload_image_model_for_queue_hold()
        if not enabled:
            self._startup_queue_hold = False
            self._resume_after_hold_released()

    def schedule_startup_queue_release(
        self, delay_ms: int = STARTUP_QUEUE_RELEASE_DELAY_MS
    ) -> None:
        """Release restored queue auto-start after app startup has settled."""
        if not self._startup_queue_hold:
            return
        timer = self._startup_queue_release_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self._release_startup_queue_hold)
            self._startup_queue_release_timer = timer
        timer.stop()
        timer.start(max(0, int(delay_ms)))

    def _release_startup_queue_hold(self) -> None:
        if not self._startup_queue_hold:
            return
        self._startup_queue_hold = False
        if self._active_queue_job_id and not self._generation_worker_active():
            self._resume_restored_active_job_if_idle()
            return
        self._defer_try_start_next_queued_job()

    def _resume_restored_active_job_if_idle(self) -> None:
        if not self._active_queue_job_id or self._generation_worker_active():
            self._defer_try_start_next_queued_job()
            return
        if self._yield_active_if_superseded_by_reorder():
            return
        plugin = self._active_plugin
        if plugin is None:
            self._finish_copy_batch()
            self._defer_try_start_next_queued_job()
            return
        if self._step_running is None:
            if not self._promote_next_step_to_running(plugin):
                self._finish_copy_batch()
                self._defer_try_start_next_queued_job()
                return
        if self._pending_job_needs_ai_stage():
            self._begin_job_ai_stage()
        else:
            self._launch_generation_job()

    def _resume_after_hold_released(self) -> None:
        if self._queue_advance_suppressed:
            return
        if (
            self._copy_batch_active
            and not self._copy_batch_cancelled
            and self._pending_batch_copies() > 0
            and not self._tasks.is_running()
            and not self._is_in_copy_cooldown()
        ):
            QTimer.singleShot(0, self._launch_next_copy_after_cooldown)
            return
        if self._active_queue_job_id and not self._generation_worker_active():
            self._resume_restored_active_job_if_idle()
            return
        if not self._generation_worker_active():
            self._try_start_next_queued_job()
            return
        self._defer_try_start_next_queued_job(delay_ms=self._GPU_CLEANUP_POLL_MS)

    def _generation_pipeline_idle(self) -> bool:
        return not self._tasks.is_running() and not self._is_in_copy_cooldown()

    def jobs_pane_title_suffix(self) -> str:
        """Title-bar suffix for hold / quiesce state, or '' when unheld."""
        if not self._hold_job_queue:
            return ""
        if self._active_queue_job_id and (
            self._tasks.is_running() or self._is_in_copy_cooldown()
        ):
            return " - Quiesce"
        return " - HOLD"

    def _emit_jobs_pane_title_changed(self) -> None:
        self.jobs_pane_title_changed.emit()

    def has_pending_work(self) -> bool:
        return bool(self._queue) or self.is_running()

    @property
    def active_queue_job_id(self) -> str:
        return self._active_queue_job_id

    def active_job_full_prompt(self) -> str:
        from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

        return effective_job_prompt_for_tooltip(self._active_job_card_values())

    def _active_job_card_shows_next_copy(self) -> bool:
        """True when the active card should preview the copy after the in-flight one."""
        if not self._copy_batch_active or not self._active_queue_job_id:
            return False
        # Generation worker only — AI stage keeps the current-copy card/progress UI.
        return (
            self._tasks.is_running()
            and self.active_series_remaining_after() > 0
        )

    def _active_job_card_values(self) -> Dict[str, Any]:
        """Settings shown on the active job card."""
        if self._active_job_card_shows_next_copy() and self._next_copy_display_values:
            return dict(self._next_copy_display_values)
        return dict(self._pending_values)

    def _active_job_card_source_paths(self) -> list[str]:
        from imagegen_plugins.image_gen_naming import resolve_source_image_paths

        values = self._active_job_card_values()
        return [
            p
            for p in resolve_source_image_paths(values)
            if p and os.path.isfile(p)
        ]

    def _active_job_card_thumbnail_paths(self) -> list[str]:
        plugin = self._active_plugin
        if plugin is None:
            return list(self._active_thumbnail_paths)
        paths = thumbnail_paths_for_values(plugin, self._active_job_card_values())
        return paths or list(self._active_thumbnail_paths)

    def _advance_next_copy_display_for_in_flight(self) -> None:
        """Once a copy is in flight, the card previews the following copy."""
        if self.active_series_remaining_after() > 0:
            self._next_copy_display_values = dict(self._pending_values)
        else:
            self._next_copy_display_values = {}

    def _sync_next_copy_display_from_pending(self) -> None:
        """Keep the card preview aligned after edits to pending copy settings."""
        if self._active_job_card_shows_next_copy():
            self._next_copy_display_values = dict(self._pending_values)

    def _sync_next_copy_chain_from_completed_cycle(
        self,
        completed_copy_values: Dict[str, Any],
        *,
        output_path: str = "",
    ) -> None:
        """Legacy hook; chain resolution happens in resolve_step_before_run."""
        if output_path and os.path.isfile(output_path):
            self._last_completed_output_path = output_path
        prompt = str(completed_copy_values.get("prompt") or "").strip()
        if prompt:
            self._last_completed_prompt = prompt
        self._last_completed_values = dict(completed_copy_values)
        self._sync_next_copy_display_from_pending_steps()
        self._clear_copy_cycle_exif_snapshot()

    def _apply_replaced_job_values_to_active(
        self, plugin: ImageGenModelPlugin, values: Dict[str, Any]
    ) -> None:
        """Apply unified-dialog Replace to pending values and live display state."""
        from imagegen_plugins.flux_prompt_job import (
            has_flux_prompt_ai_job,
            normalize_replaced_job_values,
        )
        from imagegen_plugins.image_gen_naming import resolve_source_image_paths
        from imagegen_plugins.job_values_snapshot import preserve_job_queue_only_keys

        preserve_job_queue_only_keys(values, self._pending_values)
        normalize_replaced_job_values(values)
        in_flight = self._step_running is not None
        if in_flight:
            merged = dict(self._pending_values)
            merged.update(values)
            merged["copies"] = self._copies_total
            self._pending_values = merged
        else:
            self._pending_values = dict(values)
        self._active_plugin = plugin
        self._active_job_with_ai = has_flux_prompt_ai_job(values) or bool(
            values.get("series_prompt_refinement")
        )
        thumbs = thumbnail_paths_for_values(plugin, values)
        if thumbs:
            self._active_thumbnail_paths = list(thumbs)
        paths = [
            p for p in resolve_source_image_paths(values) if p and os.path.isfile(p)
        ]
        if paths:
            self._expand_source_path = paths[0]
            self._task_reference_paths = list(paths)
        elif not self._active_job_card_shows_next_copy():
            self._expand_source_path = ""
            self._task_reference_paths = []
        if in_flight:
            self._sync_next_copy_display_from_pending_steps()
        else:
            self._sync_next_copy_display_from_pending()

    def _sync_active_job_queue_row(
        self,
        plugin: ImageGenModelPlugin,
        values: Dict[str, Any],
        copies_total: int,
    ) -> None:
        """Keep the queued row aligned while this job is active (pre-worker pop)."""
        job_id = self._active_queue_job_id
        if not job_id:
            return
        job = self._queued_job_by_id(job_id)
        if job is None:
            return
        from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip
        from imagegen_plugins.model_task_queue import refresh_queued_job_status

        job.plugin = plugin
        job.plugin_id = plugin.plugin_id
        job.function = plugin.function
        job.plugin_unavailable = False
        job.values = dict(values)
        job.copies_total = copies_total
        job.full_prompt = effective_job_prompt_for_tooltip(values)
        thumbs = thumbnail_paths_for_values(plugin, values)
        if thumbs:
            job.thumbnail_paths = list(thumbs)
        refresh_queued_job_status(job)

    def _invalidate_pending_queue_snapshot_cache(self, *_args) -> None:
        self._cached_pending_queue_key = None
        self._cached_pending_rows = None

    def _pending_queue_snapshot_rows(self) -> list[QueueRowSnapshot]:
        def _view_key(view) -> tuple | None:
            if view is None:
                return None
            fp = getattr(view, "fingerprint", None)
            return fp() if callable(fp) else None

        key = tuple(
            (job.job_id, _view_key(job.status_view), job.full_prompt)
            for job in self._queue
        )
        if (
            self._cached_pending_queue_key == key
            and self._cached_pending_rows is not None
        ):
            return self._cached_pending_rows
        pending_rows: list[QueueRowSnapshot] = []
        for job in self._queue:
            pending_rows.append(
                QueueRowSnapshot(
                    job_id=job.job_id,
                    is_active=False,
                    status_html=job.status_html,
                    thumbnail_paths=list(job.thumbnail_paths),
                    full_prompt=job.full_prompt,
                    references_invalid=job.references_invalid,
                    status_view=job.status_view,
                )
            )
        self._cached_pending_queue_key = key
        self._cached_pending_rows = pending_rows
        return pending_rows

    def queue_snapshot(self) -> list[QueueRowSnapshot]:
        pending_rows = list(self._pending_queue_snapshot_rows())
        if not self._active_queue_job_id:
            return pending_rows
        # Active job stays in ``_queue`` until the generate worker accepts the launch.
        pending_rows = [
            row
            for row in pending_rows
            if row.job_id != self._active_queue_job_id
        ]
        active_row = QueueRowSnapshot(
            job_id=self._active_queue_job_id,
            is_active=True,
            status_html=self._task_status_info_html,
            thumbnail_paths=self._active_job_card_thumbnail_paths(),
            full_prompt=self.active_job_full_prompt(),
            status_view=self._task_status_view,
        )
        insert_at = max(0, min(self._active_display_index, len(pending_rows)))
        rows = list(pending_rows)
        rows.insert(insert_at, active_row)
        return rows

    def selected_job_id(self) -> str | None:
        return self._selected_job_id

    def set_selected_job_id(self, job_id: str | None) -> None:
        job_id = str(job_id).strip() if job_id else None
        if job_id == self._selected_job_id:
            return
        self._selected_job_id = job_id or None

    def row_index_for_job_id(self, job_id: str) -> int:
        for idx, row in enumerate(self.queue_snapshot()):
            if row.job_id == job_id:
                return idx
        return -1

    def resolve_selected_row_index(self) -> int:
        rows = self.queue_snapshot()
        if not rows:
            self._selected_job_id = None
            return -1
        if self._selected_job_id:
            for idx, row in enumerate(rows):
                if row.job_id == self._selected_job_id:
                    return idx
        self._selected_job_id = None
        return -1

    def job_row_supports_image_series_refinement(self, row: int) -> bool:
        record = self.job_record_for_row(row)
        if record is None:
            return False
        plugin, values = record
        if self._job_record_is_infill(plugin, values):
            return False
        from imagegen_plugins.image_gen_active_model import FUNCTION_CREATE, FUNCTION_EDIT
        from imagegen_plugins.image_gen_pipeline_modes import (
            pipeline_supports_series_image_refinement,
        )

        if plugin.function == FUNCTION_EDIT:
            paths = resolve_source_image_paths(values)
            return bool(paths)
        if plugin.function == FUNCTION_CREATE:
            return pipeline_supports_series_image_refinement(plugin.pipeline_id)
        return False

    def job_row_supports_text_series_refinement(self, row: int) -> bool:
        record = self.job_record_for_row(row)
        if record is None:
            return False
        plugin, values = record
        if self._job_record_is_infill(plugin, values):
            return False
        from imagegen_plugins.image_gen_active_model import (
            FUNCTION_CREATE,
            FUNCTION_EDIT,
            FUNCTION_EXPAND,
        )
        from imagegen_plugins.lmstudio_caption import (
            get_lmstudio_ui_available,
            is_lmstudio_sdk_installed,
        )

        if not is_lmstudio_sdk_installed():
            return False
        if not get_lmstudio_ui_available():
            return False
        return plugin.function in (FUNCTION_CREATE, FUNCTION_EDIT, FUNCTION_EXPAND)

    def _job_record_is_infill(self, plugin, values: dict) -> bool:
        from imagegen_plugins.image_gen_active_model import (
            FUNCTION_INFILL,
            FUNCTION_INFILL_PAINT,
        )

        if plugin.function in (FUNCTION_INFILL, FUNCTION_INFILL_PAINT):
            return True
        return plugin.pipeline_id == "mflux_fill_infill"

    def move_job_before(self, job_id: str, before_job_id: str | None) -> bool:
        """Move a queue row to the display slot immediately before ``before_job_id``."""
        if not job_id:
            return False
        if before_job_id is not None and before_job_id == job_id:
            return False
        rows = self.queue_snapshot()
        target_display_row = len(rows)
        if before_job_id is not None:
            target_display_row = self.row_index_for_job_id(before_job_id)
            if target_display_row < 0:
                return False
        return self.move_job_to_display_row(job_id, target_display_row)

    def move_job_to_display_row(self, job_id: str, target_display_row: int) -> bool:
        """Move any queue row (including the active job) to a display insert index."""
        rows = self.queue_snapshot()
        if not rows or not job_id:
            return False
        from_row = self.row_index_for_job_id(job_id)
        if from_row < 0:
            return False
        target_display_row = max(0, min(int(target_display_row), len(rows)))
        if from_row == target_display_row:
            return False
        ids = [row.job_id for row in rows]
        ids.pop(from_row)
        insert_at = (
            target_display_row
            if target_display_row <= from_row
            else target_display_row - 1
        )
        insert_at = max(0, min(insert_at, len(ids)))
        ids.insert(insert_at, job_id)
        active_id = self._active_queue_job_id
        new_queue: list[QueuedGenerateJob] = []
        new_active_index = 0
        for idx, jid in enumerate(ids):
            if jid == active_id:
                new_active_index = idx
            job = self._queued_job_by_id(jid)
            if job is not None:
                new_queue.append(job)
        if len(new_queue) != len(self._queue):
            return False
        self._queue = new_queue
        if active_id:
            self._active_display_index = new_active_index
        if self._yield_active_if_superseded_by_reorder():
            self._schedule_persist_job_queue()
            return True
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def job_record_for_row(
        self, row: int
    ) -> tuple[ImageGenModelPlugin, Dict[str, Any]] | None:
        """Return (plugin, values) for a queue table row (active or pending)."""
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return None
        entry = rows[row]
        if entry.is_active:
            plugin = self._active_plugin
            if plugin is None:
                return None
            doc = self._step_pending_doc
            steps = doc.get("steps") if isinstance(doc, dict) else None
            if isinstance(steps, list) and steps:
                return plugin, merge_step_into_values(steps[0])
            return plugin, dict(self._pending_values)
        for job in self._queue:
            if job.job_id == entry.job_id:
                if job.plugin is None:
                    return None
                return job.plugin, dict(job.values)
        return None

    def start_generation(
        self, plugin: ImageGenModelPlugin, values: Dict[str, Any]
    ) -> bool:
        from imagegen_plugins.job_values_snapshot import (
            snapshot_job_values_at_submit,
            strip_dialog_leaked_job_queue_flags,
        )

        copies = self._normalize_copies(values.get("copies", 1))
        values = dict(values)
        values["copies"] = copies
        strip_dialog_leaked_job_queue_flags(values)
        from imagegen_plugins.flux_prompt_job import strip_flux_prompt_ai_job_if_ui_inactive

        # Collapsed AI section => no Job AI on initial Generate (matches _prepare_run_values).
        strip_flux_prompt_ai_job_if_ui_inactive(self._imagegen_submit_owner(), values)
        if copies > 1 and not values.get("random_seed"):
            if not apply_copies_random_seed_choice(
                self.main_window,
                values,
                prompt_enable_random_seed_for_copies(self.main_window),
            ):
                return False

        try:
            values = snapshot_job_values_at_submit(plugin, values)
        except Exception as e:
            show_styled_critical(
                self.main_window,
                "Could not start job",
                str(e),
            )
            return False

        if self.is_running():
            return self.enqueue_generation(plugin, values)

        if self._hold_job_queue and self._generation_pipeline_idle():
            return self.enqueue_generation(plugin, values)

        return self._start_generation_now(plugin, values) is not False

    def _imagegen_submit_owner(self) -> Any | None:
        """Open image-gen dialog or active unified panel (for flux AI UI gating)."""
        dlg = getattr(self.main_window, "_imagegen_function_dialog", None)
        if dlg is None:
            return None
        panel = getattr(dlg, "_current_panel", None)
        return panel if panel is not None else dlg

    def enqueue_generation(
        self, plugin: ImageGenModelPlugin, values: Dict[str, Any]
    ) -> bool:
        from imagegen_plugins.job_values_snapshot import (
            job_values_snapshotted,
            snapshot_job_values_at_submit,
            strip_dialog_leaked_job_queue_flags,
        )

        copies = self._normalize_copies(values.get("copies", 1))
        values = dict(values)
        values["copies"] = copies
        if not job_values_snapshotted(values):
            strip_dialog_leaked_job_queue_flags(values)
        from imagegen_plugins.flux_prompt_job import strip_flux_prompt_ai_job_if_ui_inactive

        # Collapsed AI section => no Job AI (same rule as dialog _prepare_run_values).
        strip_flux_prompt_ai_job_if_ui_inactive(self._imagegen_submit_owner(), values)
        if not job_values_snapshotted(values):
            try:
                values = snapshot_job_values_at_submit(plugin, values)
            except Exception as e:
                show_styled_critical(
                    self.main_window,
                    "Could not queue job",
                    str(e),
                )
                return False
        try:
            steps = materialize_steps(plugin, values, copies)
            job = make_queued_generate_job(
                plugin, values, copies_total=copies, steps=steps
            )
            self._normalize_queued_job_copies(job)
        except Exception as e:
            show_styled_critical(
                self.main_window,
                "Could not queue job",
                str(e),
            )
            return False
        self._queue.append(job)
        self.queue_changed.emit()
        self._sync_cancel_menu()
        self._persist_job_queue_now()
        return True

    def is_queued_job_replaceable(self, job_id: str) -> bool:
        if not job_id or job_id == self._active_queue_job_id:
            return False
        return self._queued_job_by_id(job_id) is not None

    def copies_for_job_editor(self, job_id: str) -> int | None:
        """Copies count for the job editor slider.

        Queued jobs: batch total. Active job: remaining images (includes in-flight).
        """
        if not job_id:
            return None
        if job_id == self._active_queue_job_id:
            if self._is_series_continuous_total(self._copies_total):
                return _SERIES_CONTINUOUS_COPIES
            return max(1, int(self._copies_total) - int(self._copies_done))
        job = self._queued_job_by_id(job_id)
        if job is None:
            return None
        if self._is_series_continuous_total(job.copies_total):
            return _SERIES_CONTINUOUS_COPIES
        return max(1, int(job.copies_total))

    def active_job_future_copies_updatable(self) -> int:
        """Pending batch copies that can still pick up updated settings.

        The in-flight step is already popped from the pending doc, so ``pending``
        counts only copies not yet started (including during AI/gen on the current copy).
        """
        if not self._active_queue_job_id:
            return 0
        if (
            self._copy_batch_active
            and self._is_series_continuous_total(self._copies_total)
        ):
            return 1
        return self._pending_batch_copies()

    def is_active_job_remaining_updatable(self, job_id: str) -> bool:
        if not job_id or job_id != self._active_queue_job_id:
            return False
        return self.active_job_future_copies_updatable() > 0

    def queue_replace_job_still_exists(self, job_id: str) -> bool:
        """True while *job_id* is still the active or a queued replace/update target."""
        if not job_id:
            return False
        if job_id == self._active_queue_job_id:
            return True
        return self._queued_job_by_id(job_id) is not None

    def update_active_job_remaining(
        self, job_id: str, plugin: ImageGenModelPlugin, values: Dict[str, Any]
    ) -> bool:
        """Update settings for pending copies in the active batch (not the in-flight copy).

        Dialog ``values["copies"]`` is remaining images (see ``copies_for_job_editor``);
        it is converted to batch total before updating queue state.
        """
        from imagegen_plugins.job_values_snapshot import snapshot_job_values_at_submit

        if not self.is_active_job_remaining_updatable(job_id):
            return False
        values = dict(values)
        in_progress = (
            1 if (self._tasks.is_running() or self._job_ai_stage_active) else 0
        )
        remaining = self._normalize_copies(values.get("copies", 1))
        if in_progress:
            remaining = max(1, remaining)
        copies = self._copies_done + remaining
        values["copies"] = copies
        future = copies - self._copies_done - in_progress
        if future > 1 and not values.get("random_seed"):
            if not apply_copies_random_seed_choice(
                self.main_window,
                values,
                prompt_enable_random_seed_for_copies(self.main_window),
            ):
                return False
            # "No" resets the slider to 1 remaining; "Yes" leaves batch total in values.
            if int(values.get("copies", 1) or 1) <= 1:
                remaining = max(1, int(values.get("copies", 1) or 1))
                copies = self._copies_done + remaining
                values["copies"] = copies
        from imagegen_plugins.flux_prompt_job import (
            normalize_replaced_job_values,
            strip_flux_prompt_ai_job_if_ui_inactive,
            sync_owner_prompt_into_values,
        )

        owner = self._imagegen_submit_owner()
        sync_owner_prompt_into_values(owner, values)
        # Collapsed AI section => no Job AI on active-job Update (matches Generate).
        strip_flux_prompt_ai_job_if_ui_inactive(owner, values)
        normalize_replaced_job_values(values)
        try:
            values = snapshot_job_values_at_submit(plugin, values)
        except Exception as e:
            show_styled_critical(
                self.main_window,
                "Could not update job",
                str(e),
            )
            return False
        self._copies_total = copies
        if self._is_series_continuous_total(copies):
            self._copy_batch_active = True
        else:
            self._copy_batch_active = copies > 1 or self._copies_done > 0
        self._sync_copies_done_display()
        self._apply_replaced_job_values_to_active(plugin, values)
        future = max(0, copies - self._copies_done - in_progress)
        self._rewrite_active_pending_steps(plugin, values, future)
        self._sync_active_job_queue_row(plugin, values, copies)
        self._task_status_info_html = self.get_task_queue_status_info_html()
        self.task_status_info_changed.emit()
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def replace_queued_job(
        self, job_id: str, plugin: ImageGenModelPlugin, values: Dict[str, Any]
    ) -> bool:
        """Update a pending queue entry in place (same job_id and position)."""
        from imagegen_plugins.flux_prompt_job import (
            effective_job_prompt_for_tooltip,
            normalize_replaced_job_values,
            strip_flux_prompt_ai_job_if_ui_inactive,
            sync_owner_prompt_into_values,
        )
        from imagegen_plugins.job_values_snapshot import (
            preserve_job_queue_only_keys,
            snapshot_job_values_at_submit,
        )

        job = self._queued_job_by_id(job_id)
        if job is None:
            return False
        copies = self._normalize_copies(values.get("copies", 1))
        values = dict(values)
        values["copies"] = copies
        if copies > 1 and not values.get("random_seed"):
            if not apply_copies_random_seed_choice(
                self.main_window,
                values,
                prompt_enable_random_seed_for_copies(self.main_window),
            ):
                return False
            copies = self._normalize_copies(values.get("copies", 1))
            values["copies"] = copies
        owner = self._imagegen_submit_owner()
        sync_owner_prompt_into_values(owner, values)
        # Collapsed AI section => no Job AI on queued-job Replace (matches Generate).
        strip_flux_prompt_ai_job_if_ui_inactive(owner, values)
        try:
            values = snapshot_job_values_at_submit(plugin, values)
        except Exception as e:
            show_styled_critical(
                self.main_window,
                "Could not update queued job",
                str(e),
            )
            return False
        preserve_job_queue_only_keys(values, job.values)
        normalize_replaced_job_values(values)
        steps = materialize_steps(plugin, values, copies)
        job.plugin = plugin
        job.plugin_id = plugin.plugin_id
        job.function = plugin.function
        job.plugin_unavailable = False
        job.values = values
        job.copies_total = copies
        job.steps = steps
        job.thumbnail_paths = thumbnail_paths_for_values(plugin, values)
        job.full_prompt = effective_job_prompt_for_tooltip(values)
        job.references_invalid = job_references_invalid(plugin, values)
        self._normalize_queued_job_copies(job)
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._sync_cancel_menu()
        self._schedule_persist_job_queue()
        return True

    def cancel_queued_job(self, job_id: str) -> None:
        before = len(self._queue)
        self._queue = [job for job in self._queue if job.job_id != job_id]
        if len(self._queue) != before:
            self.queue_changed.emit()
            self._sync_cancel_menu()
            self._schedule_persist_job_queue()

    def cancel_job_at_row(self, row: int) -> None:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return
        entry = rows[row]
        if entry.is_active:
            self.cancel_active_job()
        else:
            self.cancel_queued_job(entry.job_id)

    def cancel_jobs_from_row_and_subsequent(self, row: int) -> None:
        """Remove the queue row and every row after it (no confirmation)."""
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return
        suffix = rows[row:]
        active_in_suffix = any(entry.is_active for entry in suffix)
        pending_remove = {entry.job_id for entry in suffix if not entry.is_active}
        if pending_remove:
            self._queue = [job for job in self._queue if job.job_id not in pending_remove]
            self.queue_changed.emit()
            self._sync_cancel_menu()
            self._schedule_persist_job_queue()
        if active_in_suffix:
            self.cancel_active_job()

    def confirm_cancel_job_at_row(self, parent=None, row: int = -1) -> bool:
        """Confirm cancel/remove for a queue row; runs the action if user chooses Yes."""
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        entry = rows[row]
        if entry.is_active:
            prompt = "Cancel the running job?"
            proceed_note = _CANCEL_PROCEED_NOTE
        else:
            prompt = "Remove this job from the queue?"
            proceed_note = _REMOVE_PROCEED_NOTE
        parent = parent or self.main_window
        answer = show_styled_question(
            parent,
            "Cancel job?",
            prompt,
            default_no=True,
            proceed_note=proceed_note,
            on_proceed=lambda r=row: self.cancel_job_at_row(r),
        )
        return answer == QMessageBox.StandardButton.Yes

    def confirm_cancel_generation(self, parent=None) -> bool:
        """Confirm cancel of the active generation/caption; runs cancel if user chooses Yes."""
        if not self.is_running():
            return False
        parent = parent or self.main_window
        answer = show_styled_question(
            parent,
            "Cancel job?",
            "Cancel the running job?",
            default_no=True,
            proceed_note=_CANCEL_PROCEED_NOTE,
            on_proceed=self.cancel_active_job,
        )
        from imagegen_plugins.job_queue_common import schedule_restore_main_canvas_focus

        schedule_restore_main_canvas_focus(self.main_window)
        return answer == QMessageBox.StandardButton.Yes

    def cancel_active_job(self) -> None:
        self.cancel_generation(entire_job=True)

    @staticmethod
    def _normalize_copies(raw: Any) -> int:
        try:
            copies = int(raw)
        except (TypeError, ValueError):
            copies = 1
        copies = max(_COPIES_MIN, min(_COPIES_MAX, copies))
        if is_series_continuous_copies(copies):
            return _SERIES_CONTINUOUS_COPIES
        return copies

    @staticmethod
    def _is_series_continuous_total(copies_total: int) -> bool:
        return is_series_continuous_copies(copies_total)

    def _active_job_is_continuous(self) -> bool:
        return (
            self._is_series_continuous_total(self._copies_total)
            or pending_doc_is_continuous(self._step_pending_doc, self._step_running)
        )

    def _queued_job_is_continuous(self, job: QueuedGenerateJob) -> bool:
        if self._is_series_continuous_total(job.copies_total):
            return True
        try:
            if self._is_series_continuous_total(int(job.values.get("copies", 0) or 0)):
                return True
        except (TypeError, ValueError):
            pass
        steps = job.steps
        if isinstance(steps, list) and steps:
            return pending_doc_is_continuous({"steps": steps})
        return False

    @staticmethod
    def _stamp_series_copies_on_steps(steps: list[dict], copies: int) -> None:
        for step in steps:
            values = step_values(step)
            values["copies"] = copies
            step["values"] = values

    def _sync_copies_done_display(self) -> None:
        if self._is_series_continuous_total(self._copies_total):
            self._copies_done = 0
        else:
            self._copies_done = self._steps_done

    @staticmethod
    def _pipeline_supports_quantization(
        plugin: ImageGenModelPlugin, values: Dict[str, Any] | None = None
    ) -> bool:
        return plugin.plugin_reports_quantization(values)

    def _start_generation_now(
        self,
        plugin: ImageGenModelPlugin,
        values: Dict[str, Any],
        *,
        job_id: str | None = None,
        status_html: str | None = None,
        thumbnail_paths: list[str] | None = None,
        from_queue: bool = False,
    ) -> bool | None:
        copies = self._normalize_copies(values.get("copies", 1))
        values = dict(values)
        values["copies"] = copies

        self._active_queue_job_id = job_id or uuid.uuid4().hex
        self._active_display_index = 0
        self._active_thumbnail_paths = list(
            thumbnail_paths if thumbnail_paths is not None
            else thumbnail_paths_for_values(plugin, values)
        )

        self._copies_total = copies
        self._copies_done = 0
        self._copy_batch_active = copies > 1
        self._copy_batch_cancelled = False
        self._skip_series_copy_requested = False
        self._stop_copy_cooldown_timer()
        self._reset_active_job_progress_tracking()
        self._job_ai_stage_active = False
        self._active_job_with_ai = False
        self._task_status_info_html = ""

        self._active_plugin = plugin
        self._pending_values = values
        self._next_copy_display_values = dict(values)
        self._progressive_browse_opened = False

        job = self._queued_job_by_id(self._active_queue_job_id) if from_queue else None
        step_list = list(job.steps) if job is not None and job.steps else None
        self._init_active_job_steps(
            plugin,
            values,
            copies,
            thumbnail_paths=self._active_thumbnail_paths,
            steps=step_list,
        )
        if not self._promote_next_step_to_running(plugin):
            if from_queue:
                self._abort_queued_job_start()
            return False

        if status_html:
            pass  # queue pane rebuilds compact HTML from live controller state

        self.queue_changed.emit()
        self.task_status_info_changed.emit()
        self._update_live_status_timer()
        if self._pending_job_needs_ai_stage():
            result = self._begin_job_ai_stage()
            if result is False and from_queue:
                self._abort_queued_job_start()
            return result
        result = self._launch_generation_job(
            manage_batch_on_failure=not from_queue,
            from_queue=from_queue,
            queue_job_id=self._active_queue_job_id if from_queue else None,
        )
        if result is False and from_queue:
            if self._tasks.is_running():
                return result
            self._abort_queued_job_start()
        return result

    def _pending_job_needs_ai_stage(self) -> bool:
        if self._step_running is not None:
            return step_needs_ai(self._step_running)
        return False

    def active_job_timing_steps_label(self) -> str:
        return "AI:" if self._job_ai_stage_active else "Steps:"

    def _start_job_ai_progress_tracking(self) -> None:
        from imagegen_plugins.model_task_status_info import _AI_REFINE_PROGRESS_TOTAL

        self._reset_active_job_progress_tracking()
        self._step_progress_start_time = time.perf_counter()
        self._live_step = 0
        self._live_step_total = _AI_REFINE_PROGRESS_TOTAL

    def _refresh_job_ai_stage_status_html(self, *, running: bool) -> None:
        if self._active_job_card_shows_next_copy():
            self._task_status_info_html = self.get_task_queue_status_info_html()
            self.task_status_info_changed.emit()
            return
        from imagegen_plugins.model_task_status_info import (
            format_job_ai_stage_queue_status_html,
        )

        plugin = self._active_plugin
        if plugin is None:
            return
        elapsed, estimate = self._snapshot_live_timing(in_cooldown=False)
        if elapsed is None:
            elapsed = self._wall_clock_elapsed_seconds(in_cooldown=False)
        step = self._live_step if self._live_step_total > 0 else None
        step_total = self._live_step_total if self._live_step_total > 0 else None
        self._task_status_info_html = format_job_ai_stage_queue_status_html(
            plugin,
            self._pending_values,
            running=running,
            step=step,
            step_total=step_total,
            elapsed_seconds=elapsed,
            estimate_seconds=estimate,
        )
        self.task_status_info_changed.emit()

    def _begin_job_ai_stage(self) -> bool:
        from imagegen_plugins.flux_prompt_job import flux_prompt_ai_job_meta

        plugin = self._active_plugin
        if plugin is None or self._step_running is None:
            return self._launch_generation_job() is not False
        if not prepare_step_ai_launch(self._step_running):
            self._fail_job_ai_stage(
                "Could not prepare AI prompt refinement for the job."
            )
            return False
        self._sync_pending_values_from_running_step()
        self._step_running_doc = build_running_job_doc(
            job_id=self._active_queue_job_id,
            plugin=plugin,
            step=self._step_running,
        )
        self._persist_step_job_files()
        meta = flux_prompt_ai_job_meta(self._pending_values)
        if meta is None:
            self._fail_job_ai_stage(
                "Could not prepare AI prompt refinement for the job."
            )
            return False

        self._job_ai_stage_active = True
        self._active_job_with_ai = True
        self._advance_next_copy_display_for_in_flight()
        self._start_job_ai_progress_tracking()

        system_prompt = str(meta.get("system_prompt") or "")
        user_prompt = str(meta.get("user_prompt") or "")
        image_paths = list(meta.get("image_paths") or [])
        from imagegen_plugins.job_values_snapshot import job_values_snapshotted

        if image_paths and not job_values_snapshotted(self._pending_values):
            from imagegen_plugins.image_gen_naming import resolve_source_image_paths

            refreshed = [
                p
                for p in resolve_source_image_paths(self._pending_values)
                if p and os.path.isfile(p)
            ]
            if refreshed:
                image_paths = refreshed
        thumb_paths = [
            os.path.normpath(p)
            for p in image_paths
            if p and os.path.isfile(str(p))
        ]
        if thumb_paths:
            self._active_thumbnail_paths = list(thumb_paths)
        self._refresh_job_ai_stage_status_html(running=False)
        self.generation_started.emit()

        if not self._tasks.start_flux_prompt_job(
            system_prompt,
            user_prompt,
            image_paths=image_paths,
        ):
            self._fail_job_ai_stage("Could not start AI prompt refinement for the job.")
            return False
        return True

    def _complete_job_ai_stage(self, refined_prompt: str) -> None:
        self._job_ai_stage_active = False
        self._launch_refined_prompt = (refined_prompt or "").strip()
        plugin = self._active_plugin
        if plugin is not None:
            self._task_status_info_html = self.get_task_queue_status_info_html()
            self.task_status_info_changed.emit()
        QTimer.singleShot(0, self._launch_generation_after_job_ai)

    def _launch_generation_after_job_ai(self) -> None:
        if self._active_plugin is None:
            self._finish_copy_batch()
            return
        result = self._launch_generation_job()
        if result is False:
            self._finish_copy_batch()

    def _start_next_copy_cycle(self) -> bool:
        """Run AI prompt refinement (when configured) then the next generation copy."""
        plugin = self._active_plugin
        if plugin is None:
            return False
        if self._step_running is None:
            if not self._promote_next_step_to_running(plugin):
                return False
        if self._pending_job_needs_ai_stage():
            return self._begin_job_ai_stage()
        return self._launch_generation_job() is not False

    def _fail_job_ai_stage(self, error_message: str) -> None:
        self._job_ai_stage_active = False
        if (
            not self._suppress_task_failure_ui
            and error_message
            and error_message != "Cancelled"
        ):
            show_styled_critical(
                self.main_window,
                "AI prompt job failed",
                error_message[:4000],
            )
        cancelled = error_message == "Cancelled"
        if cancelled and not self._copy_batch_cancelled:
            remaining = pending_step_count(self._step_pending_doc)
            if self._is_series_continuous_total(self._copies_total) or remaining > 0:
                self._skip_series_copy_requested = False
                self._continue_after_aborted_step()
                return
        self.generation_finished.emit(False, "", error_message)
        self._finish_copy_batch(cancelled=cancelled)

    def _generation_launch_abandoned(
        self, *, from_queue: bool, queue_job_id: str | None
    ) -> bool:
        """True when a deferred launch should stop (cancel, reset, or queue moved)."""
        if self._copy_batch_cancelled or self._queue_advance_suppressed:
            return True
        if self._active_plugin is None:
            return True
        if from_queue and queue_job_id:
            if not self._active_queue_job_id:
                return True
            if self._active_queue_job_id != queue_job_id:
                return True
        return False

    def _defer_until_worker_cleanup(
        self,
        *,
        worker_wait_attempts: int,
        manage_batch_on_failure: bool,
        from_queue: bool,
        queue_job_id: str | None,
    ) -> bool | None:
        """Wait for the previous worker to exit. Frozen inline threads cannot be killed."""
        if self._generation_launch_abandoned(
            from_queue=from_queue, queue_job_id=queue_job_id
        ):
            self._set_gpu_cleanup_status(False)
            return False
        killable = self._tasks.worker_is_killable()
        if killable and worker_wait_attempts >= self._GPU_CLEANUP_MAX_ATTEMPTS:
            self._tasks.force_terminate_worker()
            self._release_main_process_gpu_memory()
            if not self._tasks.worker_needs_cleanup():
                return True
            return False
        self._set_gpu_cleanup_status(True)
        if not killable and worker_wait_attempts == 0 and not from_queue:
            self._tasks.nudge_worker_shutdown()
        QTimer.singleShot(
            self._GPU_CLEANUP_POLL_MS,
            lambda: self._launch_generation_job(
                _worker_wait_attempts=worker_wait_attempts + 1,
                manage_batch_on_failure=manage_batch_on_failure,
                from_queue=from_queue,
                queue_job_id=queue_job_id,
            ),
        )
        return None

    def _launch_generation_job(
        self,
        *,
        _worker_wait_attempts: int = 0,
        manage_batch_on_failure: bool = True,
        from_queue: bool = False,
        queue_job_id: str | None = None,
    ) -> bool | None:
        plugin = self._active_plugin
        if self._copy_cycle_values:
            values = dict(self._copy_cycle_values)
        elif self._step_running is not None:
            values = merge_step_into_values(self._step_running)
        else:
            values = dict(self._pending_values)
        refined = (self._launch_refined_prompt or "").strip()
        if refined:
            values["prompt"] = refined
        if plugin is None:
            return False
        if self._generation_launch_abandoned(
            from_queue=from_queue, queue_job_id=queue_job_id
        ):
            self._set_gpu_cleanup_status(False)
            return False

        if self._tasks.worker_needs_cleanup():
            waited = self._defer_until_worker_cleanup(
                worker_wait_attempts=_worker_wait_attempts,
                manage_batch_on_failure=manage_batch_on_failure,
                from_queue=from_queue,
                queue_job_id=queue_job_id,
            )
            if waited is None:
                return None
            if waited is True:
                return self._launch_generation_job(
                    _worker_wait_attempts=0,
                    manage_batch_on_failure=manage_batch_on_failure,
                    from_queue=from_queue,
                    queue_job_id=queue_job_id,
                )
            self._set_gpu_cleanup_status(False)
            show_styled_critical(
                self.main_window,
                "Generation failed",
                "The previous model is still releasing GPU memory. "
                "Wait a moment and try again.",
            )
            if manage_batch_on_failure:
                self._finish_copy_batch()
            return False

        self._set_gpu_cleanup_status(False)
        self._release_main_process_gpu_memory()

        output_path = next_imagegen_path(ext=output_extension_from_settings())
        try:
            payload = plugin.build_payload(values, output_path)
            pad_temps = payload.pop("_aspect_pad_temp_paths", None)
            if isinstance(pad_temps, list) and pad_temps:
                self._aspect_pad_temp_paths.extend(str(p) for p in pad_temps)
            canonical_from_payload = payload.pop("_canonical_source_image_paths", None)
            self._expand_base_path = ""
            if plugin.pipeline_id == "mflux_fill_expand":
                from imagegen_plugins.image_gen_dim_limits import effective_max_for_plugin
                from imagegen_plugins.job_values_snapshot import job_values_snapshotted

                expand_values = dict(values)
                max_side = effective_max_for_plugin(plugin)
                if job_values_snapshotted(values):
                    snap_max = values.get("max_generation_dimension")
                    if snap_max is not None:
                        try:
                            max_side = int(snap_max)
                        except (TypeError, ValueError):
                            pass
                expand_values["max_generation_dimension"] = max_side
                base_path = prepare_and_save_expand_base(expand_values, output_path)
                payload["prepared_fill_image_path"] = base_path
                self._expand_base_path = base_path
            elif plugin.pipeline_id == "mflux_fill_infill":
                from imagegen_plugins.pixelmator_export import (
                    missing_infill_export_paths,
                )

                missing_infill = missing_infill_export_paths(values)
                if missing_infill:
                    preview = "\n".join(f"• {p}" for p in missing_infill[:4])
                    show_styled_critical(
                        self.main_window,
                        "Infill",
                        "Infill base image or mask is missing on disk. "
                        "Paint a mask and generate again, or re-export from Pixelmator Pro.\n\n"
                        f"{preview}",
                    )
                    if manage_batch_on_failure:
                        self._finish_copy_batch()
                    return False
            from imagegen_plugins.image_gen_pipeline_modes import job_run_uses_source_image

            if job_run_uses_source_image(plugin.pipeline_id, values):
                worker_source_paths = source_paths_for_generation_exif(payload)
                if isinstance(canonical_from_payload, list) and canonical_from_payload:
                    canonical_source_paths = source_paths_for_generation_exif(
                        {"source_image_paths": canonical_from_payload}
                    )
                else:
                    canonical_source_paths = source_paths_for_generation_exif(values)
                display_paths = canonical_source_paths or worker_source_paths
                if canonical_source_paths:
                    values["_canonical_source_image_paths"] = list(
                        canonical_source_paths
                    )
                    values["source_image_path"] = canonical_source_paths[0]
                    values["source_image_paths"] = list(canonical_source_paths)
                if display_paths:
                    self._expand_source_path = display_paths[0]
                    self._task_reference_paths = list(display_paths)
                else:
                    self._expand_source_path = ""
                    self._task_reference_paths = []
            else:
                from imagegen_plugins.flux_prompt_job import (
                    flux_prompt_ai_reference_image_paths,
                )

                ai_ref_paths = flux_prompt_ai_reference_image_paths(values)
                if ai_ref_paths:
                    display_paths = source_paths_for_generation_exif(
                        values, extra_paths=ai_ref_paths
                    )
                    if display_paths:
                        self._expand_source_path = display_paths[0]
                        self._task_reference_paths = list(display_paths)
                    else:
                        self._expand_source_path = ""
                        self._task_reference_paths = []
                else:
                    self._expand_source_path = ""
                    self._task_reference_paths = []
        except Exception as e:
            show_styled_critical(
                self.main_window,
                "Generation failed",
                str(e),
            )
            if manage_batch_on_failure:
                self._finish_copy_batch()
            return False

        self._output_path = output_path
        self._snapshot_copy_cycle_for_exif(plugin, values)
        if isinstance(payload.get("steps"), (int, float)):
            self._copy_cycle_values["steps"] = int(payload["steps"])
        apply_payload_model_fields_to_values(
            self._copy_cycle_values, payload, sync_prompt=False
        )
        if self._copies_done == 0:
            self._task_status_info_html = self.get_task_queue_status_info_html()
            self.task_status_info_changed.emit()

        from config import get_config
        from imagegen_plugins.job_values_snapshot import job_values_snapshotted

        if job_values_snapshotted(values) and "debug_mode" in values:
            payload["debug_mode"] = bool(values.get("debug_mode"))
        else:
            payload["debug_mode"] = bool(
                get_config().load_settings().get("debug_mode", False)
            )

        if not self._tasks.start_generate_job(payload):
            if self._tasks.worker_needs_cleanup():
                waited = self._defer_until_worker_cleanup(
                    worker_wait_attempts=_worker_wait_attempts,
                    manage_batch_on_failure=manage_batch_on_failure,
                    from_queue=from_queue,
                    queue_job_id=queue_job_id,
                )
                if waited is None:
                    return None
                if waited is True:
                    return self._launch_generation_job(
                        _worker_wait_attempts=0,
                        manage_batch_on_failure=manage_batch_on_failure,
                        from_queue=from_queue,
                        queue_job_id=queue_job_id,
                    )
            show_styled_critical(
                self.main_window,
                "Generation failed",
                "Could not start the model worker process.",
            )
            if manage_batch_on_failure:
                self._finish_copy_batch()
            return False
        self._launch_refined_prompt = ""
        if from_queue and queue_job_id:
            self._pop_queued_job(queue_job_id)
        return True

    def _snapshot_copy_cycle_for_exif(
        self,
        plugin: ImageGenModelPlugin,
        cycle_values: Dict[str, Any] | None = None,
    ) -> None:
        """Freeze the settings for the in-flight copy (survives mid-run Update)."""
        values = dict(
            cycle_values if cycle_values is not None else self._pending_values
        )
        self._copy_cycle_plugin = plugin
        self._copy_cycle_values = values
        self._copy_cycle_reference_paths = list(self._task_reference_paths)
        self._copy_cycle_expand_source_path = self._expand_source_path
        self._advance_next_copy_display_for_in_flight()

    def _clear_copy_cycle_exif_snapshot(self) -> None:
        self._copy_cycle_plugin = None
        self._copy_cycle_values = {}
        self._copy_cycle_reference_paths = []
        self._copy_cycle_expand_source_path = ""

    def _copy_cycle_exif_plugin(self) -> Optional[ImageGenModelPlugin]:
        if self._copy_cycle_plugin is not None:
            return self._copy_cycle_plugin
        return self._active_plugin

    def _copy_cycle_exif_values(self) -> Dict[str, Any]:
        if self._copy_cycle_values:
            return self._copy_cycle_values
        return self._pending_values

    def _live_generation_elapsed_seconds(self) -> Optional[float]:
        start = self._step_progress_start_time
        if start is None:
            return None
        completed_at = self._step_progress_completed_at
        if completed_at is not None:
            return completed_at - start
        return time.perf_counter() - start

    def _snapshot_live_timing(
        self, *, in_cooldown: bool = False
    ) -> tuple[Optional[float], Optional[float]]:
        """Elapsed and estimate from one clock read (kept in sync for display)."""
        if in_cooldown:
            elapsed = self._frozen_elapsed_seconds
            return (elapsed, None) if elapsed is not None else (None, None)
        elapsed = self._live_generation_elapsed_seconds()
        if elapsed is None:
            return None, None
        estimate = None
        if self._live_step > 0 and self._live_step_total > 0:
            estimate = self._estimate_remaining_seconds(
                elapsed=elapsed,
                completed_steps=self._live_step,
                total_steps=self._live_step_total,
                seconds_per_step=self._step_seconds_per_step,
            )
        elif (
            self._historical_avg_total_seconds is not None
            and self._historical_avg_total_seconds > 0
        ):
            estimate = max(0.0, self._historical_avg_total_seconds - elapsed)
        self._live_elapsed_seconds = elapsed
        self._live_estimate_seconds = estimate
        return elapsed, estimate

    def _wall_clock_elapsed_seconds(self, *, in_cooldown: bool) -> Optional[float]:
        """Elapsed since job processing started (before first step completes)."""
        if self._step_progress_start_time is None:
            return None
        if in_cooldown and self._frozen_elapsed_seconds is not None:
            return self._frozen_elapsed_seconds
        return time.perf_counter() - self._step_progress_start_time

    @staticmethod
    def _estimate_remaining_seconds(
        *,
        elapsed: float,
        completed_steps: int,
        total_steps: int,
        seconds_per_step: Optional[float],
    ) -> Optional[float]:
        """(N-n)*a - (E-n*a) with frozen a; i.e. total_steps*a - elapsed."""
        if (
            completed_steps <= 0
            or total_steps <= 0
            or completed_steps >= total_steps
            or seconds_per_step is None
            or seconds_per_step <= 0
        ):
            return None
        return max(0.0, (total_steps * seconds_per_step) - elapsed)

    def _apply_live_steps_progress(self, html: str) -> str:
        if not html or self._live_step_total <= 0 or self._live_step <= 0:
            return html
        elapsed, estimate = self._snapshot_live_timing(
            in_cooldown=self._is_in_copy_cooldown()
        )
        if elapsed is None:
            return html
        return update_status_html_steps_progress(
            html,
            self._live_step,
            self._live_step_total,
            elapsed_seconds=elapsed,
            estimate_seconds=estimate,
        )

    def _is_multistep_series_job(self) -> bool:
        return self._copy_batch_active and self._copies_total > 1

    def _copy_cooldown_ms(self) -> int:
        if not self._is_multistep_series_job():
            return 0
        from config import get_config
        from imagegen_plugins.image_gen_dim_limits import app_inter_copy_cooldown_seconds

        return app_inter_copy_cooldown_seconds(get_config().load_settings()) * 1000

    def _job_cooldown_ms(self) -> int:
        from config import get_config
        from imagegen_plugins.image_gen_dim_limits import app_job_cooldown_seconds

        return app_job_cooldown_seconds(get_config().load_settings()) * 1000

    def _is_in_copy_cooldown(self) -> bool:
        timer = self._cooldown_timer
        return timer is not None and timer.isActive()

    def _cooldown_seconds_remaining(self) -> int:
        deadline = self._cooldown_deadline
        if deadline is None:
            return 0
        return max(0, int(round(deadline - time.perf_counter())))

    def copy_cooldown_seconds_remaining(self) -> int:
        """Seconds left in inter-copy cooldown (0 when not cooling down)."""
        if not self._is_in_copy_cooldown():
            return 0
        return self._cooldown_seconds_remaining()

    def _probe_lmstudio_after_generation(self, *_args) -> None:
        """One-shot availability refresh so open image-gen panels can restore AI UI."""
        try:
            from imagegen_plugins.lmstudio_caption import probe_lmstudio_services

            probe_lmstudio_services(reason="generation_finished")
        except ImportError:
            pass

    def task_status_display_needs_refresh(self) -> bool:
        """False when only the cooldown countdown second is unchanged (timer polls)."""
        if not self._is_in_copy_cooldown():
            return True
        remaining = self._cooldown_seconds_remaining()
        return remaining != self._last_cooldown_ui_second

    def _update_live_status_timer(self, *_args) -> None:
        if self.pane_shows_generation_progress():
            if not self._live_status_timer.isActive():
                self._live_status_timer.start()
        elif self._live_status_timer.isActive():
            self._live_status_timer.stop()

    def _on_live_status_tick(self) -> None:
        if not self.task_status_display_needs_refresh():
            return
        self.live_status_tick.emit()

    def active_job_status_view(self):
        from imagegen_plugins.model_task_status_info import build_active_job_status_view

        return build_active_job_status_view(self)

    def mark_task_status_display_refreshed(self) -> None:
        """Record cooldown countdown after all task-status UI consumers have updated."""
        if self._is_in_copy_cooldown():
            self._last_cooldown_ui_second = self._cooldown_seconds_remaining()
        else:
            self._last_cooldown_ui_second = None

    def skip_copy_cooldown(self) -> None:
        """End the inter-copy cooldown early and start the next generation."""
        if not self._is_in_copy_cooldown():
            return
        QTimer.singleShot(0, self._skip_copy_cooldown_deferred)

    def _skip_copy_cooldown_deferred(self) -> None:
        if not self._is_in_copy_cooldown():
            return
        self._stop_copy_cooldown_timer()
        self._on_copy_cooldown_elapsed()

    def can_skip_active_series_copy(self) -> bool:
        """True when an in-flight generation copy may be ended early."""
        if self._skip_series_copy_requested:
            return False
        if not self._tasks.is_running() or self._tasks.active_kind != "generate":
            return False
        if self._is_in_copy_cooldown():
            return False
        return True

    def is_skipping_active_series_copy(self) -> bool:
        """True while ending the current copy early (skip toolbar or partial cancel)."""
        return bool(self._skip_series_copy_requested)

    def skip_active_series_copy(self) -> None:
        """End the current copy; advances the series or finishes the job on the last copy."""
        if not self.can_skip_active_series_copy():
            return
        self._skip_series_copy_requested = True
        self.task_status_info_changed.emit()
        QTimer.singleShot(0, self._cancel_active_series_copy_deferred)

    def _cancel_active_series_copy_deferred(self) -> None:
        if not self._skip_series_copy_requested:
            return
        self._tasks.cancel_task()
        self.task_status_info_changed.emit()

    def active_series_remaining_after(self) -> int:
        """Images in the active batch still to run after the current cycle."""
        if not self._active_queue_job_id:
            return 0
        return pending_step_count(self._step_pending_doc)

    def can_add_active_series_cycle(self) -> bool:
        if not self._active_queue_job_id:
            return False
        if self._is_series_continuous_total(self._copies_total):
            return False
        max_after = _SERIES_CONTINUOUS_COPIES - self._copies_done - 1
        return self.active_series_remaining_after() < max_after

    def add_active_series_cycle(self, *, delta: int = 1) -> bool:
        """Add more images to the active batch (same parameters)."""
        return self._adjust_active_series_remaining_after(delta)

    def set_active_series_continuous(self) -> bool:
        """Set the active batch to continuous mode (51 copies)."""
        if not self._active_queue_job_id:
            return False
        if self._is_series_continuous_total(self._copies_total):
            return False
        max_after = _SERIES_CONTINUOUS_COPIES - self._copies_done - 1
        self._set_active_series_remaining_after(max_after)
        return True

    def subtract_active_series_remaining(self) -> bool:
        """Remove one pending image from the active batch (minimum 0 remaining)."""
        if self._is_series_continuous_total(self._copies_total):
            return self._leave_active_continuous_series(
                target_total=_SERIES_CONTINUOUS_COPIES - 1
            )
        return self._adjust_active_series_remaining_after(-1)

    def can_subtract_active_series_cycle(self) -> bool:
        if not self._active_queue_job_id:
            return False
        if self._is_series_continuous_total(self._copies_total):
            return True
        return self.active_series_remaining_after() > 0

    def _leave_active_continuous_series(self, *, target_total: int) -> bool:
        """Exit continuous mode (51) to a finite copy count."""
        plugin = self._active_plugin
        if not self._active_queue_job_id or plugin is None:
            return False
        if not self._is_series_continuous_total(self._copies_total):
            return False
        target_total = max(1, min(_SERIES_CONTINUOUS_COPIES - 1, int(target_total)))

        self._continuous_step_template = None
        doc = self._step_pending_doc
        if isinstance(doc, dict):
            doc.pop(CONTINUOUS_MODE_KEY, None)
            doc.pop(CONTINUOUS_TEMPLATE_KEY, None)

        template_values = dict(self._pending_values)
        template_values["copies"] = target_total
        running = 1 if self._step_running is not None else 0
        self._steps_done = 0
        if isinstance(doc, dict):
            doc["steps_done"] = 0
        pending_needed = max(0, target_total - running)
        self._rewrite_active_pending_steps(plugin, template_values, pending_needed)

        self._copies_total = target_total
        self._copies_done = 0
        self._pending_values["copies"] = target_total
        self._copy_batch_active = target_total > 1 or running > 0
        self._sync_active_job_queue_row(plugin, self._pending_values, target_total)
        self._sync_next_copy_display_from_pending_steps()
        self._persist_step_job_files()
        self.task_status_info_changed.emit()
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def active_series_refinement_enabled(self) -> bool:
        return bool(self._pending_values.get("series_refinement", False))

    def active_series_prompt_refinement_enabled(self) -> bool:
        return bool(self._pending_values.get("series_prompt_refinement", False))

    def set_active_series_refinement(self, enabled: bool) -> bool:
        """Toggle whether remaining copies replace the first source with each result."""
        if not self._active_queue_job_id or self.active_series_remaining_after() <= 0:
            return False
        enabled = bool(enabled)
        if self.active_series_refinement_enabled() == enabled:
            return False
        self._pending_values["series_refinement"] = enabled
        doc = self._step_pending_doc
        if isinstance(doc, dict):
            raw_steps = doc.get("steps")
            if isinstance(raw_steps, list):
                for step in raw_steps:
                    step["series_refinement"] = enabled
                    vals = step_values(step)
                    vals["series_refinement"] = enabled
                    step["values"] = vals
        if (
            enabled
            and self._copies_done > 0
            and not self._tasks.is_running()
        ):
            last_out = self._output_path
            if last_out and os.path.isfile(last_out):
                self._pending_values = apply_refinement_source_for_next_copy(
                    self._pending_values, last_out
                )
                paths = resolve_source_image_paths(self._pending_values)
                self._expand_source_path = paths[0] if paths else ""
                self._task_reference_paths = list(paths)
                self._active_thumbnail_paths = list(paths)
        self._sync_next_copy_display_from_pending_steps()
        self._persist_step_job_files()
        self.task_status_info_changed.emit()
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def set_active_series_prompt_refinement(self, enabled: bool) -> bool:
        """Toggle whether remaining copies re-run the previous prompt through AI."""
        if not self._active_queue_job_id or self.active_series_remaining_after() <= 0:
            return False
        enabled = bool(enabled)
        if self.active_series_prompt_refinement_enabled() == enabled:
            return False
        plugin = self._active_plugin
        if plugin is None:
            return False
        from imagegen_plugins.flux_prompt_job import (
            clear_series_chain_flux_prompt_ai_job,
            ensure_flux_prompt_ai_job_for_series,
        )

        if enabled:
            if not ensure_flux_prompt_ai_job_for_series(plugin, self._pending_values):
                return False
            self._pending_values["series_prompt_refinement"] = True
            if self._copies_done > 0:
                from imagegen_plugins.flux_prompt_job import (
                    sync_flux_prompt_ai_user_prompt_for_next_copy,
                )

                sync_flux_prompt_ai_user_prompt_for_next_copy(
                    self._pending_values,
                    source_values=(
                        self._copy_cycle_exif_values()
                        if self._copy_cycle_values
                        else self._pending_values
                    ),
                )
        else:
            self._pending_values["series_prompt_refinement"] = False
            clear_series_chain_flux_prompt_ai_job(self._pending_values)
        doc = self._step_pending_doc
        if isinstance(doc, dict):
            raw_steps = doc.get("steps")
            if isinstance(raw_steps, list):
                from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job
                from imagegen_plugins.job_step_queue import copy_step_from_values

                updated: list[dict] = []
                for step in raw_steps:
                    merged = merge_step_into_values(step)
                    if enabled:
                        merged["series_prompt_refinement"] = True
                        if not ensure_flux_prompt_ai_job_for_series(plugin, merged):
                            updated.append(step)
                            continue
                    else:
                        merged["series_prompt_refinement"] = False
                        clear_series_chain_flux_prompt_ai_job(merged)
                    updated.append(
                        copy_step_from_values(
                            merged,
                            needs_ai=has_flux_prompt_ai_job(merged),
                            step_id=str(step.get("step_id") or ""),
                        )
                    )
                doc["steps"] = updated
                self._step_pending_doc = doc
        self._sync_next_copy_display_from_pending_steps()
        self._persist_step_job_files()
        self.task_status_info_changed.emit()
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def _queued_job_by_id(self, job_id: str) -> QueuedGenerateJob | None:
        for job in self._queue:
            if job.job_id == job_id:
                return job
        return None

    def _resolve_plugin_for_record(
        self, plugin_id: str, function: str
    ) -> ImageGenModelPlugin | None:
        from imagegen_plugins import create_menu_plugins

        for plugin in create_menu_plugins():
            if plugin.plugin_id == plugin_id and plugin.function == function:
                return plugin
        return None

    def _clear_step_job_state(self) -> None:
        self._step_running_doc = None
        self._step_pending_doc = None
        self._step_running = None
        self._steps_done = 0
        self._last_completed_output_path = ""
        self._last_completed_prompt = ""
        self._last_completed_values = {}
        self._continuous_step_template = None

    def _activate_continuous_series_pending_doc(
        self,
        doc: dict | None,
        *,
        template_step: dict | None = None,
    ) -> None:
        if template_step is not None:
            self._continuous_step_template = dict(template_step)
        elif self._continuous_step_template is None:
            if isinstance(doc, dict):
                raw_steps = doc.get("steps")
                if isinstance(raw_steps, list) and raw_steps:
                    self._continuous_step_template = dict(raw_steps[0])
            if self._continuous_step_template is None and self._step_running is not None:
                self._continuous_step_template = dict(self._step_running)
        if not isinstance(doc, dict) or self._continuous_step_template is None:
            return
        doc[CONTINUOUS_MODE_KEY] = True
        doc[CONTINUOUS_TEMPLATE_KEY] = dict(self._continuous_step_template)

    def _normalize_queued_job_copies(self, job: QueuedGenerateJob) -> None:
        copies = int(job.values.get("copies", job.copies_total or 1))
        step_count = len(job.steps) if isinstance(job.steps, list) else 0
        if not (
            self._is_series_continuous_total(copies)
            or step_count > _SERIES_CONTINUOUS_COPIES
        ):
            return
        job.copies_total = _SERIES_CONTINUOUS_COPIES
        job.values["copies"] = _SERIES_CONTINUOUS_COPIES
        if job.plugin is None:
            return
        if not isinstance(job.steps, list) or not job.steps:
            job.steps = materialize_steps(job.plugin, job.values, _SERIES_CONTINUOUS_COPIES)
            return
        template = merge_step_into_values(job.steps[0])
        template["copies"] = _SERIES_CONTINUOUS_COPIES
        job.steps = materialize_steps(job.plugin, template, _SERIES_CONTINUOUS_COPIES)

    def _sync_chain_state_to_pending_doc(self) -> None:
        if self._step_pending_doc is None:
            return
        self._step_pending_doc = sync_chain_state_to_pending_doc(
            self._step_pending_doc,
            output_path=self._last_completed_output_path,
            prompt=self._last_completed_prompt,
            prior_values=self._last_completed_values or None,
        )

    def _pending_doc_for_persist(self) -> dict | None:
        return finalize_pending_doc_for_persist(
            self._step_pending_doc,
            output_path=self._last_completed_output_path,
            prompt=self._last_completed_prompt,
            prior_values=self._last_completed_values or None,
            continuous_mode=self._is_series_continuous_total(self._copies_total),
            continuous_template=self._continuous_step_template,
        )

    def _sync_batch_counters_from_steps(self) -> None:
        if not self._active_queue_job_id:
            return
        pending = pending_step_count(self._step_pending_doc)
        running = 1 if self._step_running is not None else 0
        if self._is_series_continuous_total(self._copies_total):
            self._copies_total = int(self._pending_values.get("copies", _SERIES_CONTINUOUS_COPIES))
            self._copy_batch_active = True
            self._sync_copies_done_display()
            return
        total = max(1, self._steps_done + pending + running)
        self._copies_total = total
        self._copy_batch_active = self._copies_total > 1 or self._steps_done > 0

    def _sync_pending_values_from_running_step(self) -> None:
        if self._step_running is None:
            return
        values = merge_step_into_values(self._step_running)
        values["copies"] = self._copies_total
        self._pending_values = values
        self._next_copy_display_values = dict(values)

    def _sync_next_copy_display_from_pending_steps(self) -> None:
        doc = self._step_pending_doc
        steps = doc.get("steps") if isinstance(doc, dict) else None
        if isinstance(steps, list) and steps:
            values = merge_step_into_values(steps[0])
            values["copies"] = self._copies_total
            self._next_copy_display_values = values
        elif self._step_running is not None:
            self._next_copy_display_values = dict(self._pending_values)

    def _init_active_job_steps(
        self,
        plugin: ImageGenModelPlugin,
        values: Dict[str, Any],
        copies: int,
        *,
        full_prompt: str = "",
        thumbnail_paths: list[str] | None = None,
        steps: list[dict] | None = None,
    ) -> None:
        from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

        if steps is None:
            steps = materialize_steps(plugin, values, copies)
        fp = full_prompt or effective_job_prompt_for_tooltip(values)
        continuous = self._is_series_continuous_total(copies)
        template = dict(steps[0]) if continuous and steps else None
        self._step_pending_doc = build_pending_job_doc(
            job_id=self._active_queue_job_id,
            plugin=plugin,
            steps=steps,
            full_prompt=fp,
            thumbnail_paths=thumbnail_paths,
            steps_done=0,
            continuous_mode=continuous,
            continuous_template=template,
        )
        self._steps_done = 0
        self._step_running = None
        self._step_running_doc = None
        self._last_completed_output_path = ""
        self._last_completed_prompt = ""
        self._last_completed_values = {}
        self._continuous_step_template = template
        self._sync_batch_counters_from_steps()

    def _append_continuous_pending_step(self, plugin: ImageGenModelPlugin) -> bool:
        doc = self._step_pending_doc
        template = self._continuous_step_template
        if doc is None or template is None:
            return False
        from imagegen_plugins.job_step_queue import copy_step_from_values, new_step_id

        values = step_values(template)
        step = copy_step_from_values(values, needs_ai=step_needs_ai(template))
        step["step_id"] = new_step_id()
        self._step_pending_doc = append_pending_step(doc, step)
        self._sync_batch_counters_from_steps()
        return True

    def _promote_next_step_to_running(self, plugin: ImageGenModelPlugin) -> bool:
        doc = self._step_pending_doc
        if doc is None:
            return False
        if (
            self._is_series_continuous_total(self._copies_total)
            and pending_step_count(doc) <= 0
            and self._continuous_step_template is not None
        ):
            self._append_continuous_pending_step(plugin)
            doc = self._step_pending_doc
        if doc is None:
            return False
        step, doc = pop_pending_step(doc)
        self._step_pending_doc = doc
        if step is None:
            return False
        step = resolve_step_before_run(
            plugin,
            step,
            prior_output_path=self._last_completed_output_path,
            prior_prompt=self._last_completed_prompt,
            prior_values=self._last_completed_values or None,
        )
        self._step_running = step
        self._step_running_doc = build_running_job_doc(
            job_id=self._active_queue_job_id,
            plugin=plugin,
            step=step,
        )
        self._sync_pending_values_from_running_step()
        self._sync_batch_counters_from_steps()
        self._sync_next_copy_display_from_pending_steps()
        self._persist_step_job_files()
        return True

    def _complete_running_step_after_copy(self, *, output_path: str = "") -> None:
        if self._step_running is not None:
            completed = merge_step_into_values(self._step_running)
            self._last_completed_values = dict(completed)
            self._last_completed_prompt = str(completed.get("prompt") or "").strip()
        if output_path:
            self._last_completed_output_path = output_path
        self._step_running = None
        self._step_running_doc = None
        clear_job_active_running_file()
        if isinstance(self._step_pending_doc, dict):
            self._step_pending_doc["steps_done"] = self._steps_done + 1
        self._steps_done += 1
        self._sync_copies_done_display()
        self._sync_chain_state_to_pending_doc()
        self._sync_batch_counters_from_steps()
        self._persist_step_job_files()

    def _prepend_running_step_to_pending(self) -> None:
        if self._step_running is None:
            return
        doc = self._step_pending_doc
        plugin = self._active_plugin
        if doc is None and plugin is not None:
            from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

            doc = build_pending_job_doc(
                job_id=self._active_queue_job_id,
                plugin=plugin,
                steps=[],
                full_prompt=effective_job_prompt_for_tooltip(self._pending_values),
                thumbnail_paths=self._active_thumbnail_paths,
                steps_done=self._steps_done,
            )
        if doc is None:
            return
        self._sync_chain_state_to_pending_doc()
        doc = self._step_pending_doc
        if doc is None:
            return
        self._step_pending_doc = prepend_pending_step(doc, self._step_running)
        self._step_running = None
        self._step_running_doc = None
        clear_job_active_running_file()

    def _rewrite_active_pending_steps(
        self,
        plugin: ImageGenModelPlugin,
        template_values: Dict[str, Any],
        count: int,
    ) -> None:
        steps = materialize_pending_steps_from_update(
            plugin, template_values, count
        )
        doc = self._step_pending_doc
        if doc is None:
            from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

            doc = build_pending_job_doc(
                job_id=self._active_queue_job_id,
                plugin=plugin,
                steps=[],
                full_prompt=effective_job_prompt_for_tooltip(template_values),
                thumbnail_paths=self._active_thumbnail_paths,
                steps_done=self._steps_done,
            )
        doc = replace_pending_steps(doc, steps)
        doc["steps_done"] = self._steps_done
        display = doc.get("display")
        if not isinstance(display, dict):
            display = {}
            doc["display"] = display
        from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

        display["full_prompt"] = effective_job_prompt_for_tooltip(template_values)
        thumbs = thumbnail_paths_for_values(plugin, template_values)
        if thumbs:
            display["thumbnail_paths"] = list(thumbs)
            self._active_thumbnail_paths = list(thumbs)
        self._step_pending_doc = doc
        if self._is_series_continuous_total(int(template_values.get("copies", 1))):
            self._activate_continuous_series_pending_doc(
                self._step_pending_doc,
                template_step=dict(steps[0]) if steps else None,
            )
        self._sync_chain_state_to_pending_doc()
        self._sync_batch_counters_from_steps()
        self._sync_next_copy_display_from_pending_steps()
        self._persist_step_job_files()

    def _queued_jobs_as_step_docs(self) -> list:
        return [queued_generate_job_to_step_doc(job) for job in self._queue]

    def _persist_step_job_files(self, *, force: bool = False) -> None:
        if self._queue_persist_suppressed and not force:
            return
        plugin = self._active_plugin
        running_doc = self._step_running_doc
        pending_doc = self._pending_doc_for_persist()
        if plugin is not None and self._active_queue_job_id:
            from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip

            running_doc, pending_doc = active_job_step_docs_for_persist(
                job_id=self._active_queue_job_id,
                plugin=plugin,
                running_step=self._step_running,
                pending_doc=pending_doc,
                full_prompt=effective_job_prompt_for_tooltip(self._pending_values),
                thumbnail_paths=self._active_thumbnail_paths,
            )
        active_display_index = (
            max(0, int(self._active_display_index))
            if self._active_queue_job_id
            else 0
        )
        persist_step_job_files(
            running_doc=running_doc,
            pending_doc=pending_doc,
            queued_job_docs=self._queued_jobs_as_step_docs(),
            active_display_index=active_display_index,
        )

    def _restore_active_job_from_step_files(
        self, *, active_display_index: int = 0
    ) -> bool:
        running_doc = load_job_active_running()
        pending_doc = load_job_active_pending()
        if not running_doc and not pending_doc:
            return False
        source = running_doc if running_doc else pending_doc
        if not isinstance(source, dict):
            return False
        plugin_id = str(source.get("plugin_id") or "")
        function = str(source.get("function") or "")
        job_id = str(source.get("job_id") or "")
        if not plugin_id or not function or not job_id:
            return False
        plugin = self._resolve_plugin_for_record(plugin_id, function)
        if plugin is None:
            return False
        self._active_queue_job_id = job_id
        self._active_display_index = max(
            0, min(int(active_display_index), len(self._queue))
        )
        self._active_plugin = plugin
        self._step_pending_doc = dict(pending_doc) if isinstance(pending_doc, dict) else None
        self._steps_done = 0
        if isinstance(self._step_pending_doc, dict):
            try:
                self._steps_done = max(0, int(self._step_pending_doc.get("steps_done", 0)))
            except (TypeError, ValueError):
                self._steps_done = 0
        display = (
            self._step_pending_doc.get("display")
            if isinstance(self._step_pending_doc, dict)
            else None
        )
        if isinstance(display, dict):
            raw_thumbs = display.get("thumbnail_paths")
            if isinstance(raw_thumbs, list):
                self._active_thumbnail_paths = [
                    str(p) for p in raw_thumbs if p and os.path.isfile(str(p))
                ]
        if not self._active_thumbnail_paths:
            steps = (
                self._step_pending_doc.get("steps")
                if isinstance(self._step_pending_doc, dict)
                else None
            )
            if isinstance(steps, list) and steps:
                self._active_thumbnail_paths = thumbnail_paths_for_values(
                    plugin, merge_step_into_values(steps[0])
                )
        running_step = None
        if isinstance(running_doc, dict):
            raw_step = running_doc.get("step")
            if isinstance(raw_step, dict):
                running_step = dict(raw_step)
        self._step_running = running_step
        self._step_running_doc = (
            dict(running_doc) if isinstance(running_doc, dict) else None
        )
        if running_step is not None:
            self._sync_pending_values_from_running_step()
        elif isinstance(self._step_pending_doc, dict):
            steps = self._step_pending_doc.get("steps")
            if isinstance(steps, list) and steps:
                values = merge_step_into_values(steps[0])
                values["copies"] = max(1, self._steps_done + len(steps))
                self._pending_values = values
                self._next_copy_display_values = dict(values)
        pending_count = pending_step_count(self._step_pending_doc)
        running_count = 1 if self._step_running is not None else 0
        (
            self._last_completed_output_path,
            self._last_completed_prompt,
            self._last_completed_values,
        ) = restore_chain_state_from_pending_doc(self._step_pending_doc)
        if pending_doc_is_continuous(self._step_pending_doc, running_step):
            self._copies_total = _SERIES_CONTINUOUS_COPIES
            self._pending_values["copies"] = _SERIES_CONTINUOUS_COPIES
            raw_template = (
                self._step_pending_doc.get(CONTINUOUS_TEMPLATE_KEY)
                if isinstance(self._step_pending_doc, dict)
                else None
            )
            if isinstance(raw_template, dict):
                self._continuous_step_template = dict(raw_template)
            else:
                steps = (
                    self._step_pending_doc.get("steps")
                    if isinstance(self._step_pending_doc, dict)
                    else None
                )
                if isinstance(steps, list) and steps:
                    self._continuous_step_template = dict(steps[0])
        else:
            copies = int(self._pending_values.get("copies", 0))
            if self._is_series_continuous_total(copies):
                self._copies_total = _SERIES_CONTINUOUS_COPIES
                self._pending_values["copies"] = _SERIES_CONTINUOUS_COPIES
            else:
                self._copies_total = max(
                    1, self._steps_done + pending_count + running_count
                )
            self._continuous_step_template = None
        self._sync_copies_done_display()
        self._copy_batch_active = self._copies_total > 1 or self._steps_done > 0
        self._copy_batch_cancelled = False
        return True

    def _restore_persisted_job_queue(self) -> None:
        remove_legacy_job_queue_data()
        restored: List[QueuedGenerateJob] = []
        for job_doc in load_job_queue_json():
            plugin = None
            plugin_unavailable = bool(job_doc.get("plugin_unavailable"))
            if not plugin_unavailable:
                plugin = self._resolve_plugin_for_record(
                    str(job_doc.get("plugin_id") or ""),
                    str(job_doc.get("function") or ""),
                )
                if plugin is None:
                    plugin_unavailable = True
            job = queued_job_from_step_doc(
                job_doc, plugin, plugin_unavailable=plugin_unavailable
            )
            self._normalize_queued_job_copies(job)
            restored.append(job)
        self._queue = restored
        has_active = self._restore_active_job_from_step_files(
            active_display_index=load_job_queue_active_display_index()
        )
        if restored or has_active:
            self.queue_changed.emit()
            self._sync_cancel_menu()
        if (restored or has_active) and not self._hold_job_queue:
            self._startup_queue_hold = True

    def _schedule_persist_job_queue(self) -> None:
        if self._queue_persist_suppressed:
            return
        self._queue_persist_timer.start(300)

    def _persist_job_queue_now(self) -> None:
        if self._queue_persist_suppressed:
            return
        self._queue_persist_timer.stop()
        self._persist_step_job_files()

    def _persist_job_queue_for_exit(self) -> None:
        """Persist queue snapshot once at shutdown; block later empty overwrites."""
        self._queue_persist_timer.stop()
        if self._exit_queue_persisted:
            return
        if self._step_running is not None and not self._quit_after_current_worker:
            self._prepend_running_step_to_pending()
        self._sync_chain_state_to_pending_doc()
        self._persist_step_job_files(force=True)
        self._exit_queue_persisted = True
        self._queue_persist_suppressed = True

    def _active_is_next_to_run(self) -> bool:
        return bool(self._active_queue_job_id) and self._active_display_index == 0

    def _yield_active_if_superseded_by_reorder(self) -> bool:
        """Demote the active job when another row should run first (idle pipeline only)."""
        if self._active_is_next_to_run():
            return False
        if self._generation_worker_active():
            return False
        return self._yield_active_batch_if_not_next_to_run()

    def _yield_active_batch_if_not_next_to_run(self) -> bool:
        """Finish (cancelled) or demote when another queue row should run first."""
        if self._active_is_next_to_run():
            return False
        if self._copy_batch_cancelled:
            self._finish_copy_batch(cancelled=True)
            return True
        if self._demote_active_remaining_to_queue():
            self._defer_try_start_next_queued_job()
            return True
        if self._pending_batch_copies() <= 0:
            self._finish_copy_batch()
            return True
        self._clear_active_job_head_without_demote()
        self._defer_try_start_next_queued_job()
        return True

    def _remove_cancelled_job_from_queue(self, job_id: str) -> None:
        if not job_id:
            return
        before = len(self._queue)
        self._queue = [job for job in self._queue if job.job_id != job_id]
        if len(self._queue) != before:
            self._invalidate_pending_queue_snapshot_cache()

    def _demote_active_remaining_to_queue(self) -> bool:
        """Fold remaining active copies into ``_queue`` at the active display slot."""
        if self._copy_batch_cancelled:
            return False
        if not self._active_queue_job_id:
            return False
        continuous = self._active_job_is_continuous()
        pending_count = pending_step_count(self._step_pending_doc)
        if pending_count <= 0 and self._step_running is None and not continuous:
            return False
        plugin = self._active_plugin
        if plugin is None:
            return False
        from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip
        from imagegen_plugins.model_task_queue import refresh_queued_job_status

        steps: list[dict] = []
        if self._step_running is not None:
            steps.append(dict(self._step_running))
        doc = self._step_pending_doc
        if isinstance(doc, dict):
            raw_steps = doc.get("steps")
            if isinstance(raw_steps, list):
                steps.extend(dict(s) for s in raw_steps)
        if not steps and continuous:
            template_step = self._continuous_step_template
            if template_step is None and isinstance(doc, dict):
                raw_template = doc.get(CONTINUOUS_TEMPLATE_KEY)
                if isinstance(raw_template, dict):
                    template_step = raw_template
            template_values = None
            if template_step is not None:
                template_values = merge_step_into_values(template_step)
            elif self._pending_values:
                template_values = dict(self._pending_values)
            if template_values is not None:
                template_values = dict(template_values)
                template_values["copies"] = _SERIES_CONTINUOUS_COPIES
                steps = materialize_steps(
                    plugin, template_values, _SERIES_CONTINUOUS_COPIES
                )
        if not steps:
            return False
        if continuous:
            copies_total = _SERIES_CONTINUOUS_COPIES
            self._stamp_series_copies_on_steps(steps, copies_total)
        else:
            copies_total = len(steps)
        values = merge_step_into_values(steps[0])
        values["copies"] = copies_total
        full_prompt = effective_job_prompt_for_tooltip(values)
        display = doc.get("display") if isinstance(doc, dict) else None
        if isinstance(display, dict):
            fp = str(display.get("full_prompt") or "").strip()
            if fp:
                full_prompt = fp
        thumbs = list(self._active_thumbnail_paths)
        existing = self._queued_job_by_id(self._active_queue_job_id)
        if existing is not None:
            existing.plugin = plugin
            existing.plugin_id = plugin.plugin_id
            existing.function = plugin.function
            existing.plugin_unavailable = False
            existing.values = values
            existing.copies_total = copies_total
            existing.steps = steps
            existing.full_prompt = full_prompt
            if thumbs:
                existing.thumbnail_paths = thumbs
            refresh_queued_job_status(existing)
        else:
            job = restore_queued_generate_job(
                job_id=self._active_queue_job_id,
                plugin=plugin,
                plugin_id=plugin.plugin_id,
                function=plugin.function,
                values=values,
                copies_total=copies_total,
                full_prompt=full_prompt,
                steps=steps,
            )
            if thumbs:
                job.thumbnail_paths = thumbs
            refresh_queued_job_status(job)
            insert_at = max(0, min(self._active_display_index, len(self._queue)))
            self._queue.insert(insert_at, job)
        self._stop_copy_cooldown_timer()
        self._clear_step_job_state()
        clear_job_active_running_file()
        self._copy_batch_active = False
        self._copies_total = 0
        self._copies_done = 0
        self._copy_batch_cancelled = False
        self._active_queue_job_id = ""
        self._active_display_index = 0
        self._active_thumbnail_paths = []
        self._update_status_bar_indicator(None)
        self._reset_generation_state()
        self.queue_changed.emit()
        self._sync_cancel_menu()
        self._schedule_persist_job_queue()
        self._emit_jobs_pane_title_changed()
        return True

    def _advance_copy_batch_progress(self) -> None:
        self._sync_copies_done_display()

    def _series_continues_after_copy_success(self) -> bool:
        """Return True when the active batch should run another copy immediately."""
        from imagegen_plugins.job_step_queue import pending_step_count

        if not self._copy_batch_active or self._copy_batch_cancelled:
            return False
        if self._is_series_continuous_total(self._copies_total):
            return True
        pending = pending_step_count(self._step_pending_doc)
        if pending <= 0:
            return False
        if self._yield_active_batch_if_not_next_to_run():
            return False
        return True

    def _step_cancel_applies(self) -> bool:
        """True when cancel should drop only the in-flight copy, not the whole job."""
        if not self._active_queue_job_id:
            return False
        remaining = pending_step_count(self._step_pending_doc)
        if not self._is_series_continuous_total(self._copies_total) and remaining <= 0:
            return False
        in_flight = (
            self._step_running is not None
            or self._job_ai_stage_active
            or self._tasks.is_running()
            or self._gpu_cleanup_active
        )
        return in_flight

    def _continue_after_aborted_step(self, *, output_path: str = "") -> None:
        """End the current copy early and run the next pending step when applicable."""
        try:
            plugin = self._copy_cycle_exif_plugin()
            self._remove_partial_output()
            if plugin and plugin.pipeline_id == "mflux_fill_expand":
                remove_expand_base_temp(self._expand_base_path)
                self._expand_base_path = ""
            self._remove_aspect_pad_temps()
            if self._step_running is None and self._copy_cycle_values:
                cycle_values = dict(self._copy_cycle_values)
                self._last_completed_values = dict(cycle_values)
                self._last_completed_prompt = str(cycle_values.get("prompt") or "").strip()
            self._clear_copy_cycle_exif_snapshot()
            self._complete_running_step_after_copy(output_path=output_path)
            self.generation_finished.emit(False, output_path, "")
            if self._finish_current_unit_and_maybe_quit():
                return
            if not self._series_continues_after_copy_success():
                self._finish_copy_batch(cancelled=False)
                return
            completed_copy_values = dict(self._copy_cycle_exif_values())
            self._sync_next_copy_chain_from_completed_cycle(
                completed_copy_values,
                output_path=output_path,
            )
            self._reset_active_job_progress_tracking()
            self.queue_changed.emit()
            self.task_status_info_changed.emit()
            self._schedule_persist_job_queue()
            self._emit_jobs_pane_title_changed()
            if self._hold_job_queue:
                return
            QTimer.singleShot(0, self._launch_next_copy_after_cooldown)
        finally:
            if self._skip_series_copy_requested:
                self._skip_series_copy_requested = False
                self.task_status_info_changed.emit()

    def series_remaining_after_for_row(self, row: int) -> int:
        """Pending images after the current one (active) or after the first (queued)."""
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return 0
        entry = rows[row]
        if entry.is_active:
            return self.active_series_remaining_after()
        job = self._queued_job_by_id(entry.job_id)
        if job is None:
            return 0
        if isinstance(job.steps, list) and job.steps:
            return max(0, len(job.steps) - 1)
        return max(0, job.copies_total - 1)

    def can_add_series_cycle_for_row(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.can_add_active_series_cycle()
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None:
            return False
        return not self._is_series_continuous_total(job.copies_total)

    def can_subtract_series_cycle_for_row(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.can_subtract_active_series_cycle()
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None:
            return False
        if self._is_series_continuous_total(job.copies_total):
            return True
        return self.series_remaining_after_for_row(row) > 0

    def add_series_cycle_for_row(self, row: int, *, delta: int = 1) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.add_active_series_cycle(delta=delta)
        return self._adjust_queued_series_total(row, delta)

    def set_series_continuous_for_row(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.set_active_series_continuous()
        return self._set_queued_series_continuous(row)

    def subtract_series_remaining_for_row(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.subtract_active_series_remaining()
        return self._adjust_queued_series_total(row, -1)

    def clear_active_series_remaining(self) -> bool:
        """Remove all pending images from the active batch after the current one."""
        if self.active_series_remaining_after() <= 0:
            return False
        self._set_active_series_remaining_after(0)
        return True

    def clear_series_remaining_for_row(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.clear_active_series_remaining()
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None:
            return False
        if isinstance(job.steps, list) and job.steps:
            job.steps = [dict(job.steps[0])]
        job.copies_total = 1
        job.values["copies"] = 1
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def series_refinement_enabled_for_row(self, row: int) -> bool:
        record = self.job_record_for_row(row)
        if record is None:
            return False
        _, values = record
        return bool(values.get("series_refinement", False))

    def set_series_refinement_for_row(self, row: int, enabled: bool) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.set_active_series_refinement(enabled)
        if self.series_remaining_after_for_row(row) <= 0:
            return False
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None:
            return False
        enabled = bool(enabled)
        if bool(job.values.get("series_refinement", False)) == enabled:
            return False
        job.values["series_refinement"] = enabled
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def series_prompt_refinement_enabled_for_row(self, row: int) -> bool:
        record = self.job_record_for_row(row)
        if record is None:
            return False
        _, values = record
        return bool(values.get("series_prompt_refinement", False))

    def set_series_prompt_refinement_for_row(self, row: int, enabled: bool) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows):
            return False
        if rows[row].is_active:
            return self.set_active_series_prompt_refinement(enabled)
        if self.series_remaining_after_for_row(row) <= 0:
            return False
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None or job.plugin is None:
            return False
        enabled = bool(enabled)
        if bool(job.values.get("series_prompt_refinement", False)) == enabled:
            return False
        from imagegen_plugins.flux_prompt_job import (
            clear_series_chain_flux_prompt_ai_job,
            ensure_flux_prompt_ai_job_for_series,
        )

        if enabled:
            if not ensure_flux_prompt_ai_job_for_series(job.plugin, job.values):
                return False
            job.values["series_prompt_refinement"] = True
        else:
            job.values["series_prompt_refinement"] = False
            clear_series_chain_flux_prompt_ai_job(job.values)
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def _set_queued_series_continuous(self, row: int) -> bool:
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows) or rows[row].is_active:
            return False
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None or job.plugin is None:
            return False
        if self._is_series_continuous_total(job.copies_total):
            return False
        job.values = dict(job.values)
        job.values["copies"] = _SERIES_CONTINUOUS_COPIES
        if not isinstance(job.steps, list) or not job.steps:
            job.steps = materialize_steps(
                job.plugin, job.values, _SERIES_CONTINUOUS_COPIES
            )
        self._normalize_queued_job_copies(job)
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def _adjust_queued_series_total(self, row: int, delta: int) -> bool:
        if delta == 0:
            return False
        rows = self.queue_snapshot()
        if row < 0 or row >= len(rows) or rows[row].is_active:
            return False
        job = self._queued_job_by_id(rows[row].job_id)
        if job is None or job.plugin is None:
            return False
        if not isinstance(job.steps, list) or not job.steps:
            job.steps = materialize_steps(job.plugin, job.values, job.copies_total)
        self._normalize_queued_job_copies(job)
        remaining = max(0, len(job.steps) - 1)
        if delta > 0:
            if len(job.steps) >= _SERIES_CONTINUOUS_COPIES:
                return False
            new_total = min(_SERIES_CONTINUOUS_COPIES, len(job.steps) + delta)
            if new_total <= len(job.steps):
                return False
            template = merge_step_into_values(job.steps[0])
            for _ in range(new_total - len(job.steps)):
                extra = materialize_pending_steps_from_update(
                    job.plugin, template, 1
                )
                if extra:
                    job.steps.append(extra[0])
        else:
            if self._is_series_continuous_total(job.copies_total):
                new_total = _SERIES_CONTINUOUS_COPIES - 1
                template = merge_step_into_values(job.steps[0]) if job.steps else dict(job.values)
                template["copies"] = new_total
                job.steps = materialize_steps(job.plugin, template, new_total)
            elif remaining <= 0:
                return False
            else:
                new_total = max(1, len(job.steps) + delta)
                if new_total == len(job.steps):
                    return False
                job.steps = [dict(s) for s in job.steps[:new_total]]
        job.copies_total = len(job.steps)
        job.values["copies"] = job.copies_total
        refresh_queued_job_status(job)
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        return True

    def _adjust_active_series_remaining_after(self, delta: int) -> bool:
        if not self._active_queue_job_id or delta == 0:
            return False
        max_after = _SERIES_CONTINUOUS_COPIES - self._copies_done - 1
        after = self.active_series_remaining_after()
        new_after = max(0, min(max_after, after + delta))
        if new_after == after:
            return False
        self._set_active_series_remaining_after(new_after)
        return True

    def _set_active_series_remaining_after(self, after: int) -> None:
        max_after = _SERIES_CONTINUOUS_COPIES - self._copies_done - 1
        after = max(0, min(max_after, int(after)))
        doc = self._step_pending_doc
        plugin = self._active_plugin
        if doc is None or plugin is None:
            return
        current = pending_step_count(doc)
        delta = after - current
        if delta > 0:
            template = dict(self._pending_values)
            for _ in range(delta):
                new_steps = materialize_pending_steps_from_update(
                    plugin, template, 1
                )
                if new_steps:
                    doc = append_pending_step(doc, new_steps[0])
        elif delta < 0:
            raw_steps = doc.get("steps")
            steps = (
                [dict(s) for s in raw_steps[:after]]
                if isinstance(raw_steps, list)
                else []
            )
            doc = replace_pending_steps(doc, steps)
        self._step_pending_doc = doc
        new_total = self._copies_done + 1 + after
        if self._is_series_continuous_total(new_total):
            new_total = _SERIES_CONTINUOUS_COPIES
            self._activate_continuous_series_pending_doc(self._step_pending_doc)
        self._copies_total = new_total
        self._pending_values["copies"] = new_total
        self._sync_copies_done_display()
        self._copy_batch_active = new_total > 1 or self._copies_done > 0
        if plugin is not None:
            self._sync_active_job_queue_row(plugin, self._pending_values, new_total)
        self._sync_batch_counters_from_steps()
        self._persist_step_job_files()
        self.task_status_info_changed.emit()
        self.queue_changed.emit()
        self._schedule_persist_job_queue()
        if self._is_in_copy_cooldown() and self._pending_batch_copies() <= 0:
            self._stop_copy_cooldown_timer()
            self._finish_copy_batch()

    def _reset_live_queue_progress(self) -> None:
        self._live_step = 0
        self._live_step_total = 0
        self._live_elapsed_seconds = None
        self._live_estimate_seconds = None
        self._step_seconds_per_step = None
        self._generation_timing_key = None
        self._historical_avg_total_seconds = None

    def _reset_active_job_progress_tracking(self) -> None:
        """Clear step/elapsed/timing used by progress bars (not copy-batch counters)."""
        self._reset_live_queue_progress()
        self._step_progress_start_time = None
        self._step_progress_completed_at = None
        self._frozen_elapsed_seconds = None
        self._job_ai_chars_received = 0
        self._job_ai_last_progress_bucket = -1
        self._last_cooldown_ui_second = None

    def get_task_queue_status_info_html(self, *, omit_live_steps_row: bool = False) -> str:
        """Compact info table for the job queue pane and sidebar (rebuilt from live state)."""
        plugin = self._active_plugin
        if plugin is None:
            return ""

        show_next = self._active_job_card_shows_next_copy()
        card_values = self._active_job_card_values()
        card_paths = self._active_job_card_source_paths()

        if self._job_ai_stage_active and not show_next:
            from imagegen_plugins.model_task_status_info import (
                format_job_ai_stage_queue_status_html,
            )

            elapsed, estimate = self._snapshot_live_timing(in_cooldown=False)
            if elapsed is None:
                elapsed = self._wall_clock_elapsed_seconds(in_cooldown=False)
            step = None
            step_total = None
            if not omit_live_steps_row and self._live_step_total > 0:
                step = self._live_step
                step_total = self._live_step_total
            return format_job_ai_stage_queue_status_html(
                plugin,
                self._pending_values,
                running=self._tasks.is_running(),
                step=step,
                step_total=step_total,
                elapsed_seconds=elapsed,
                estimate_seconds=estimate,
            )

        from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job

        in_cooldown = self._is_in_copy_cooldown()
        in_flight = self._tasks.is_running() or self._job_ai_stage_active
        elapsed, estimate = self._snapshot_live_timing(in_cooldown=in_cooldown)
        step = self._live_step if self._live_step_total > 0 else None
        step_total = self._live_step_total if self._live_step_total > 0 else None
        if show_next:
            if in_flight and (
                self._expand_base_path
                or self._expand_source_path
                or self._task_reference_paths
            ):
                source_path = self._expand_source_path
                expand_base = self._expand_base_path
            else:
                source_path = card_paths[0] if card_paths else ""
                expand_base = ""
            with_ai = has_flux_prompt_ai_job(card_values)
        else:
            source_path = self._expand_source_path
            expand_base = self._expand_base_path
            with_ai = self._active_job_with_ai

        html = format_image_generation_queue_status_html(
            plugin,
            card_values,
            source_path=source_path,
            base_path=expand_base,
            step=step,
            step_total=step_total,
            elapsed_seconds=elapsed,
            estimate_seconds=estimate,
            running=self._tasks.is_running() or self._job_ai_stage_active,
            omit_live_steps_row=omit_live_steps_row,
            with_ai=with_ai,
        )
        if not html:
            return ""

        if show_next:
            if in_flight and (
                self._expand_base_path
                or self._expand_source_path
                or self._task_reference_paths
            ):
                ref_paths = list(self._task_reference_paths)
                ref_source = self._expand_source_path
                ref_base = self._expand_base_path
            else:
                ref_paths = list(card_paths)
                ref_source = source_path
                ref_base = expand_base
            has_refs = bool(ref_paths or ref_source or ref_base)
        else:
            ref_paths = list(self._task_reference_paths)
            ref_source = self._expand_source_path
            ref_base = self._expand_base_path
            has_refs = bool(ref_paths or ref_source or ref_base)

        if has_refs:
            show_elapsed = bool(ref_source or ref_base)
            expand_elapsed = None
            expand_estimate = None
            if show_elapsed:
                if elapsed is not None:
                    expand_elapsed = elapsed
                    expand_estimate = estimate
                else:
                    expand_elapsed = self._wall_clock_elapsed_seconds(
                        in_cooldown=in_cooldown
                    )
            html, refreshed_paths = refresh_expand_task_status_html_for_display(
                html,
                elapsed_seconds=expand_elapsed,
                estimate_seconds=expand_estimate,
                source_path=ref_source,
                base_path=ref_base,
                reference_paths=ref_paths,
            )
            if not show_next:
                self._task_reference_paths = refreshed_paths
        if in_cooldown:
            html = apply_cooldown_to_status_html(
                html,
                self._cooldown_seconds_remaining(),
                skip_icon_html=cooldown_skip_icon_html(),
            )
        if (
            not omit_live_steps_row
            and self._step_progress_start_time is not None
            and self._live_step_total > 0
        ):
            display_elapsed = elapsed
            if display_elapsed is None:
                display_elapsed = self._wall_clock_elapsed_seconds(
                    in_cooldown=in_cooldown
                )
            html = update_status_html_steps_progress(
                html,
                self._live_step,
                self._live_step_total,
                elapsed_seconds=display_elapsed,
                estimate_seconds=estimate,
            )
        return html

    def get_task_queue_status_view(self, *, omit_live_steps_row: bool = False):
        """Structured status view for job queue cards (rebuilt from live state)."""
        from imagegen_plugins.job_status_views import (
            EMPTY_QUEUE_STATUS_VIEW,
            apply_cooldown_to_queue_status,
            update_queue_status_steps,
        )
        from imagegen_plugins.model_task_status_info import (
            build_job_ai_stage_queue_status_view,
            build_queue_job_status_view,
            refresh_expand_task_status_view_for_display,
        )

        plugin = self._active_plugin
        if plugin is None:
            return EMPTY_QUEUE_STATUS_VIEW

        show_next = self._active_job_card_shows_next_copy()
        card_values = self._active_job_card_values()
        card_paths = self._active_job_card_source_paths()

        if self._job_ai_stage_active and not show_next:
            elapsed, estimate = self._snapshot_live_timing(in_cooldown=False)
            if elapsed is None:
                elapsed = self._wall_clock_elapsed_seconds(in_cooldown=False)
            step = None
            step_total = None
            if not omit_live_steps_row and self._live_step_total > 0:
                step = self._live_step
                step_total = self._live_step_total
            view = build_job_ai_stage_queue_status_view(
                plugin,
                self._pending_values,
                running=self._tasks.is_running(),
                step=step,
                step_total=step_total,
                elapsed_seconds=elapsed,
                estimate_seconds=estimate,
            )
            self._task_status_view = view
            return view

        from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job

        in_cooldown = self._is_in_copy_cooldown()
        in_flight = self._tasks.is_running() or self._job_ai_stage_active
        elapsed, estimate = self._snapshot_live_timing(in_cooldown=in_cooldown)
        step = self._live_step if self._live_step_total > 0 else None
        step_total = self._live_step_total if self._live_step_total > 0 else None
        if show_next:
            if in_flight and (
                self._expand_base_path
                or self._expand_source_path
                or self._task_reference_paths
            ):
                source_path = self._expand_source_path
                expand_base = self._expand_base_path
            else:
                source_path = card_paths[0] if card_paths else ""
                expand_base = ""
            with_ai = has_flux_prompt_ai_job(card_values)
        else:
            source_path = self._expand_source_path
            expand_base = self._expand_base_path
            with_ai = self._active_job_with_ai

        view = build_queue_job_status_view(
            plugin,
            card_values,
            step=step,
            step_total=step_total,
            elapsed_seconds=elapsed,
            estimate_seconds=estimate,
            running=self._tasks.is_running() or self._job_ai_stage_active,
            omit_live_steps_row=omit_live_steps_row,
            with_ai=with_ai,
        )
        if view.is_empty():
            self._task_status_view = EMPTY_QUEUE_STATUS_VIEW
            return EMPTY_QUEUE_STATUS_VIEW

        if show_next:
            if in_flight and (
                self._expand_base_path
                or self._expand_source_path
                or self._task_reference_paths
            ):
                ref_paths = list(self._task_reference_paths)
                ref_source = self._expand_source_path
                ref_base = self._expand_base_path
            else:
                ref_paths = list(card_paths)
                ref_source = source_path
                ref_base = expand_base
            has_refs = bool(ref_paths or ref_source or ref_base)
        else:
            ref_paths = list(self._task_reference_paths)
            ref_source = self._expand_source_path
            ref_base = self._expand_base_path
            has_refs = bool(ref_paths or ref_source or ref_base)

        if has_refs:
            show_elapsed = bool(ref_source or ref_base)
            expand_elapsed = None
            expand_estimate = None
            if show_elapsed:
                if elapsed is not None:
                    expand_elapsed = elapsed
                    expand_estimate = estimate
                else:
                    expand_elapsed = self._wall_clock_elapsed_seconds(
                        in_cooldown=in_cooldown
                    )
            view, refreshed_paths = refresh_expand_task_status_view_for_display(
                view,
                elapsed_seconds=expand_elapsed,
                estimate_seconds=expand_estimate,
                source_path=ref_source,
                base_path=ref_base,
                reference_paths=ref_paths,
            )
            if not show_next:
                self._task_reference_paths = refreshed_paths
        if in_cooldown:
            view = apply_cooldown_to_queue_status(
                view,
                self._cooldown_seconds_remaining(),
                show_skip=True,
            )
        if (
            not omit_live_steps_row
            and self._step_progress_start_time is not None
            and self._live_step_total > 0
        ):
            display_elapsed = elapsed
            if display_elapsed is None:
                display_elapsed = self._wall_clock_elapsed_seconds(
                    in_cooldown=in_cooldown
                )
            view = update_queue_status_steps(
                view,
                self._live_step,
                self._live_step_total,
                elapsed_seconds=display_elapsed,
                estimate_seconds=estimate,
            )
        self._task_status_view = view
        return view

    def _progressive_images_supported_for_work(self) -> bool:
        """True when the active job or queue includes a progressive-capable pipeline."""
        plugin = self._active_plugin
        if plugin is not None and get_pipeline(
            plugin.pipeline_id
        ).supports_progressive_images:
            return True
        for job in self._queue:
            job_plugin = job.plugin
            if job_plugin is None:
                continue
            if get_pipeline(job_plugin.pipeline_id).supports_progressive_images:
                return True
        return False

    def get_show_progressive_images_menu_state(self) -> Optional[bool]:
        """Return persisted toggle when progressive previews can run, else None."""
        if not self._progressive_images_supported_for_work():
            return None
        return load_show_progressive_images()

    def set_show_progressive_images(self, enabled: bool) -> None:
        """Persist global show_progressive_images for supported pipelines."""
        enabled = bool(enabled)
        save_show_progressive_images(enabled)
        plugin = self._active_plugin
        if plugin is not None:
            self._pending_values["show_progressive_images"] = enabled
        if (
            enabled
            and plugin is not None
            and get_pipeline(plugin.pipeline_id).supports_progressive_images
            and self._tasks.is_running()
            and self._output_path
            and not self._slideshow_is_active()
        ):
            # Worker always copies step PNGs to output_path; show the latest
            # step immediately when the user turns previews on mid-copy.
            self._progressive_browse_opened = False
            self._refresh_progressive_image(self._output_path)
        self.task_status_info_changed.emit()

    _SLIDESHOW_VIEW_MODES = frozenset({"slideshow", "slideshow2", "slideshow3"})

    def _slideshow_is_active(self) -> bool:
        mode = getattr(self.main_window, "current_view_mode", None)
        return mode in self._SLIDESHOW_VIEW_MODES

    def _should_display_progressive_images(self) -> bool:
        """Honor show_progressive_images unless a slideshow is running."""
        return load_show_progressive_images() and not self._slideshow_is_active()

    def _active_generation_in_progress_or_cooldown(self) -> bool:
        if self._tasks.is_running():
            return True
        if self._gpu_cleanup_active and self._active_queue_job_id:
            return True
        if self._active_queue_job_id and self._active_plugin is not None:
            return True
        return self._is_in_copy_cooldown() and self._copy_batch_active

    def _paths_associated_with_active_generation(self) -> set[str]:
        """Output, expand source/base, and reference thumbnails for the active job."""
        paths: list[str] = []
        if self._output_path:
            paths.append(self._output_path)
        if self._expand_source_path:
            paths.append(self._expand_source_path)
        if self._expand_base_path:
            paths.append(self._expand_base_path)
        paths.extend(self._task_reference_paths)
        paths.extend(self._active_thumbnail_paths)
        out: set[str] = set()
        for p in paths:
            if p:
                out.add(os.path.normpath(p))
        return out

    def viewing_path_matches_active_generation(self, path: str) -> bool:
        """True when *path* is tied to the active job (output, sources, or cooldown)."""
        if not path or self._active_plugin is None:
            return False
        if not self._active_generation_in_progress_or_cooldown():
            return False
        associated = self._paths_associated_with_active_generation()
        if not associated:
            return False
        return os.path.normpath(path) in associated

    def viewing_path_is_active_generation_output(self, path: str) -> bool:
        """True when *path* is the active job's output file."""
        if not path or not self._output_path:
            return False
        if not self._active_generation_in_progress_or_cooldown():
            return False
        return os.path.normpath(path) == os.path.normpath(self._output_path)

    def snapshot_generation_timing_for_info_panel(
        self,
    ) -> tuple[Optional[float], Optional[float], Optional[int], Optional[int]]:
        """Elapsed, estimate, and step progress for File Information active-job box."""
        if not self._active_generation_in_progress_or_cooldown():
            return None, None, None, None
        in_cooldown = self._is_in_copy_cooldown()
        if not self._tasks.is_running() and not in_cooldown:
            if not (
                self._active_queue_job_id
                and (self._active_plugin is not None or self._gpu_cleanup_active)
            ):
                return None, None, None, None
        elapsed, estimate = self._snapshot_live_timing(in_cooldown=in_cooldown)
        if elapsed is None:
            elapsed = self._wall_clock_elapsed_seconds(in_cooldown=in_cooldown)
        if elapsed is None and (
            self._gpu_cleanup_active or self._active_queue_job_id
        ):
            elapsed = 0.0
        if elapsed is None:
            return None, None, None, None
        step = self._live_step if self._live_step_total > 0 else None
        step_total = self._live_step_total if self._live_step_total > 0 else None
        return elapsed, estimate, step, step_total

    def snapshot_series_progress_for_active_job_strip(
        self,
    ) -> tuple[int, int] | None:
        """Completed and total images for the jobs-pane series progress bar."""
        if not self._copy_batch_active or self._copies_total <= 1:
            return None
        if not self._tasks.is_running() and not self._is_in_copy_cooldown():
            return None
        return self._copies_done, self._copies_total

    def snapshot_queue_jobs_progress_for_active_job_strip(
        self,
    ) -> int | None:
        """Total jobs currently in the queue (live snapshot)."""
        if not self._active_queue_job_id:
            return None
        # Avoid queue_snapshot() here — it can re-enter during strip geometry measurement.
        total = len(self._queue)
        if total <= 1:
            return None
        return total

    def get_task_reference_paths(self) -> list[str]:
        return list(self._task_reference_paths)

    def open_task_reference_paths(self, paths: list[str]) -> None:
        existing = [p for p in paths if p and os.path.isfile(p)]
        if not existing or not hasattr(self.main_window, "refresh_from_configuration"):
            return
        self.main_window.refresh_from_configuration(
            {"files": existing, "sort_mode": "custom"}
        )

    def start_caption(
        self, file_path: str, user_prompt_override: str | None = None
    ) -> bool:
        if self.has_pending_work():
            return False
        self._task_status_info_html = format_caption_status_html(user_prompt_override)
        self.task_status_info_changed.emit()
        if not self._tasks.start_caption_job(file_path, user_prompt_override):
            self._task_status_info_html = ""
            return False
        return True

    def start_caption_foreground(
        self, file_path: str, user_prompt_override: str | None = None
    ) -> bool:
        """Caption via a second worker while generation may be running."""
        if self._foreground_tasks.is_running():
            return False
        return self._foreground_tasks.start_caption_job(
            file_path, user_prompt_override
        )

    def is_foreground_caption_running(self) -> bool:
        return self._foreground_tasks.is_running()

    def cancel_caption(self) -> None:
        """Stop in-flight AI caption jobs without cancelling image generation."""
        if self._tasks.is_running() and self._tasks.active_kind == "caption":
            self._tasks.cancel_task()
        if (
            self._foreground_tasks.is_running()
            and self._foreground_tasks.active_kind == "caption"
        ):
            self._foreground_tasks.cancel_task()
        self._task_status_info_html = ""
        self.task_status_info_changed.emit()
        if self._tasks.is_running():
            self._update_status_bar_indicator(self._tasks.active_kind)
        else:
            self._update_status_bar_indicator(None)
        self._sync_cancel_menu()

    def cancel_flux_prompt_refine(self) -> None:
        """Stop dialog Gen Prompt refinement; never cancel a submitted job's AI stage."""
        if self._job_ai_stage_active:
            return
        if self._tasks.is_running() and self._tasks.active_kind == "flux_prompt":
            self._tasks.cancel_task()
        if (
            self._foreground_tasks.is_running()
            and self._foreground_tasks.active_kind == "flux_prompt"
        ):
            self._foreground_tasks.cancel_task()

    def start_flux_prompt_refine(
        self,
        system_prompt: str,
        user_prompt: str,
        image_path: str | None = None,
        image_paths: list[str] | None = None,
    ) -> bool:
        # IMPORTANT: Keep this background-worker path on the primary _tasks worker.
        # start_flux_prompt_refine_foreground covers concurrent use during generation,
        # but future AI refinement will increase job complexity (multi-step / chained
        # refinement) and must continue to use the main background text pipeline.
        if self.has_pending_work():
            return False
        if not self._tasks.start_flux_prompt_job(
            system_prompt,
            user_prompt,
            image_path=image_path,
            image_paths=image_paths,
        ):
            return False
        return True

    def start_flux_prompt_refine_foreground(
        self,
        system_prompt: str,
        user_prompt: str,
        image_path: str | None = None,
        image_paths: list[str] | None = None,
    ) -> bool:
        """Refine prompt via a second worker while generation may be running."""
        if self._foreground_tasks.is_running():
            return False
        return self._foreground_tasks.start_flux_prompt_job(
            system_prompt,
            user_prompt,
            image_path=image_path,
            image_paths=image_paths,
        )

    def cancel_generation(self, *, entire_job: bool = False) -> None:
        """Cancel in-flight work. Default skips the current copy when more steps remain."""
        active = (
            self.is_running()
            or bool(self._active_queue_job_id)
            or self._copy_batch_active
            or self._job_ai_stage_active
        )
        if not active:
            return
        if entire_job or not self._step_cancel_applies():
            self._copy_batch_cancelled = True
            self._skip_series_copy_requested = False
            self._pending_cancel_job_id = self._active_queue_job_id
        else:
            self._copy_batch_cancelled = False
            self._skip_series_copy_requested = True
            self._pending_cancel_job_id = ""
        self._stop_copy_cooldown_timer()
        self._tasks.cancel_task()
        if (
            not self._tasks.is_running()
            and not self._gpu_cleanup_active
            and not self._job_ai_stage_active
        ):
            if self._copy_batch_cancelled:
                self._finish_copy_batch(cancelled=True)
            elif self._skip_series_copy_requested:
                self._continue_after_aborted_step()

    def schedule_unload_image_model_for_queue_hold(self) -> None:
        """Queue image-model unload after hold + setting checks (next event-loop tick)."""
        QTimer.singleShot(0, self._maybe_unload_image_model_for_queue_hold)

    def _unload_models_when_queue_held_enabled(self) -> bool:
        from config import get_config

        return bool(
            get_config().load_settings().get(
                "imagegen_unload_models_when_queue_held", False
            )
        )

    def _on_tasks_task_finished_for_hold_unload(
        self, kind: str, _success: bool, _err: str
    ) -> None:
        if kind != "generate":
            return
        if not self._hold_job_queue or not self._unload_models_when_queue_held_enabled():
            return
        self.schedule_unload_image_model_for_queue_hold()

    def _maybe_unload_image_model_for_queue_hold(self) -> None:
        """Unload image weights when hold + setting are on and no copy is running."""
        if not self._hold_job_queue or not self._unload_models_when_queue_held_enabled():
            return
        if self._job_ai_stage_active:
            return
        if self._tasks.is_running() or self._foreground_tasks.is_running():
            return
        if self._gpu_cleanup_active:
            return
        if not self._tasks.unload_image_model():
            return
        self._release_main_process_gpu_memory()

    def prepare_for_shutdown(self, *, suppress_failure_ui: bool = True) -> None:
        """Stop any in-flight task without confirmation or failure dialogs."""
        self._quit_after_current_worker = False
        self._deferred_quit_wait_all_jobs = False
        self._dismiss_deferred_quit_dialog()
        if suppress_failure_ui:
            self._suppress_task_failure_ui = True
        self._queue_advance_suppressed = True
        self._persist_job_queue_for_exit()
        self._abort_active_generation_for_shutdown()
        if self._foreground_tasks.is_running():
            self._foreground_tasks.cancel_task()

    def _abort_active_generation_for_shutdown(self) -> None:
        if not self.is_running():
            self._clear_active_generation_state()
            return
        self._copy_batch_cancelled = True
        if self._step_running is not None:
            self._prepend_running_step_to_pending()
        timer = self._cooldown_timer
        if timer is not None and timer.isActive():
            self._stop_copy_cooldown_timer()
        self._tasks.cancel_task()
        self._clear_active_generation_state()

    def _clear_active_generation_state(self) -> None:
        self._remove_aspect_pad_temps()
        self._clear_step_job_state()
        clear_job_active_running_file()
        self._copy_batch_active = False
        self._copies_total = 0
        self._copies_done = 0
        self._copy_batch_cancelled = False
        self._skip_series_copy_requested = False
        self._active_queue_job_id = ""
        self._active_display_index = 0
        self._active_thumbnail_paths = []
        self._reset_generation_state()
        self._update_status_bar_indicator(None)
        self._sync_idle_detector_generation_busy()
        self._update_live_status_timer()

    def _quit_interrupts_active_worker(self) -> bool:
        """True when quitting would cancel an in-flight model worker task."""
        return self._tasks.is_running() or self._foreground_tasks.is_running()

    def _deferred_quit_has_more_work_after_current(self) -> bool:
        """True when wait-for-all would run more copies or queued jobs than quit-after-current."""
        if self._queue:
            return True
        return self._pending_batch_copies() > 1

    def _deferred_quit_work_includes_continuous(self) -> bool:
        """True when executing or queued jobs include continuous series (copies >= 51)."""
        if pending_doc_is_continuous(self._step_pending_doc, self._step_running):
            return True
        if self._copy_batch_active and self._is_series_continuous_total(self._copies_total):
            return True
        return any(self._queued_job_is_continuous(job) for job in self._queue)

    def _deferred_quit_show_wait_for_all_option(self) -> bool:
        """Offer wait-for-all only when more work remains and none of it is continuous."""
        return (
            self._deferred_quit_has_more_work_after_current()
            and not self._deferred_quit_work_includes_continuous()
        )

    def _deferred_quit_status_message(self) -> str:
        if self._deferred_quit_wait_all_jobs:
            return "Prowser will shut down after all queued jobs finish."
        if self._copy_batch_active:
            return (
                "Prowser will shut down after the current copy completes.\n"
                "Existing jobs will be requeued on the next startup."
            )
        return "Prowser will shut down after the current task completes."

    def _deferred_quit_toggle_button_label(self) -> str:
        if self._deferred_quit_wait_all_jobs:
            return "Quit after current copy"
        return "Wait for all"

    def _refresh_deferred_quit_dialog(self) -> None:
        if (
            not self._deferred_quit_show_wait_for_all_option()
            and self._deferred_quit_wait_all_jobs
        ):
            self._deferred_quit_wait_all_jobs = False
            self._queue_advance_suppressed = True
        label = self._deferred_quit_status_label
        if label is not None:
            label.setText(self._deferred_quit_status_message())
        toggle_btn = self._deferred_quit_toggle_btn
        if toggle_btn is not None:
            show_toggle = self._deferred_quit_show_wait_for_all_option()
            toggle_btn.setVisible(show_toggle)
            if show_toggle:
                toggle_btn.setText(self._deferred_quit_toggle_button_label())

    def _show_deferred_quit_dialog(self) -> None:
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import QDialog, QHBoxLayout, QLabel, QPushButton, QVBoxLayout
        from utils import get_button_style, get_dialog_shell_stylesheet

        self._dismiss_deferred_quit_dialog()
        parent = self.main_window
        dialog = QDialog(parent)
        dialog.setWindowTitle("Shutting down")
        dialog.setStyleSheet(get_dialog_shell_stylesheet() + get_button_style())
        dialog.setWindowModality(Qt.WindowModality.ApplicationModal)
        dialog.setMinimumWidth(360)
        layout = QVBoxLayout(dialog)
        layout.setSpacing(18)
        layout.setContentsMargins(22, 18, 22, 18)
        status_label = QLabel(self._deferred_quit_status_message())
        layout.addWidget(status_label)
        from imagegen_plugins.active_job_strip_widget import ActiveJobStripWidget

        progress_strip = ActiveJobStripWidget(
            self.main_window,
            dialog,
            pause_when_imagegen_dialog_building=False,
            layout_width_px=336,
        )
        layout.addWidget(progress_strip, 0, Qt.AlignmentFlag.AlignHCenter)
        button_row = QHBoxLayout()
        toggle_btn = QPushButton(self._deferred_quit_toggle_button_label())
        toggle_btn.clicked.connect(self._toggle_deferred_quit_mode)
        show_toggle = self._deferred_quit_show_wait_for_all_option()
        toggle_btn.setVisible(show_toggle)
        if show_toggle:
            button_row.addWidget(toggle_btn)
        button_row.addStretch()
        cancel_btn = QPushButton("Cancel")
        cancel_btn.setDefault(True)
        cancel_btn.clicked.connect(dialog.reject)
        button_row.addWidget(cancel_btn)
        layout.addLayout(button_row)
        dialog.finished.connect(self._on_deferred_quit_dialog_finished)
        self._deferred_quit_dialog = dialog
        self._deferred_quit_status_label = status_label
        self._deferred_quit_toggle_btn = toggle_btn
        progress_strip.refresh(force=True)
        dialog.show()
        dialog.raise_()
        dialog.activateWindow()

    def _dismiss_deferred_quit_dialog(self) -> None:
        dialog = self._deferred_quit_dialog
        if dialog is None:
            return
        self._deferred_quit_dialog = None
        self._deferred_quit_status_label = None
        self._deferred_quit_toggle_btn = None
        try:
            dialog.blockSignals(True)
            dialog.hide()
            dialog.deleteLater()
        except RuntimeError:
            pass

    def _on_deferred_quit_dialog_finished(self, _result: int) -> None:
        if self._deferred_quit_dialog is not None:
            self._deferred_quit_dialog = None
        self._deferred_quit_status_label = None
        self._deferred_quit_toggle_btn = None
        if not self._quit_after_current_worker:
            return
        self._quit_after_current_worker = False
        self._deferred_quit_wait_all_jobs = False
        self._queue_advance_suppressed = False

    def _resume_deferred_quit_queue_advance(self) -> None:
        if not self._quit_after_current_worker or not self._deferred_quit_wait_all_jobs:
            return
        if self._hold_job_queue:
            return
        if (
            self._copy_batch_active
            and not self._copy_batch_cancelled
            and self._pending_batch_copies() > 0
            and not self._tasks.is_running()
            and not self._is_in_copy_cooldown()
        ):
            QTimer.singleShot(0, self._launch_next_copy_after_cooldown)
            return
        if not self.is_running():
            self._defer_try_start_next_queued_job()

    def _set_deferred_quit_wait_all_jobs(self) -> None:
        self._deferred_quit_wait_all_jobs = True
        self._queue_advance_suppressed = False
        self._exit_queue_persisted = False
        self._queue_persist_suppressed = False
        self._refresh_deferred_quit_dialog()
        QTimer.singleShot(0, self._resume_deferred_quit_queue_advance)

    def _try_complete_deferred_quit_after_current_copy(self) -> None:
        """If quit-after-current was requested and the active unit is done, shut down."""
        if not self._quit_after_current_worker:
            return
        if self._deferred_quit_wait_all_jobs:
            return
        if (
            self._job_ai_stage_active
            or self._tasks.is_running()
            or self._foreground_tasks.is_running()
            or self._is_in_copy_cooldown()
        ):
            if self._deferred_quit_dialog is None:
                self._show_deferred_quit_dialog()
            else:
                self._refresh_deferred_quit_dialog()
            return
        if self._copy_batch_active:
            self._finish_copy_batch()
        self._maybe_quit_after_current_worker()

    def _set_deferred_quit_after_current_copy(self) -> None:
        self._deferred_quit_wait_all_jobs = False
        self._queue_advance_suppressed = True
        self._persist_job_queue_for_exit()
        self._refresh_deferred_quit_dialog()
        self._try_complete_deferred_quit_after_current_copy()

    def _toggle_deferred_quit_mode(self) -> None:
        if self._deferred_quit_wait_all_jobs:
            self._set_deferred_quit_after_current_copy()
        else:
            self._set_deferred_quit_wait_all_jobs()

    def _begin_quit_after_current_worker(self) -> None:
        """Finish the in-flight copy or job, then quit (see _maybe_quit_after_current_worker)."""
        self._quit_after_current_worker = True
        self._deferred_quit_wait_all_jobs = False
        self._queue_advance_suppressed = True
        self._persist_job_queue_for_exit()
        QTimer.singleShot(0, self._try_complete_deferred_quit_after_current_copy)

    def _deferred_quit_pipeline_idle(self) -> bool:
        if self._job_ai_stage_active:
            return False
        if self._tasks.is_running() or self._foreground_tasks.is_running():
            return False
        return not self.has_pending_work()

    def _maybe_quit_after_current_worker(self) -> None:
        if not self._quit_after_current_worker:
            return
        if self._job_ai_stage_active:
            return
        if self._tasks.is_running() or self._foreground_tasks.is_running():
            # Worker job id is cleared after generation_finished / task_finished handlers.
            QTimer.singleShot(0, self._maybe_quit_after_current_worker)
            return
        if self._deferred_quit_wait_all_jobs:
            if not self._deferred_quit_pipeline_idle():
                return
        self._quit_after_current_worker = False
        self._deferred_quit_wait_all_jobs = False
        self._dismiss_deferred_quit_dialog()
        mw = self.main_window
        if mw is not None:
            QTimer.singleShot(0, mw.close)

    def _finish_current_unit_and_maybe_quit(self) -> bool:
        """End the active copy batch when deferred quit was requested."""
        if not self._quit_after_current_worker:
            return False
        if self._deferred_quit_wait_all_jobs:
            return False
        self._sync_chain_state_to_pending_doc()
        remaining = pending_step_count(self._step_pending_doc)
        if remaining > 0:
            from imagegen_plugins.job_step_persistence import save_job_active_pending

            pending_doc = self._pending_doc_for_persist()
            save_job_active_pending(pending_doc)
            clear_job_active_running_file()
        else:
            from imagegen_plugins.job_step_persistence import (
                save_job_active_pending,
            )

            save_job_active_pending(None)
            clear_job_active_running_file()
        self._finish_copy_batch()
        self._maybe_quit_after_current_worker()
        return True

    def confirm_quit_if_running(self, parent=None) -> bool:
        """Return True if quit may proceed (not running, or user confirmed)."""
        if getattr(self.main_window, "_api_quit_in_progress", False):
            self.prepare_for_shutdown()
            return True
        if self._quit_after_current_worker:
            if self._quit_interrupts_active_worker():
                return False
            if self._deferred_quit_wait_all_jobs and not self._deferred_quit_pipeline_idle():
                return False
            return True
        if not self._quit_interrupts_active_worker():
            return True
        parent = parent or self.main_window
        from imagegen_plugins.active_job_strip_widget import ActiveJobStripWidget

        progress_strip = ActiveJobStripWidget(
            self.main_window,
            None,
            pause_when_imagegen_dialog_building=False,
        )
        msg_box = styled_message_box(
            parent,
            QMessageBox.Question,
            "AI task running",
            "Image generation or an AI caption is in progress.\nQuit anyway?",
            buttons=(
                QMessageBox.StandardButton.No
                | QMessageBox.StandardButton.Yes
                | QMessageBox.StandardButton.Apply
            ),
            default_button=QMessageBox.StandardButton.No,
            button_label_overrides={
                QMessageBox.StandardButton.Yes: "Quit anyway",
                QMessageBox.StandardButton.Apply: "Wait and quit",
            },
            proceed_handlers={
                QMessageBox.StandardButton.Yes: (
                    _CANCEL_PROCEED_NOTE,
                    self.prepare_for_shutdown,
                ),
            },
            middle_widget=progress_strip,
        )
        progress_strip.refresh(force=True)
        msg_box.exec()
        answer = msg_box.result_data["button"]
        if answer == QMessageBox.StandardButton.Apply:
            self._begin_quit_after_current_worker()
            return False
        return answer == QMessageBox.StandardButton.Yes

    def cleanup(self) -> None:
        self._dismiss_deferred_quit_dialog()
        self._quit_after_current_worker = False
        self._deferred_quit_wait_all_jobs = False
        self._startup_queue_hold = False
        if self._startup_queue_release_timer is not None:
            self._startup_queue_release_timer.stop()
        self._queue_advance_suppressed = True
        self._persist_job_queue_for_exit()
        self._copy_batch_cancelled = True
        self._stop_copy_cooldown_timer()
        self._tasks.cleanup()
        self._foreground_tasks.cleanup()
        self._queue.clear()
        self._active_queue_job_id = ""
        self._active_thumbnail_paths = []
        self._reset_generation_state()
        self._sync_idle_detector_generation_busy()

    def _on_foreground_task_finished(self, kind: str, _success: bool, _err: str) -> None:
        if kind == "caption":
            self.caption_finished.emit()
        elif kind == "flux_prompt":
            self.flux_prompt_finished.emit()
        self._maybe_quit_after_current_worker()

    def _on_flux_prompt_chunk_from_worker(self, chunk: str) -> None:
        if self._job_ai_stage_active:
            from imagegen_plugins.model_task_status_info import (
                ai_refine_progress_bucket,
                ai_refine_progress_display_step,
                ai_refine_progress_step_from_chars,
            )

            self._job_ai_chars_received += len(chunk or "")
            raw_step = ai_refine_progress_step_from_chars(self._job_ai_chars_received)
            bucket = ai_refine_progress_bucket(raw_step)
            if bucket > self._job_ai_last_progress_bucket:
                self._job_ai_last_progress_bucket = bucket
                if self._live_step_total > 0:
                    self._live_step = ai_refine_progress_display_step(raw_step)
                self._refresh_job_ai_stage_status_html(running=True)
            return
        self.flux_prompt_chunk.emit(chunk)

    def _on_flux_prompt_ready_from_worker(self, text: str) -> None:
        if self._job_ai_stage_active:
            self._complete_job_ai_stage(text)
            return
        self.flux_prompt_ready.emit(text)

    def _on_flux_prompt_error_from_worker(self, error_message: str) -> None:
        if self._job_ai_stage_active:
            cancelled = error_message == "Cancelled" or self._copy_batch_cancelled
            if cancelled:
                self._fail_job_ai_stage("Cancelled")
            else:
                self._fail_job_ai_stage(error_message)
            return
        self._on_flux_prompt_error(error_message)

    def _on_caption_error(self, error_message: str) -> None:
        if self._suppress_task_failure_ui:
            return
        self.caption_error.emit(error_message)

    def _on_flux_prompt_error(self, error_message: str) -> None:
        if self._suppress_task_failure_ui:
            return
        self.flux_prompt_error.emit(error_message)

    def _on_generation_started(self) -> None:
        self.generation_started.emit()

    def _on_task_started(self, _kind: str) -> None:
        self._sync_cancel_menu()

    def _on_job_processing_started(self, kind: str) -> None:
        self.job_processing_started.emit(kind)
        if kind == "flux_prompt" and self._job_ai_stage_active:
            self._refresh_job_ai_stage_status_html(running=True)
            self._update_status_bar_indicator(kind)
            return
        if kind == "generate":
            if self._task_status_info_html:
                self._task_status_info_html = strip_cooldown_from_status_html(
                    self._task_status_info_html
                )
                if not (self._expand_source_path or self._expand_base_path):
                    self._task_status_info_html = remove_elapsed_row(
                        self._task_status_info_html
                    )
            self._reset_active_job_progress_tracking()
            self._step_progress_start_time = time.perf_counter()
            plugin = self._active_plugin
            cycle_values = self._copy_cycle_exif_values()
            if plugin is not None:
                self._generation_timing_key = build_generation_timing_key(
                    plugin, cycle_values
                )
                self._historical_avg_total_seconds = lookup_average(
                    self._generation_timing_key
                )
            try:
                self._live_step_total = int(cycle_values.get("steps") or 0)
            except (TypeError, ValueError):
                self._live_step_total = 0
            if self._live_step_total > 0 and self._task_status_info_html:
                self._task_status_info_html = update_status_html_steps_progress(
                    self._task_status_info_html,
                    0,
                    self._live_step_total,
                )
                self.task_status_info_changed.emit()
        self._update_status_bar_indicator(kind)
        if kind == "generate" and self._hold_job_queue:
            self._emit_jobs_pane_title_changed()

    def _on_task_finished(self, kind: str, _success: bool, _err: str) -> None:
        if kind == "flux_prompt" and self._job_ai_stage_active:
            if not _success:
                cancelled = _err == "Cancelled" or self._copy_batch_cancelled
                if cancelled:
                    self._fail_job_ai_stage("Cancelled")
                else:
                    self._fail_job_ai_stage(_err or "AI prompt job failed")
            self._sync_cancel_menu()
            return
        if kind == "caption":
            self.caption_finished.emit()
        if kind == "flux_prompt":
            self.flux_prompt_finished.emit()
        if self._copy_batch_active or self._tasks.is_running():
            if self._copy_batch_active:
                self._sync_cancel_menu()
            if self._quit_after_current_worker:
                QTimer.singleShot(0, self._maybe_quit_after_current_worker)
            return
        if not self._tasks.is_running():
            self._sync_cancel_menu()
            if not self._copy_batch_active:
                if not self._queue:
                    self._update_status_bar_indicator(None)
                    self._task_status_info_html = ""
        self._maybe_quit_after_current_worker()

    def _on_generation_finished(
        self, success: bool, output_path: str, error_message: str
    ) -> None:
        plugin = self._copy_cycle_exif_plugin()
        values = self._copy_cycle_exif_values()
        if not output_path:
            output_path = self._output_path
        worker_result = self._tasks.pop_worker_result()
        if worker_result is None and not success:
            worker_result = parse_worker_stdout(self._tasks.stderr_text())

        if self._skip_series_copy_requested:
            QTimer.singleShot(
                0,
                lambda op=output_path: self._continue_after_aborted_step(
                    output_path=op
                ),
            )
            return

        if success and plugin and output_path:
            try:
                include_quantization = self._pipeline_supports_quantization(
                    plugin, values
                )
                local_elapsed = self._live_elapsed_seconds
                if local_elapsed is None and self._step_progress_start_time is not None:
                    local_elapsed = (
                        time.perf_counter() - self._step_progress_start_time
                    )
                elapsed_seconds = resolve_generation_elapsed_seconds(
                    worker_result,
                    output_path,
                    local_elapsed=local_elapsed,
                )
                if elapsed_seconds and elapsed_seconds > 0:
                    timing_key = build_generation_timing_key(plugin, values)
                    if timing_key is not None:
                        record_run(timing_key, elapsed_seconds)
                used_seed = extract_used_seed_from_worker_result(
                    plugin.pipeline_id, worker_result
                )
                if used_seed is None and not values.get("random_seed"):
                    try:
                        used_seed = int(values.get("seed"))
                    except (TypeError, ValueError):
                        used_seed = None
                comment = format_image_exif_prompt(
                    plugin.menu_label(values),
                    prompt_text_for_exif(values),
                    elapsed_seconds=elapsed_seconds,
                    seed=used_seed,
                    steps=values.get("steps"),
                    quantization=(
                        plugin.quantize_for_exif(values)
                        if include_quantization
                        else None
                    ),
                    lora=lora_name_for_exif_from_values(
                        values, pipeline_id=plugin.pipeline_id
                    ),
                    guidance=values.get("guidance_scale"),
                )
                ref_entries, allow_cross_dir = self._exif_reference_entries_for_output(
                    plugin,
                    values,
                    output_path,
                    fallback_source_paths=self._exif_fallback_source_paths(),
                )
                from imagegen_plugins.image_gen_pipeline_modes import (
                    job_run_uses_source_image,
                )

                uses_source_image = job_run_uses_source_image(
                    plugin.pipeline_id, values
                )
                if uses_source_image:
                    # Toolbar toggles update _pending_values mid-run; the EXIF snapshot
                    # must not gate whether subsequent copies use image refinement.
                    will_refine_next = (
                        self._copy_batch_active
                        and not self._copy_batch_cancelled
                        and bool(self._pending_values.get("series_refinement"))
                        and (
                            self._is_series_continuous_total(self._copies_total)
                            or self._copies_done + 1 < self._copies_total
                        )
                    )
                    if ref_entries and not will_refine_next:
                        self._task_reference_paths = source_paths_for_generation_exif(
                            values
                        )
                write_exif_user_comment(
                    output_path,
                    comment,
                    reference_entries=ref_entries,
                    allow_cross_directory_references=allow_cross_dir,
                )
            except Exception:
                pass
            try:
                plugin.persist_reproducible_seed(values, worker_result)
            except Exception:
                pass
            QTimer.singleShot(0, lambda p=output_path: self._open_in_browse(p))
            self.generation_finished.emit(True, output_path, "")
            if plugin.pipeline_id == "mflux_fill_expand":
                remove_expand_base_temp(self._expand_base_path)
                self._expand_base_path = ""
            self._remove_aspect_pad_temps()
            self._complete_running_step_after_copy(output_path=output_path)
            if self._finish_current_unit_and_maybe_quit():
                return
            self.active_job_replace_updatability_changed.emit()
            if not self._series_continues_after_copy_success():
                if self._active_queue_job_id:
                    self._finish_copy_batch()
                else:
                    self._defer_try_start_next_queued_job()
                return
            completed_copy_values = dict(self._copy_cycle_exif_values())
            self._sync_next_copy_chain_from_completed_cycle(
                completed_copy_values,
                output_path=output_path,
            )
            self._enter_copy_cooldown_after_success()
            return

        err = error_message or self._tasks.stderr_text() or "Generation failed."
        cancelled = error_message == "Cancelled" or self._copy_batch_cancelled
        if cancelled:
            pending_cancel = self._pending_cancel_job_id
            active_id = self._active_queue_job_id
            if pending_cancel and active_id and pending_cancel != active_id:
                return
            if pending_cancel and not active_id and not self._copy_batch_cancelled:
                return
        if not cancelled:
            self._remove_partial_output()
        if cancelled:
            if (
                not self._copy_batch_cancelled
                and (
                    self._is_series_continuous_total(self._copies_total)
                    or pending_step_count(self._step_pending_doc) > 0
                )
            ):
                self._skip_series_copy_requested = False
                self._continue_after_aborted_step(output_path=output_path)
                return
            self._repair_cancelled_output_exif_references(output_path)
            self._finish_copy_batch(cancelled=True)
            self.generation_finished.emit(False, output_path, err)
            self._maybe_quit_after_current_worker()
            return
        if not self._suppress_task_failure_ui:
            show_styled_critical(
                self.main_window,
                "Generation failed",
                err[:4000] if err else "Image generation failed.",
            )
        self.generation_finished.emit(False, output_path, err)
        self._finish_copy_batch()
        self._maybe_quit_after_current_worker()

    def _open_in_browse(self, output_path: str) -> None:
        self._cancel_pending_progressive_refresh()
        self._refresh_progressive_image(output_path, force_fullscreen=True)

    def _schedule_progressive_refresh(
        self, output_path: str, *, force_fullscreen: bool = False
    ) -> None:
        """Coalesce step previews so browse refresh does not run every diffusion step."""
        self._pending_progressive_path = output_path
        if force_fullscreen:
            self._pending_progressive_force_fullscreen = True
            self._flush_pending_progressive_refresh()
            return
        if self._progressive_refresh_timer.isActive():
            return
        self._progressive_refresh_timer.start(self._PROGRESSIVE_REFRESH_MIN_INTERVAL_MS)

    def _flush_pending_progressive_refresh(self) -> None:
        self._progressive_refresh_timer.stop()
        path = self._pending_progressive_path
        force = self._pending_progressive_force_fullscreen
        self._pending_progressive_path = ""
        self._pending_progressive_force_fullscreen = False
        if path:
            self._refresh_progressive_image(path, force_fullscreen=force)

    def _cancel_pending_progressive_refresh(self) -> None:
        self._progressive_refresh_timer.stop()
        self._pending_progressive_path = ""
        self._pending_progressive_force_fullscreen = False

    def _repair_cancelled_output_exif_references(self, output_path: str) -> None:
        """Fix progressive-preview References when a job is cancelled mid-run."""
        plugin = self._copy_cycle_exif_plugin()
        if plugin is None or not output_path or not os.path.isfile(output_path):
            return
        try:
            from exif.exif_utils import decode_usercomment, get_usercomment_from_path

            raw = get_usercomment_from_path(output_path)
            if not raw:
                return
            comment = decode_usercomment(raw).strip()
            if not comment.startswith("Image Model:"):
                return
            ref_entries, allow_cross_dir = self._exif_reference_entries_for_output(
                plugin,
                self._copy_cycle_exif_values(),
                output_path,
                fallback_source_paths=self._exif_fallback_source_paths(),
            )
            if not ref_entries:
                return
            write_exif_user_comment(
                output_path,
                comment,
                reference_entries=ref_entries,
                allow_cross_directory_references=allow_cross_dir,
            )
        except Exception:
            pass

    def _exif_fallback_source_paths(self) -> List[str]:
        """Source paths captured at job launch when dialog values omit them."""
        values = self._copy_cycle_exif_values()
        canonical = values.get("_canonical_source_image_paths")
        if isinstance(canonical, list) and canonical:
            paths = source_paths_for_generation_exif(
                {"_canonical_source_image_paths": canonical}
            )
            if paths:
                return paths
        ref_paths = (
            self._copy_cycle_reference_paths
            if self._copy_cycle_values
            else self._task_reference_paths
        )
        expand_src = (
            self._copy_cycle_expand_source_path
            if self._copy_cycle_values
            else self._expand_source_path
        )
        paths: List[str] = []
        seen: set[str] = set()
        for raw in (*ref_paths, expand_src):
            ap = os.path.normpath(os.path.abspath(str(raw or "")))
            if ap and os.path.isfile(ap) and ap not in seen:
                seen.add(ap)
                paths.append(ap)
        return paths

    def _exif_reference_entries_for_output(
        self,
        plugin: ImageGenModelPlugin,
        values: Dict[str, Any],
        output_path: str,
        *,
        fallback_source_paths: Optional[List[str]] = None,
    ) -> tuple[Optional[list], bool]:
        ref_entries = None
        allow_cross_dir = False
        if plugin.pipeline_id == "mflux_fill_infill":
            from imagegen_plugins.pixelmator_export import resolve_infill_reference

            resolved = resolve_infill_reference(
                output_path,
                values.get("pixelmator_doc_name"),
                pixelmator_file_path=values.get("pixelmator_doc_path"),
                fallback_paths=fallback_source_paths,
            )
            if resolved is not None:
                ref_entries = [resolved]
                allow_cross_dir = True
        else:
            from imagegen_plugins.flux_prompt_job import (
                flux_prompt_ai_reference_image_paths,
            )
            from imagegen_plugins.image_gen_pipeline_modes import (
                job_run_uses_source_image,
            )

            extra_paths: List[str] = []
            if fallback_source_paths:
                extra_paths.extend(fallback_source_paths)
            extra_paths.extend(flux_prompt_ai_reference_image_paths(values))
            if not (
                job_run_uses_source_image(plugin.pipeline_id, values)
                or extra_paths
            ):
                return ref_entries, allow_cross_dir
            source_paths = source_paths_for_generation_exif(
                values, extra_paths=extra_paths or None
            )
            ref_entries = reference_entries_for_source_paths(
                source_paths, output_path
            )
            if ref_entries:
                allow_cross_dir = True
        return ref_entries, allow_cross_dir

    def _on_generate_progress(self, msg: Dict[str, Any]) -> None:
        step = msg.get("step")
        step_total = msg.get("step_total")
        step_i = -1
        total_i = 0
        step_updated = False
        if step is not None and step_total is not None:
            step_i = int(step)
            total_i = int(step_total)
            step_updated = True
            if step_i > 0 and self._step_progress_start_time is not None:
                elapsed_seconds = self._live_generation_elapsed_seconds()
                if elapsed_seconds is not None:
                    self._step_seconds_per_step = elapsed_seconds / step_i
            self._live_step = step_i
            self._live_step_total = total_i
            if (
                step_i >= total_i
                and total_i > 0
                and self._step_progress_completed_at is None
            ):
                self._step_progress_completed_at = time.perf_counter()
        path = msg.get("path")
        if path and self._should_display_progressive_images():
            preview_step = step_i if step is not None else -1
            if preview_step != 0:
                is_final = (
                    step_updated
                    and total_i > 0
                    and step_i >= total_i
                )
                self._schedule_progressive_refresh(
                    str(path), force_fullscreen=is_final
                )
            else:
                self._note_progressive_step_zero(str(path))
        if not step_updated:
            return
        self._task_status_info_html = self._apply_live_steps_progress(
            self._task_status_info_html
        )
        now = time.perf_counter()
        if (
            step_i < total_i
            and now - self._progress_ui_last_emit_at < self._PROGRESS_UI_MIN_INTERVAL_S
        ):
            return
        self._progress_ui_last_emit_at = now
        self.task_status_info_changed.emit()

    def _note_progressive_step_zero(self, output_path: str) -> None:
        """Step 0 preview is empty or redundant; avoid a full browse refresh."""
        mw = self.main_window
        current = getattr(mw, "current_image_path", None)
        if (
            current
            and os.path.normpath(current) == os.path.normpath(output_path)
            and getattr(mw, "current_view_mode", None) == "browse"
        ):
            self._progressive_browse_opened = True
        if getattr(mw, "debug_mode", False):
            from debug_log import debug_timestamp

            print(
                f"{debug_timestamp()} [imagegen] skip progressive refresh "
                f"(step=0 path={output_path})",
                flush=True,
            )

    @staticmethod
    def _progressive_image_readable(output_path: str) -> bool:
        ext = os.path.splitext(output_path)[1].lower()
        if ext not in (".png", ".webp", ".jpg", ".jpeg", ".tif", ".tiff"):
            return True
        try:
            from PIL import Image

            with Image.open(output_path) as img:
                img.verify()
            return True
        except Exception:
            return False

    def _refresh_progressive_image(
        self, output_path: str, *, force_fullscreen: bool = False
    ) -> None:
        if not output_path or not os.path.isfile(output_path):
            return
        mw = self.main_window
        if not self._progressive_image_readable(output_path):
            if getattr(mw, "debug_mode", False):
                from debug_log import debug_timestamp

                print(
                    f"{debug_timestamp()} [imagegen] skip progressive refresh "
                    f"(unreadable path={output_path})",
                    flush=True,
                )
            return
        if self._slideshow_is_active():
            if getattr(mw, "debug_mode", False):
                from debug_log import debug_timestamp

                print(
                    f"{debug_timestamp()} [imagegen] skip progressive browse "
                    f"(slideshow active path={output_path})",
                    flush=True,
                )
            return
        # Stepwise previews: match final Image Model / Prompt EXIF (skip last step).
        if not force_fullscreen:
            step = self._live_step
            total = self._live_step_total
            plugin = self._copy_cycle_exif_plugin()
            values = self._copy_cycle_exif_values()
            if (
                step > 0
                and total > 0
                and step < total
                and plugin is not None
                and values
            ):
                try:
                    ref_entries, allow_cross_dir = (
                        self._exif_reference_entries_for_output(
                            plugin,
                            values,
                            output_path,
                            fallback_source_paths=self._exif_fallback_source_paths(),
                        )
                    )
                    elapsed = self._live_generation_elapsed_seconds()
                    make_readable_user_comment_before_browse(
                        output_path,
                        model_name=plugin.menu_label(values),
                        values=values,
                        elapsed_seconds=elapsed,
                        completed_step=step,
                        total_steps=total,
                        reference_entries=ref_entries,
                        allow_cross_directory_references=allow_cross_dir,
                        include_quantization=self._pipeline_supports_quantization(
                            plugin, values
                        ),
                        quantization=plugin.quantize_for_exif(values),
                    )
                    cache_manager = getattr(mw, 'cache_manager', None)
                    if cache_manager:
                        cache_manager.clear_cache_for_file(
                            output_path, metadata_fields={'exif'}
                        )
                except Exception as e:
                    print(
                        "DEBUG make_readable_user_comment_before_browse: "
                        f"{e}"
                    )
        if hasattr(mw, "set_date_sort"):
            mw.set_date_sort(reverse=False, notify=False)
        if not hasattr(mw, "refresh_from_configuration"):
            return
        fullscreen = force_fullscreen or not self._progressive_browse_opened
        self._progressive_browse_opened = True
        mw.refresh_from_configuration(
            {"files": [output_path], "fullscreen": fullscreen},
            from_api=True,
        )

    def _remove_partial_output(self) -> None:
        path = self._output_path
        if not path:
            return
        from prowser_temp_files import cleanup_cancelled_generation_output_artifacts

        cleanup_cancelled_generation_output_artifacts(path)
        if os.path.isfile(path):
            try:
                if os.path.getsize(path) < 64:
                    os.remove(path)
            except OSError:
                pass

    def _enter_copy_cooldown_after_success(self) -> None:
        final_elapsed = self._live_elapsed_seconds
        if final_elapsed is None and self._step_progress_start_time is not None:
            final_elapsed = time.perf_counter() - self._step_progress_start_time
        final_step = self._live_step
        final_step_total = self._live_step_total
        self._frozen_elapsed_seconds = final_elapsed
        self._step_progress_start_time = None
        self._reset_live_queue_progress()
        if self._task_status_info_html and final_elapsed is not None:
            self._task_status_info_html = freeze_status_html_generation_elapsed(
                self._task_status_info_html,
                final_elapsed,
                step=final_step if final_step > 0 else None,
                step_total=final_step_total if final_step_total > 0 else None,
            )
        self.queue_changed.emit()
        self.task_status_info_changed.emit()
        self._schedule_copy_cooldown()
        self._schedule_persist_job_queue()
        self._emit_jobs_pane_title_changed()

    def _pending_batch_copies(self) -> int:
        """Images in the active batch still to generate (including after cooldown)."""
        if not self._copy_batch_active or not self._active_queue_job_id:
            return 0
        if self._is_series_continuous_total(self._copies_total):
            return 1
        return pending_step_count(self._step_pending_doc)

    def _stop_copy_cooldown_timer(self) -> None:
        timer = self._cooldown_timer
        if timer is not None:
            try:
                timer.timeout.disconnect(self._on_copy_cooldown_elapsed)
            except (TypeError, RuntimeError):
                pass
            timer.stop()
            timer.deleteLater()
        self._cooldown_timer = None
        self._cooldown_deadline = None
        self._last_cooldown_ui_second = None

    def _schedule_copy_cooldown(self) -> None:
        self._cooldown_before_next_job = False
        self._schedule_cooldown_timer()

    def _schedule_job_cooldown(self) -> None:
        self._cooldown_before_next_job = True
        self._schedule_cooldown_timer()

    def _schedule_cooldown_timer(self) -> None:
        self._stop_copy_cooldown_timer()
        self._sync_cancel_menu()
        cooldown_ms = (
            self._job_cooldown_ms()
            if self._cooldown_before_next_job
            else self._copy_cooldown_ms()
        )
        if cooldown_ms <= 0:
            QTimer.singleShot(0, self._on_copy_cooldown_elapsed)
            return
        self._update_status_bar_indicator("cooldown")
        self._cooldown_deadline = time.perf_counter() + (cooldown_ms / 1000.0)
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(self._on_copy_cooldown_elapsed)
        self._cooldown_timer = timer
        timer.start(cooldown_ms)
        self._update_live_status_timer()

    def _on_copy_cooldown_elapsed(self) -> None:
        after_job = self._cooldown_before_next_job
        self._cooldown_timer = None
        self._cooldown_deadline = None
        self._cooldown_before_next_job = False
        self._last_cooldown_ui_second = None
        if after_job:
            if self._quit_after_current_worker and not self._deferred_quit_wait_all_jobs:
                self._maybe_quit_after_current_worker()
                return
            if self._hold_job_queue or self._queue_advance_suppressed:
                return
            self._defer_try_start_next_queued_job()
            return
        if self._quit_after_current_worker and not self._deferred_quit_wait_all_jobs:
            self._finish_copy_batch()
            self._maybe_quit_after_current_worker()
            return
        if self._copy_batch_cancelled:
            self._finish_copy_batch(cancelled=True)
            return
        if self._pending_batch_copies() <= 0:
            self._finish_copy_batch()
            return
        if self._hold_job_queue:
            self.queue_changed.emit()
            self._schedule_persist_job_queue()
            self._emit_jobs_pane_title_changed()
            return
        if self._yield_active_batch_if_not_next_to_run():
            return
        QTimer.singleShot(0, self._launch_next_copy_after_cooldown)

    def _launch_next_copy_after_cooldown(self) -> None:
        if self._quit_after_current_worker and not self._deferred_quit_wait_all_jobs:
            self._finish_copy_batch()
            self._maybe_quit_after_current_worker()
            return
        if self._copy_batch_cancelled:
            self._finish_copy_batch(cancelled=True)
            return
        if self._hold_job_queue:
            return
        if self._pending_batch_copies() <= 0:
            self._finish_copy_batch()
            return
        if not self._copy_batch_active:
            self._finish_copy_batch()
            return
        if self._yield_active_batch_if_not_next_to_run():
            return
        if self._tasks.is_running():
            return
        if not self._start_next_copy_cycle():
            self._finish_copy_batch()

    def _remove_aspect_pad_temps(self) -> None:
        if self._aspect_pad_temp_paths:
            remove_edit_aspect_pad_temps(self._aspect_pad_temp_paths)
            self._aspect_pad_temp_paths = []

    def _cleanup_cancelled_generation_temps(self) -> None:
        from prowser_temp_files import (
            cleanup_cancelled_generation_output_artifacts,
            cleanup_stale_imagegen_worker_temps,
        )

        output_path = self._output_path
        if output_path:
            cleanup_cancelled_generation_output_artifacts(output_path)
        if self._expand_base_path:
            remove_expand_base_temp(self._expand_base_path)
        cleanup_stale_imagegen_worker_temps()

    def _cleanup_infill_batch_assets(self) -> None:
        plugin = self._active_plugin
        if plugin is None or plugin.pipeline_id != "mflux_fill_infill":
            return
        from imagegen_plugins.pixelmator_export import remove_persisted_pixelmator_batch

        remove_persisted_pixelmator_batch(self._pending_values)

    def _finish_copy_batch(self, *, cancelled: bool = False) -> None:
        cancelled_job_id = self._active_queue_job_id if cancelled else ""
        self._stop_copy_cooldown_timer()
        if cancelled:
            self._cleanup_cancelled_generation_temps()
        self._remove_aspect_pad_temps()
        self._cleanup_infill_batch_assets()
        if cancelled:
            self._remove_cancelled_job_from_queue(cancelled_job_id)
        self._persist_job_queue_now()
        self._clear_step_job_state()
        clear_job_active_running_file()
        self._copy_batch_active = False
        self._copies_total = 0
        self._copies_done = 0
        self._copy_batch_cancelled = False
        self._pending_cancel_job_id = ""
        self._active_queue_job_id = ""
        self._active_display_index = 0
        self._active_thumbnail_paths = []
        self._set_gpu_cleanup_status(False)
        self._update_status_bar_indicator(None)
        self._reset_generation_state()
        self.queue_changed.emit()
        self._sync_cancel_menu()
        self._emit_jobs_pane_title_changed()
        if not self._hold_job_queue and not self._queue_advance_suppressed:
            if self._queue and self._job_cooldown_ms() > 0:
                self._schedule_job_cooldown()
            else:
                self._defer_try_start_next_queued_job()
        # Re-evaluate after queue advance (and after worker clears its active job id).
        QTimer.singleShot(0, self._sync_idle_detector_generation_busy)
        self._update_live_status_timer()

    def _defer_try_start_next_queued_job(
        self, *, delay_ms: int = 0
    ) -> None:
        """Coalesce queue-advance attempts onto one timer."""
        if self._queue_advance_suppressed or self._hold_job_queue:
            return
        if self._startup_queue_hold:
            return
        if not self._queue:
            return
        if self._active_queue_job_id:
            return
        timer = self._try_start_next_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self._try_start_next_queued_job)
            self._try_start_next_timer = timer
        if timer.isActive():
            return
        timer.start(max(0, int(delay_ms)))

    def _try_start_next_queued_job(self) -> None:
        if self._quit_after_current_worker and not self._deferred_quit_wait_all_jobs:
            self._maybe_quit_after_current_worker()
            return
        if self._queue_advance_suppressed or self._hold_job_queue:
            if self._quit_after_current_worker and self._deferred_quit_wait_all_jobs:
                self._maybe_quit_after_current_worker()
            return
        if self._active_queue_job_id:
            return
        if not self._queue:
            if (
                self._quit_after_current_worker
                and self._deferred_quit_wait_all_jobs
                and not self.is_running()
            ):
                self._maybe_quit_after_current_worker()
            return
        if (
            self._tasks.is_running()
            or self._tasks.worker_needs_cleanup()
            or self._is_in_copy_cooldown()
            or self._gpu_cleanup_active
        ):
            self._defer_try_start_next_queued_job(
                delay_ms=self._GPU_CLEANUP_POLL_MS
            )
            return
        job = self._queue[0]
        if job.plugin_unavailable or job.plugin is None:
            show_styled_critical(
                self.main_window,
                "Job queue",
                f"The first queued job uses an unavailable model ({job.plugin_id}). "
                "Edit or remove it to continue.",
            )
            return
        if job.references_invalid:
            show_styled_critical(
                self.main_window,
                "Job queue",
                "The first queued job has missing reference files. "
                "Edit or remove it to continue.",
            )
            return
        result = self._start_generation_now(
            job.plugin,
            job.values,
            job_id=job.job_id,
            status_html=job.status_html,
            thumbnail_paths=job.thumbnail_paths,
            from_queue=True,
        )
        if result is None:
            return
        if result is False:
            show_styled_critical(
                self.main_window,
                "Job queue",
                "Could not start the next queued job.",
            )
            return

    def _reset_generation_state(self) -> None:
        self._stop_copy_cooldown_timer()
        self._suppress_task_failure_ui = False
        self._job_ai_stage_active = False
        self._active_job_with_ai = False
        self._launch_refined_prompt = ""
        self._active_plugin = None
        self._output_path = ""
        self._pending_values = {}
        self._next_copy_display_values = {}
        self._progressive_browse_opened = False
        self._task_status_info_html = ""
        self._expand_source_path = ""
        self._expand_base_path = ""
        self._aspect_pad_temp_paths = []
        self._task_reference_paths = []
        self._clear_copy_cycle_exif_snapshot()
        self._reset_active_job_progress_tracking()

    def _sync_cancel_menu(self) -> None:
        action = getattr(self.main_window, "imagegen_cancel_action", None)
        if action is not None:
            action.setEnabled(self.has_pending_work())

    def _update_status_bar_indicator(self, task_kind: str | None) -> None:
        mgr = getattr(self.main_window, "status_bar_manager", None)
        if mgr is None:
            return
        if task_kind in ("generate", "caption", "cooldown", "cleanup"):
            mgr.show_model_task_indicator(task_kind)
        else:
            mgr.hide_model_task_indicator()


def get_imagegen_controller(main_window) -> ImageGenController:
    ctrl = getattr(main_window, "_imagegen_controller", None)
    if ctrl is None:
        ctrl = ImageGenController(main_window)
        main_window._imagegen_controller = ctrl
        if getattr(main_window, "_startup_refresh_complete", False):
            from thumbnails.thumbnail_constants import STARTUP_QUEUE_RELEASE_DELAY_MS

            ctrl.schedule_startup_queue_release(
                delay_ms=STARTUP_QUEUE_RELEASE_DELAY_MS
            )
    return ctrl
