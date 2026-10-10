# Swift image browser and optional image generation (WithGen)

The Swift app is a **standalone macOS image browser**. Browsing, thumbnails, EXIF, native Core ML search, and face recognition run in Swift without requiring the PySide6 UI or an external Python checkout.

## Optional image generation

When **not** launched with `--min` / `PROWSER_MIN_BUNDLE`, the app can expose **Image** menu items, the unified generation dialog, and **Job Control** UI.

| Component | Role |
|-----------|------|
| **`swift/ImageGenPython/`** (bundled in the app) | Pipeline workers (`imagegen_plugins/pipelines/*.py`), LoRA ops worker (`lora_ops_worker.py`), and shared inference deps |
| **`ImageGenPluginCatalogSnapshot.json`** | Swift dialog field layouts + merged defaults (regenerate via `Scripts/generate_imagegen_catalog_snapshot.sh` when Python reference plugins change) |
| **`ImageGenPluginCatalog.swift`** | Runtime plugin ids, pipeline routing, availability |
| **`LoRAService`** | Disk-first LoRA registry (`lora_catalog.json`), settings grid, run-dialog choices, submit-time path resolution (Swift) |
| **`lora_ops_worker.py`** | Import LoRA, Check LoRAs probes, find-origin (torch / HF; requires venv) |
| **Profile venv** (`~/.swift-prowser/venvs/imagegen` by default) | `python3 -m venv` + `requirements-imagegen.txt` |
| **`MfluxGenerationTasks`** | MFLUX CLI and bundled Python pipeline workers |
| **`ImageGenMfluxPrep`** | Mask/pad/expand prep before CLI |

Configure in **Preferences → Image Generation**:

- **Imagegen Python environment** — create venv and install dependencies
- **Python executable** — optional override (defaults to venv `python3`)
- **MFLUX venv path** — optional override

Sync vendored Python from the monorepo when developing:

```bash
./Scripts/sync_imagegen_python.sh
```

`sync_imagegen_python.sh` still copies the full reference tree for parity testing; runtime Swift code only **requires** pipelines, `lora_ops_worker`, `lora_bridge` (imported by ops worker), catalog helpers used by workers, and `workers/ipc_json.py`. A future sync whitelist may trim Qt/chat-only modules.

If the bundle or venv is missing, diffusers/MFLUX Python pipelines and LoRA import/probes are unavailable; the Image menu may still appear when MFLUX CLI is installed.

## Not ported / stubbed

- **Flux-prompt AI** queue steps — skipped when the foreground AI bridge is unavailable
- **Chat** and Python CLIP/chat workers
- Whisper / LM Studio captioning (LM Studio uses HTTP from Swift)

Profile data defaults to `~/.swift-prowser` (separate from Python `~/.prowser` unless you point both at the same profile path). LoRA state lives in `data/lora_catalog.json` under the active profile.

## One-line summary

**Swift is the whole app.** Image generation control plane (registry, LoRA catalog, job payloads) is Swift; Python subprocesses run diffusion pipelines and LoRA probe/import utilities only.
