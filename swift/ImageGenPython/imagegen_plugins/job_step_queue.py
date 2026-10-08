#!/usr/bin/env python3
"""Per-copy job steps: materialize, resolve, and JSON queue documents."""

from __future__ import annotations

import os
import uuid
from typing import Any, Dict, List, Optional, Tuple

from imagegen_plugins.image_gen_field_blocks import is_series_continuous_copies
from imagegen_plugins.image_gen_registry import ImageGenModelPlugin

STEP_VERSION = 1
SERIES_CONTINUOUS_COPIES = 51
CHAIN_STATE_KEY = "chain_state"
CONTINUOUS_MODE_KEY = "continuous_mode"
CONTINUOUS_TEMPLATE_KEY = "continuous_template"


def new_step_id() -> str:
    return uuid.uuid4().hex[:12]


def _json_safe_dict(values: Dict[str, Any]) -> Dict[str, Any]:
    from imagegen_plugins.image_gen_persistence import _json_safe_dict as _persist_safe

    return _persist_safe(values)


def copy_step_from_values(
    values: Dict[str, Any],
    *,
    needs_ai: bool = False,
    step_id: str | None = None,
) -> Dict[str, Any]:
    """Build one CopyStep dict from dialog/job values."""
    from imagegen_plugins.flux_prompt_job import (
        FLUX_PROMPT_AI_JOB_KEY,
        flux_prompt_ai_job_meta,
        has_flux_prompt_ai_job,
    )

    step: Dict[str, Any] = {
        "step_id": step_id or new_step_id(),
        "values": _json_safe_dict(dict(values)),
        "needs_ai": bool(needs_ai),
    }
    if has_flux_prompt_ai_job(values):
        meta = flux_prompt_ai_job_meta(values)
        if meta is not None:
            step[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
    if values.get("series_refinement"):
        step["series_refinement"] = True
    if values.get("series_prompt_refinement"):
        step["series_prompt_refinement"] = True
    return step


def step_values(step: Dict[str, Any] | None) -> Dict[str, Any]:
    if not isinstance(step, dict):
        return {}
    raw = step.get("values")
    return dict(raw) if isinstance(raw, dict) else {}


def step_needs_ai(step: Dict[str, Any] | None) -> bool:
    if not isinstance(step, dict):
        return False
    return bool(step.get("needs_ai"))


def step_flux_prompt_ai_job(step: Dict[str, Any] | None) -> Dict[str, Any] | None:
    from imagegen_plugins.flux_prompt_job import FLUX_PROMPT_AI_JOB_KEY

    if not isinstance(step, dict):
        return None
    meta = step.get(FLUX_PROMPT_AI_JOB_KEY)
    return dict(meta) if isinstance(meta, dict) else None


def merge_step_into_values(step: Dict[str, Any]) -> Dict[str, Any]:
    """Flatten a CopyStep into a values dict for plugins/workers."""
    from imagegen_plugins.flux_prompt_job import FLUX_PROMPT_AI_JOB_KEY

    out = step_values(step)
    meta = step_flux_prompt_ai_job(step)
    if meta is not None:
        out[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
    if step.get("series_refinement"):
        out["series_refinement"] = True
    if step.get("series_prompt_refinement"):
        out["series_prompt_refinement"] = True
    return out


def materialize_steps(
    plugin: ImageGenModelPlugin,
    template_values: Dict[str, Any],
    copies_total: int,
    *,
    first_copy_needs_ai: bool | None = None,
) -> List[Dict[str, Any]]:
    """Expand N copy steps from submit-time template values."""
    from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job

    count = max(1, int(copies_total))
    if count > SERIES_CONTINUOUS_COPIES - 1:
        count = SERIES_CONTINUOUS_COPIES
    has_ai = has_flux_prompt_ai_job(template_values)
    steps: List[Dict[str, Any]] = []
    for index in range(count):
        values = dict(template_values)
        values["copies"] = count
        needs_ai = False
        if has_ai:
            if index == 0:
                needs_ai = True if first_copy_needs_ai is None else bool(first_copy_needs_ai)
            elif values.get("series_prompt_refinement"):
                needs_ai = True
        steps.append(copy_step_from_values(values, needs_ai=needs_ai))
    return steps


def materialize_pending_steps_from_update(
    plugin: ImageGenModelPlugin,
    template_values: Dict[str, Any],
    count: int,
) -> List[Dict[str, Any]]:
    """Materialize remaining copy steps after Update/Replace (Job AI on every step when enabled)."""
    from imagegen_plugins.flux_prompt_job import has_flux_prompt_ai_job

    count = max(0, int(count))
    if count <= 0:
        return []
    has_ai = has_flux_prompt_ai_job(template_values)
    steps: List[Dict[str, Any]] = []
    for _ in range(count):
        values = dict(template_values)
        needs_ai = bool(has_ai)
        steps.append(copy_step_from_values(values, needs_ai=needs_ai))
    return steps


def build_pending_job_doc(
    *,
    job_id: str,
    plugin: ImageGenModelPlugin,
    steps: List[Dict[str, Any]],
    full_prompt: str = "",
    thumbnail_paths: List[str] | None = None,
    steps_done: int = 0,
    continuous_mode: bool = False,
    continuous_template: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    doc: Dict[str, Any] = {
        "version": STEP_VERSION,
        "job_id": job_id,
        "plugin_id": plugin.plugin_id,
        "function": plugin.function,
        "display": {
            "full_prompt": full_prompt,
            "thumbnail_paths": list(thumbnail_paths or []),
        },
        "steps_done": max(0, int(steps_done)),
        "steps": [dict(step) for step in steps],
    }
    if continuous_mode:
        doc[CONTINUOUS_MODE_KEY] = True
    if continuous_template is not None:
        doc[CONTINUOUS_TEMPLATE_KEY] = dict(continuous_template)
    return doc


def sync_chain_state_to_pending_doc(
    doc: Dict[str, Any] | None,
    *,
    output_path: str = "",
    prompt: str = "",
    prior_values: Dict[str, Any] | None = None,
) -> Dict[str, Any] | None:
    """Persist series-chain hints on the pending job doc for restart."""
    if doc is None:
        return None
    out = dict(doc)
    chain: Dict[str, Any] = {}
    if output_path:
        chain["last_output_path"] = str(output_path)
    if prompt:
        chain["last_prompt"] = str(prompt)
    if prior_values:
        chain["last_values"] = _json_safe_dict(dict(prior_values))
    if chain:
        out[CHAIN_STATE_KEY] = chain
    else:
        out.pop(CHAIN_STATE_KEY, None)
    return out


def restore_chain_state_from_pending_doc(
    doc: Dict[str, Any] | None,
) -> tuple[str, str, Dict[str, Any]]:
    if not isinstance(doc, dict):
        return "", "", {}
    chain = doc.get(CHAIN_STATE_KEY)
    if not isinstance(chain, dict):
        return "", "", {}
    output_path = str(chain.get("last_output_path") or "")
    prompt = str(chain.get("last_prompt") or "")
    raw_values = chain.get("last_values")
    values = dict(raw_values) if isinstance(raw_values, dict) else {}
    return output_path, prompt, values


def pending_doc_is_continuous(
    doc: Dict[str, Any] | None,
    running_step: Dict[str, Any] | None = None,
) -> bool:
    if isinstance(doc, dict) and doc.get(CONTINUOUS_MODE_KEY):
        return True
    if isinstance(doc, dict) and isinstance(doc.get(CONTINUOUS_TEMPLATE_KEY), dict):
        return True
    if isinstance(running_step, dict):
        try:
            if is_series_continuous_copies(
                int(step_values(running_step).get("copies", 0))
            ):
                return True
        except (TypeError, ValueError):
            pass
    if isinstance(doc, dict):
        steps = doc.get("steps")
        if isinstance(steps, list):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                try:
                    if is_series_continuous_copies(
                        int(step_values(step).get("copies", 0))
                    ):
                        return True
                except (TypeError, ValueError):
                    continue
    return False


def finalize_pending_doc_for_persist(
    doc: Dict[str, Any] | None,
    *,
    output_path: str = "",
    prompt: str = "",
    prior_values: Dict[str, Any] | None = None,
    continuous_mode: bool = False,
    continuous_template: Dict[str, Any] | None = None,
) -> Dict[str, Any] | None:
    doc = sync_chain_state_to_pending_doc(
        doc,
        output_path=output_path,
        prompt=prompt,
        prior_values=prior_values,
    )
    if doc is None:
        return None
    out = dict(doc)
    if continuous_mode:
        out[CONTINUOUS_MODE_KEY] = True
    else:
        out.pop(CONTINUOUS_MODE_KEY, None)
    if continuous_template is not None:
        out[CONTINUOUS_TEMPLATE_KEY] = dict(continuous_template)
    elif not continuous_mode:
        out.pop(CONTINUOUS_TEMPLATE_KEY, None)
    return out


def build_running_job_doc(
    *,
    job_id: str,
    plugin: ImageGenModelPlugin,
    step: Dict[str, Any],
) -> Dict[str, Any]:
    return {
        "version": STEP_VERSION,
        "job_id": job_id,
        "plugin_id": plugin.plugin_id,
        "function": plugin.function,
        "step": dict(step),
    }


def pending_step_count(doc: Dict[str, Any] | None) -> int:
    if not isinstance(doc, dict):
        return 0
    steps = doc.get("steps")
    if not isinstance(steps, list):
        return 0
    return len(steps)


def pop_pending_step(doc: Dict[str, Any]) -> Tuple[Dict[str, Any] | None, Dict[str, Any]]:
    """Remove and return the first pending step; doc is mutated."""
    steps = doc.get("steps")
    if not isinstance(steps, list) or not steps:
        return None, doc
    step = dict(steps.pop(0))
    doc["steps"] = steps
    return step, doc


def prepend_pending_step(doc: Dict[str, Any], step: Dict[str, Any]) -> Dict[str, Any]:
    steps = doc.get("steps")
    if not isinstance(steps, list):
        steps = []
    doc = dict(doc)
    doc["steps"] = [dict(step)] + [dict(s) for s in steps]
    return doc


def append_pending_step(doc: Dict[str, Any], step: Dict[str, Any]) -> Dict[str, Any]:
    steps = doc.get("steps")
    if not isinstance(steps, list):
        steps = []
    doc = dict(doc)
    doc["steps"] = [dict(s) for s in steps] + [dict(step)]
    return doc


def queued_generate_job_to_step_doc(job: "QueuedGenerateJob") -> Dict[str, Any]:
    """Serialize a QueuedGenerateJob as a step-list job doc for job_queue.json."""
    steps = job.steps
    if not isinstance(steps, list) or not steps:
        steps = materialize_steps(job.plugin, job.values, job.copies_total) if job.plugin else []
    display = {
        "full_prompt": job.full_prompt,
        "thumbnail_paths": list(job.thumbnail_paths or []),
    }
    return {
        "version": STEP_VERSION,
        "job_id": job.job_id,
        "plugin_id": job.plugin_id or (job.plugin.plugin_id if job.plugin else ""),
        "function": job.function or (job.plugin.function if job.plugin else ""),
        "display": display,
        "steps_done": 0,
        "steps": [dict(step) for step in steps],
        "plugin_unavailable": bool(job.plugin_unavailable),
    }


def active_job_step_docs_for_persist(
    *,
    job_id: str,
    plugin: ImageGenModelPlugin,
    running_step: Dict[str, Any] | None,
    pending_doc: Dict[str, Any] | None,
    full_prompt: str = "",
    thumbnail_paths: List[str] | None = None,
) -> tuple[Dict[str, Any] | None, Dict[str, Any] | None]:
    """Build running/pending JSON docs from live controller step state."""
    running_doc = None
    if running_step is not None:
        running_doc = build_running_job_doc(
            job_id=job_id, plugin=plugin, step=running_step
        )
    pending_out = pending_doc
    if pending_out is None and running_step is None:
        return None, None
    if pending_out is None:
        pending_out = build_pending_job_doc(
            job_id=job_id,
            plugin=plugin,
            steps=[],
            full_prompt=full_prompt,
            thumbnail_paths=thumbnail_paths,
        )
    return running_doc, pending_out


def replace_pending_steps(doc: Dict[str, Any], steps: List[Dict[str, Any]]) -> Dict[str, Any]:
    out = dict(doc)
    out["steps"] = [dict(step) for step in steps]
    return out


def resolve_step_before_run(
    plugin: ImageGenModelPlugin,
    step: Dict[str, Any],
    *,
    prior_output_path: str = "",
    prior_prompt: str = "",
    prior_values: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    """Apply lazy chain rules before promoting a step to running."""
    from imagegen_plugins.flux_prompt_job import (
        FLUX_PROMPT_AI_JOB_KEY,
        flux_prompt_ai_job_meta,
        sync_flux_prompt_ai_user_prompt_for_next_copy,
    )
    from imagegen_plugins.image_gen_naming import apply_refinement_source_for_next_copy

    resolved = dict(step)
    values = step_values(resolved)

    if resolved.get("series_refinement") and prior_output_path and os.path.isfile(prior_output_path):
        merged = apply_refinement_source_for_next_copy(values, prior_output_path)
        values = dict(merged)
        resolved["values"] = _json_safe_dict(values)

    if resolved.get("series_prompt_refinement"):
        merged = merge_step_into_values(resolved)
        src = dict(prior_values) if prior_values else merged
        if prior_prompt:
            src = dict(src)
            src["prompt"] = prior_prompt
        sync_flux_prompt_ai_user_prompt_for_next_copy(merged, source_values=src)
        meta = flux_prompt_ai_job_meta(merged)
        if meta is not None:
            resolved[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
            values = step_values(resolved)
            values[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
            resolved["values"] = _json_safe_dict(values)

    if step_needs_ai(resolved):
        meta = flux_prompt_ai_job_meta(resolved) or step_flux_prompt_ai_job(resolved)
        if meta is not None:
            prompt = str(values.get("prompt") or "").strip()
            if prompt:
                meta = dict(meta)
                meta["user_prompt"] = prompt
                resolved[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)

    return resolved


def prepare_step_ai_launch(step: Dict[str, Any]) -> bool:
    """Ensure AI meta exists before LM Studio for a running step."""
    from imagegen_plugins.flux_prompt_job import (
        FLUX_PROMPT_AI_JOB_KEY,
        flux_prompt_ai_job_meta,
    )

    meta = step_flux_prompt_ai_job(step)
    if meta is None:
        return False
    values = step_values(step)
    prompt = str(values.get("prompt") or "").strip()
    if prompt:
        meta = dict(meta)
        meta["user_prompt"] = prompt
        step[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
        values = dict(values)
        values[FLUX_PROMPT_AI_JOB_KEY] = dict(meta)
        step["values"] = _json_safe_dict(values)
    return flux_prompt_ai_job_meta(step) is not None


def queued_job_from_step_doc(
    job_doc: Dict[str, Any],
    plugin: ImageGenModelPlugin | None,
    *,
    plugin_unavailable: bool = False,
) -> "QueuedGenerateJob":
    from imagegen_plugins.flux_prompt_job import effective_job_prompt_for_tooltip
    from imagegen_plugins.model_task_queue import (
        QueuedGenerateJob,
        thumbnail_paths_for_values,
    )

    steps = job_doc.get("steps")
    if not isinstance(steps, list) or not steps:
        values: Dict[str, Any] = {}
    else:
        values = merge_step_into_values(steps[0])
    copies_total = len(steps) if isinstance(steps, list) else 1
    display = job_doc.get("display")
    thumbs: List[str] = []
    full_prompt = effective_job_prompt_for_tooltip(values)
    full_prompt_from_display = False
    if isinstance(display, dict):
        raw_thumbs = display.get("thumbnail_paths")
        if isinstance(raw_thumbs, list):
            thumbs = [str(p) for p in raw_thumbs if p]
        fp = str(display.get("full_prompt") or "").strip()
        if fp:
            full_prompt = fp
            full_prompt_from_display = True
    if not thumbs and plugin is not None:
        thumbs = thumbnail_paths_for_values(plugin, values)
    job = QueuedGenerateJob(
        job_id=str(job_doc.get("job_id") or uuid.uuid4().hex),
        plugin=plugin,
        values=values,
        status_html="",
        thumbnail_paths=thumbs,
        copies_total=copies_total,
        full_prompt=full_prompt,
        full_prompt_from_display=full_prompt_from_display,
        plugin_id=str(job_doc.get("plugin_id") or (plugin.plugin_id if plugin else "")),
        function=str(job_doc.get("function") or (plugin.function if plugin else "")),
        plugin_unavailable=plugin_unavailable,
        steps=[dict(s) for s in steps] if isinstance(steps, list) else [],
    )
    return job
