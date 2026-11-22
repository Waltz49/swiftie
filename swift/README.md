# Prowser (Swift)

**Prowser** is a native macOS image browser for Apple Silicon. The UI is **Swift**, **AppKit**, and **SwiftUI**. Browsing, thumbnails, EXIF, themes, slideshows, Core ML–based search, and face recognition (native **dlib** bridge) run in-process. Optional local **Image** menu generation uses Swift for jobs and settings and short-lived **Python** subprocess workers (bundled under `ImageGenPython/`) when you configure a profile venv and backends such as MFLUX.

Install the latest DMG from [waltzremote.com](https://waltzremote.com/).

The first time you use AI-heavy features (similarity sort, text search, face recognition, or image generation), the app downloads and caches models; that pass can be slow, later use is much faster. Some Hugging Face downloads need a [huggingface.co](https://huggingface.co/) account and token.

Press **F1** or **/** in the app for in-app help. See [KEYBOARD.md](KEYBOARD.md) for shortcuts.

## Features (partial list)

- Browse images in a grid, list, or fullscreen with keyboard and mouse
- Move, copy, rename, delete (to Trash), lock files, and undo deletes
- Search by image similarity, image description, duplicates, and face recognition
- Slideshows, EXIF tools, external editor integration, set desktop wallpaper
- Optional **Image** menu, job queue, LoRA tools, and model management (hidden with `--min` / minimal bundles)
- Optional chat pane and LM Studio integration (same minimal-build gate)
- Light, Dark, User, and saved custom themes (**View → Theme**)

## Install from the DMG

1. Open the **swift-prowser** installer volume.
2. Drag **prowser_swift.app** (or the app shown on the volume) into **Applications**.
3. Launch from Applications. Grant privacy permissions when macOS prompts you.

## Requirements

- **macOS 14+** on Apple Silicon (developed on a 16GB M2 class machine)
- **Xcode Command Line Tools** and **Swift 5.9+** to build from source (`Package.swift`, target `Prowser`)
- **cmake** and **git** to build the vendored native **dlib** face encoder (or use `--skip-dlib` when running)
- Optional image generation: **Python 3.12+** profile venv (`venvs/imagegen`, packages from bundled `requirements-imagegen.txt`). Configure under **Settings → Image Generation**. Maintainer details: [SWIFT-PYTHON.md](SWIFT-PYTHON.md)

## Build and run from this folder

```bash
./setup.sh          # once: resolve SwiftPM packages, build dlib if needed
./run.sh            # debug build + launch (via open, for keyboard focus)
./run.sh ~/Pictures # open a folder
./Scripts/test.sh   # unit tests (Swift Package Manager; no Xcode GUI)
```

You can also run `swift test` from this directory. Example filter: `swift test --filter QueueJobStatusBuilderTests`.

Release app bundle:

```bash
./Scripts/build_app.sh
open ~/tmp/prowser_swift.app
```

Use `./Scripts/run.sh --foreground` to see log output in Terminal. Use `./Scripts/run.sh --skip-dlib` to skip the native dlib build.

### Command-line options

Pass options to `./run.sh` after the script flags; they are forwarded to the `Prowser` binary. Run `./run.sh --help` or launch the binary with `-h`.

| Flag | Purpose |
|------|---------|
| paths | Directory or image files to open |
| `-f`, `--filter` PATTERN | Session-only glob filter |
| `-p`, `--profile` DIR | Profile root (default `~/.swift-prowser`) |
| `--fullscreen` | Launch in macOS Space fullscreen |
| `--no-fullscreen` | Launch windowed |
| `--debug` | Enable debug mode |
| `--min` | Hide image generation, chat, and related UI (same as minimal bundle) |

Environment: `PROWSER_PROFILE` (same as `-p`), `PROWSER_FAST_EXIT=1` (immediate exit on SIGTERM/SIGINT).

Examples:

```bash
./run.sh ~/Pictures
./run.sh -f "*.jpg" ~/Downloads
./run.sh -p ~/.swift-prowser-test
```

## Permissions

On first launch, macOS may ask for Photos, Files, Automation, and related access so Prowser can read and organize images. After granting permissions, quit and relaunch if folders do not appear. DMG installs can be set as the default viewer in System Settings.

Some features differ in sandboxed or bundled builds (for example **View Copy of Trash** may be unavailable in the signed app).

## Settings (profiles)

Settings and caches live under **`~/.swift-prowser/`** by default. Open preferences with **⌘,**.

```bash
./run.sh -p ~/.swift-prowser-test
```

Generated images save to the configured **image creation directory** (default `~/Downloads`).

### Profile layout (typical)

```
~/.swift-prowser/
├── data/
│   ├── settings.json
│   ├── lora_catalog.json          # LoRA registry (image generation)
│   ├── known_faces.json
│   └── instance.lock
├── cache/
│   ├── image_browser_cache/       # thumbnails, metadata
│   ├── swift_native/              # Core ML / Vision / dlib model caches
│   └── image_recognition/
│       └── face_cache/            # per-image face embeddings
├── venvs/
│   └── imagegen/                  # optional Python venv for generation workers
├── tmp/                           # scratch (generation, wallpaper, exports, …)
├── logs/                          # Tools → Debug → View log
└── wallpaper/                     # letterboxed wallpaper files
```

Override the work-temp root in **Settings → Temporary files directory**; when blank, the default is `{profile}/tmp/`.

## Optional image generation (summary)

When image generation UI is enabled, Swift owns the job queue, plugin catalog (`ImageGenPluginCatalogSnapshot.json`), and LoRA registry. Pipeline work runs in bundled Python modules (`swift/ImageGenPython/`) with `PYTHONPATH` pointed at that tree and `PROWSER_PROFILE` set to the active profile. Default generation backend is an optimized persistent worker; **Settings → Image Generation** can select MFLUX CLI instead. Sync vendored Python from the monorepo during development with `./Scripts/sync_imagegen_python.sh`.

## Supported formats

Common formats include JPEG, PNG, GIF, BMP, TIFF, WebP, SVG, HEIC, and HEIF. RAW extensions (CR2, NEF, ARW, DNG, and others) are listed for open-with support. Not every EXIF or edit operation applies to every format.

## Repository layout

| Path | Role |
|------|------|
| `Prowser/` | Application sources (UI, services, bridges) |
| `ProwserTests/` | Swift unit tests |
| `ImageGenPython/` | Bundled pipeline and worker Python (subprocess only) |
| `ProwserDlibBridge/` | Swift ↔ dlib face encoding bridge |
| `Vendor/` | Built `dlib-install` artifact when present |
| `Scripts/` | Build, DMG, model, and catalog maintainer scripts — [Scripts/README.md](Scripts/README.md) |

## License

Use of this software is governed by the [LICENSE](LICENSE) file in this directory (Business Source License 1.1). **About → License** / **Credits** list third-party components (dlib, Core ML models, CLIP/ResNet weights, and optional downloads).