# Swift image browser and optional image generation (WithGen)

The Swift app is a **standalone macOS image browser**. Browsing, thumbnails, EXIF, native Core ML search, and face recognition run in Swift without requiring the PySide6 UI.

## Optional image generation (MFLUX CLI)

When **not** launched with `--min` / `PROWSER_MIN_BUNDLE`, the app can expose **Image** menu items, the unified generation dialog, and **Job Control** UI. Generation does **not** use `model_tasks_worker.py` or Qt.

| Component | Role |
|-----------|------|
| **Python** `imagegen_plugins/registry_bridge.py` | Headless subprocess: plugin list, `build_payload`, availability metadata |
| **Swift** `MfluxGenerationTasks` | Spawns `mflux-generate-*` from the configured venv `bin` |
| **Swift** `ImageGenMfluxPrep` | Mask/pad/expand prep before CLI (ports of PIL helpers) |

Configure in **Preferences → Image Generation**:

- **Python repo root** — checkout containing `imagegen_plugins` (or `PROWSER_PYTHON_ROOT`)
- **Python executable** — optional override for the registry subprocess
- **MFLUX venv path** — venv root or `bin` directory with `mflux-generate`, `mflux-generate-fill`, etc.

If the registry bridge or MFLUX binaries are missing, the **Image** menu stays disabled.

## Not ported / stubbed

- **LoRA** catalog UI and settings editor — stub (“Not implemented yet”); CLI LoRA args are omitted
- **Flux-prompt AI** queue steps — skipped when the foreground AI bridge is unavailable
- **Chat** and Python CLIP/chat workers
- Whisper / LM Studio captioning

Profile data defaults to `~/.swift-prowser` (separate from Python `~/.prowser` unless you point both at the same profile path).

## One-line summary

**Swift is the whole app.** Image generation is optional and uses a thin Python registry plus local MFLUX CLIs—not the full Python image browser process.
