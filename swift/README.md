# Prowser (Swift)

Prowser is a native macOS image browser for Apple Silicon, built with **Swift**, **AppKit**, and **SwiftUI**. Browse, organize, and search images with keyboard-driven workflows, EXIF tools, on-device Core ML search, face recognition (dlib, with models downloaded on first use), and optional local AI image generation when dependencies are installed.

The latest installable DMG is on the [website](https://waltzremote.com/).

The first time you use AI-based features (similarity sort, text search, face recognition, or **Image** menu generation), the app downloads and caches models; that pass can be slow, later use is much faster. Some Hugging Face downloads need a [huggingface.co](https://huggingface.co/) account and token.

## Features (partial list)

- Browse images in a grid, list, or fullscreen with keyboard and mouse
- Move, copy, rename, delete (to Trash), lock files, and undo deletes
- Search by image similarity, image description, duplicates, and face recognition
- Slideshows, EXIF tools, external editor integration, set desktop wallpaper
- Optional **Image** menu and Job Control for local generation/manipulation ([SWIFT-PYTHON.md](SWIFT-PYTHON.md))
- Light, Dark, User, and saved custom themes (**View → Theme**)
- Chat pane (when enabled) with LM Studio streaming; see [PARITY.md](PARITY.md) for port status

Press **F1** or **/** in the app for in-app help. See [KEYBOARD.md](KEYBOARD.md) for a full shortcut list.

## Install from the DMG

1. Open the **swift-prowser** installer volume.
2. Drag **prowser_swift.app** (or the app shown on the volume) into **Applications**.
3. Launch from Applications. Grant privacy permissions when macOS prompts you.

## Requirements

- **macOS 14+** on Apple Silicon (developed on a 16GB M2 class machine)
- **Xcode Command Line Tools** and **Swift 5.9+** to build from source
- **cmake** and **git** for the bundled native dlib face encoder (or use `--skip-dlib` when running)
- Optional image generation: Python **3.12+** venv under the profile (`requirements-imagegen.txt`); see [SWIFT-PYTHON.md](SWIFT-PYTHON.md)

## Build and run from this folder

```bash
./setup.sh          # once: resolve packages, build dlib if needed
./run.sh            # debug build + launch (via open, for keyboard focus)
./run.sh ~/Pictures # open a folder
./Scripts/test.sh   # unit tests (Swift Package Manager; no Xcode GUI)
```

From the `swift/` directory you can also run `swift test` directly. Optional filters: `swift test --filter QueueJobStatusBuilderTests`.

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
| `--min` | Hide image generation and related UI (same as minimal bundle) |

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

Settings and caches live under **`~/.swift-prowser/`** by default (separate from the legacy Python app’s `~/.prowser` unless you point both at the same path). Open preferences with **⌘,**.

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
│   └── image_recognition/         # shared face_cache (Python-compatible subtree)
├── tmp/                           # scratch (generation, wallpaper, exports, …)
├── logs/                          # Tools → Debug → View log
└── wallpaper/                     # letterboxed wallpaper files
```

Override the work-temp root in **Settings → Temporary files directory**; when blank, the default is `{profile}/tmp/`.

## Supported formats

Common formats include JPEG, PNG, GIF, BMP, TIFF, WebP, SVG, HEIC, and HEIF. Not every EXIF or edit operation applies to every format.

## Development

- **Swift package:** this directory (`Package.swift`, target `Prowser`)
- **Maintainer scripts:** [Scripts/README.md](Scripts/README.md)
- **Python ↔ Swift image generation:** [SWIFT-PYTHON.md](SWIFT-PYTHON.md)
- **Parity checklist:** [PARITY.md](PARITY.md)
- **Known UI differences vs Python reference:** [INTENTIONAL_DIFFERENCES.md](INTENTIONAL_DIFFERENCES.md)

The Python/Qt reference app lives outside this tree; vendored pipeline code under `ImageGenPython/` is used by subprocess workers only, not for the macOS UI.

## License

Use of this software is governed by the [LICENSE](LICENSE) file in this directory (Business Source License 1.1). **About → License** / **Credits** list third-party components (dlib, Core ML models, CLIP/ResNet weights, and optional downloads).