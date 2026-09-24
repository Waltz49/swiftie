# Swift image browser

The Swift app is a **standalone macOS image browser**. It does not start Python, and it does not use Python ML workers.

Browsing, thumbnails, list/browse/slideshow views, file operations, EXIF (ImageIO), duplicates, **native Core ML image search (⌘K / ⌘F)**, and the rest of the native UI run entirely in Swift.

Python-only features from the original PySide6 app are **not** ported:

- Image generation, LoRAs, job queue
- Chat
- **Search for Known Person** (⌘P) and **Search for Person in Current Image** (⌃⌘P) use **native dlib** in Swift (shared `known_faces.json` + `face_cache/` when profile roots match). The Python app implements the same features with `face_recognition` and older menu labels (**Search by Person…**, **Quick Person Search**).
- Whisper / LM Studio captioning

The Swift browser stores its profile under `~/.swift-prowser` (settings, thumbnail cache, image recognition cache, `.prsort`). That is separate from the Python app’s `~/.prowser`.

See **Help → Image Search (Native)…** for caveats vs the Python app.

## One-line summary

**Swift is the whole app.** No Python helper processes are required or started.
