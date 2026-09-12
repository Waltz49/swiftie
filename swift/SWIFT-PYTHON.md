# Swift ↔ Python architecture

The Swift app is the whole **window and browser**. Python is a **helper process farm** for heavy AI/ML work (and a few EXIF/plugin details). They are not two UIs talking.

Swift draws everything. When it needs a brain that already exists in the original repo, it starts a Python process and passes JSON. The original PySide6 app is a *different* UI that uses the same Python workers and profile. Swift does not launch that Qt window.

## Picture it like a restaurant

**Swift is the dining room** — menus, tables, waiters, the photo album you flip through.

**Python is the kitchen** — models, CLIP, faces, image generation, Whisper. You never sit in the kitchen. The waiter (Swift) writes an order on a ticket (JSON), slides it under the door (stdin), and the kitchen shouts results back (stdout).

## Where Python lives

It points **back at the original Python repo**. Nothing ML-related is copied into `swift/` or into the `.app`.

The built app is a native Swift binary plus resources. At launch it looks for the **parent checkout** — the directory that contains `prowser.py`, `workers/`, `imagegen_plugins/`, `faces/`, and `venv_image_browser/bin/python`.

How it finds that (`PythonLocator` / `ProfilePaths.pythonRoot()`):

1. Env var `PROWSER_PYTHON_ROOT` (highest priority)
2. Walk up from cwd / the `.app` until it sees `prowser.py`
3. Then run `venv_image_browser/bin/python` in that tree (or a system `python3` as a last resort)

`swift/Scripts/run.sh` sets `PROWSER_PYTHON_ROOT` to the repo root (`swift/..`). `swift/Scripts/build_app.sh` writes that **absolute path** into the app’s `Info.plist` (`LSEnvironment`). Default is the same: the folder next to `swift/`, not anything inside the bundle. Override at build time with `--python-root`.

The few `.py` files under `swift/Scripts/` (quick person, faces settings, check LoRAs) are thin launchers. They add the parent repo to `sys.path` and import `workers/`, `faces/`, etc. They are not a self-contained Python app.

| Piece | Where it lives |
|---|---|
| UI + browser | `swift/` and the `.app` |
| Workers, plugins, venv, models code | original repo (parent of `swift/`) |
| Shared settings/caches | `~/.prowser` |

Move the `.app` to a machine that does not have that checkout (and that baked-in path), and browsing still works; generate/chat/CLIP/faces will not.

If Python is missing, the browser still works. Generate / chat / face search / CLIP report “Python worker environment not found.”

## What Swift owns (native)

Pretty much everything you see and most file work:

- App shell: window, 3-pane layout, menus, keyboard, status bar, settings windows, single-instance lock
- Thumbnail grid, list view, browse (zoom/pan), slideshows 1–3
- File tree, preview, shortcuts, information pane, job-queue *panel*
- File ops: open/move/copy/delete/rename/resize/convert, trash, destinations, favorites
- Caches written in Swift: thumbnails, metadata JSON, `.prsort` order
- Most EXIF via Apple ImageIO
- Image-gen *forms* and job queue UI (fields, LoRA picker, progress strip)
- Chat *pane* UI
- Search *dialogs* (CLIP, similar, person)

Image generation is the clearest split: Swift builds the form and queue; Python still runs the models and writes the files.

## What still requires Python

Swift locates the parent repo (`prowser.py`) and `venv_image_browser/bin/python`, then starts **headless workers** — no Qt.

| Worker Swift starts | What Python actually does |
|---|---|
| `workers.model_tasks_worker` | Generate images, caption, flux-prompt (LM Studio) |
| `imagegen_plugins.registry_bridge` | Plugin list, payload/dim math, some EXIF write/read |
| `imagegen_plugins.lora_bridge` | LoRA catalog, import, install |
| `workers.chat_worker` | Streaming LLM chat |
| `workers.face_worker` | Scan a folder for faces |
| `workers.clip_search_worker` | Text/image CLIP search |
| `workers.similarity_search_worker` | CNN “find similar” |
| `workers.person_search_worker` | Match a face across files |
| `workers.whisper_worker` | Speech-to-text from WAV |
| `workers/background_clip_worker.py` | Background CLIP indexing |
| `swift/Scripts/quick_person_worker.py` | Encode faces for Quick Person |
| `swift/Scripts/faces_settings_worker.py` | Face-recognition settings helpers |

Those workers reuse the existing Python packages: `imagegen_plugins/`, `exif/`, `faces/`, `search/`, etc.

Python is also used for:

- **User-comment EXIF** (piexif) when you want Qt-identical prompt/comment text; ImageIO is the fallback
- **Orphan cleanup** (`workers.model_tasks_process_registry`)
- Optional debug: Check LoRAs (`swift/Scripts/run_check_loras.py`)

Swift bridge types live in `swift/Prowser/Bridges/` (`WorkerServices` holds them). `JSONLineProcessBridge` is the shared stdin/stdout client.

## How they talk

Three pipes, plus shared files on disk.

### 1. JSON lines on stdin/stdout (the main one)

`JSONLineProcessBridge` starts:

```text
venv_image_browser/bin/python -u -m workers.chat_worker
```

cwd = repo root; env includes `PROWSER_PYTHON_ROOT` and `PROWSER_PROFILE`.

Swift writes one JSON object per line to stdin:

```json
{"command":"chat","job_id":"...","messages":[...],"system_prompt":"..."}
```

Python writes one JSON object per line to stdout (`ready`, `chunk`, `finished`, `error`, `progress`, …). Shared helper: `workers/ipc_json.py`.

Same pattern for generate, CLIP search, faces, Whisper, LoRA, registry.

### 2. Unix sockets (background CLIP only)

CLIP indexing is long-lived, so it does not use stdin JSON.

- Swift listens on `~/.prowser/data/background_clip_status.sock`
- Swift sends commands to `background_clip_control.sock` (`start`, `pause`, `resume`, `flush_and_pause`, `stop`)
- Worker pushes status JSON back (`running`, indexed counts, …)

Details: `workers/CLIP_IPC.md`. Swift side: `CLIPBridge` + `UnixSocket`.

### 3. Named pipe (second copy of the app)

If you open another Prowser, it writes a JSON line to the first instance’s FIFO (`NamedPipeListener`) — “open this folder” — instead of starting a second UI.

### 4. Shared files (not a live connection)

Both apps read/write the same profile:

- `~/.prowser/data/settings.json`
- thumbnail + metadata caches
- CLIP feature caches
- chat sessions, `.prsort`

That is why Swift and the old Python UI can take turns on the same library.

## One-line summary

**Swift = the app. Python = on-demand AI workers in the original repo.** They communicate with JSON over process pipes (and Unix sockets for CLIP). The original Qt window is not in that loop.
