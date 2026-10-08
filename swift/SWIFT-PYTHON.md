# Swift image browser and optional image generation (WithGen)

The Swift app is a **standalone macOS image browser**. Browsing, thumbnails, EXIF, native Core ML search, and face recognition run in Swift without requiring the PySide6 UI or an external Python checkout.

## Optional image generation

When **not** launched with `--min` / `PROWSER_MIN_BUNDLE`, the app can expose **Image** menu items, the unified generation dialog, and **Job Control** UI.

| Component | Role |
|-----------|------|
| **`swift/ImageGenPython/`** (bundled in the app) | Vendored `imagegen_plugins/pipelines/*.py` and minimal worker deps (no Qt registry bridge) |
| **`ImageGenPluginCatalogSnapshot.json`** | Swift dialog field layouts + merged defaults (regenerate via `Scripts/generate_imagegen_catalog_snapshot.sh`) |
| **`SwiftImageGenRegistry`** | Plugin list, normalize, materialize steps, worker payloads (no Python subprocess for UI) |
| **Profile venv** (`~/.swift-prowser/venvs/imagegen` by default) | System `python3 -m venv` + `requirements-imagegen.txt` (torch, diffusers, mflux, …) |
| **`MfluxGenerationTasks`** | MFLUX CLI and bundled Python pipeline workers |
| **`ImageGenMfluxPrep`** | Mask/pad/expand prep before CLI (ports of PIL helpers) |

Configure in **Preferences → Image Generation**:

- **Imagegen Python environment** — create venv and install dependencies (uses bundled requirements file)
- **Python executable** — optional override (defaults to venv `python3`)
- **MFLUX venv path** — optional override (defaults to imagegen venv `bin/`)

Sync vendored Python from the monorepo when developing:

```bash
./Scripts/sync_imagegen_python.sh
```

If the bundle or venv is missing, the **Image** menu stays disabled.

## Not ported / stubbed

- **LoRA** — `LoRABridge` + `lora_bridge.py` worker; Settings LoRA tab, run-dialog stack picker, `snapshot_job_values.py` at submit; weights under `~/.cache/image_browser/mflux_loras`; catalog in profile `data/lora_catalog.json`
- **Flux-prompt AI** queue steps — skipped when the foreground AI bridge is unavailable
- **Chat** and Python CLIP/chat workers
- Whisper / LM Studio captioning (LM Studio uses HTTP from Swift)

Profile data defaults to `~/.swift-prowser` (separate from Python `~/.prowser` unless you point both at the same profile path).

## One-line summary

**Swift is the whole app.** Image generation uses bundled ImageGenPython plus a profile venv and local MFLUX CLIs—not the full Python image browser process or an external repo root.
