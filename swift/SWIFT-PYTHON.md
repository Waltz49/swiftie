# Swift image browser

The Swift app is a **standalone macOS image browser**. It does not start Python, and it does not use ML/AI workers.

Browsing, thumbnails, list/browse/slideshow views, file operations, EXIF (ImageIO), duplicates, and the rest of the native UI run entirely in Swift.

Python ML/AI features from the original PySide6 app are **not** part of this browser:

- Image generation, LoRAs, job queue
- Chat
- CLIP text search and background CLIP indexing
- CNN “find similar”
- Face / person search, Quick Person, extract faces
- Whisper / LM Studio captioning

Those items are omitted from menus, settings, keyboard help, and About.

The Swift browser stores its profile under `~/.swift-prowser` (settings, thumbnail cache, `.prsort`). That is separate from the Python app’s `~/.prowser`. The Swift browser will not launch Python workers even if a venv is present.

## One-line summary

**Swift is the whole app.** No Python helper processes are required or started.
