# Intentional UI/UX differences (Swift Prowser vs Python Prowser)

This document summarizes **deliberate or accepted** differences between the **Swift** image browser and the **Python (Qt) development** app, described from a **user’s point of view**. It is not a parity checklist; see `PARITY.md` for implementation status.

*Last informed by Swift port history, `PARITY.md` / `SWIFT-PYTHON.md`, and Cursor development sessions.*

---

## What the Swift app is

- The Swift build is a **standalone macOS image browser**. It does **not** require Python to be installed and does **not** start Python helper processes.
- By default it keeps its own data under **`~/.swift-prowser`** (preferences, caches, sort files). The Python app typically uses **`~/.prowser`**. You can point either app at a shared profile when you intend to share settings and compatible caches.
- Launch option **`--min`** hides face-recognition-related preferences and other generation-adjacent UI for a slimmer browser-focused build.

---

## Features present in Python but not in the Swift browser

These are **intentionally out of scope** for the Swift product (not oversights in a single dialog):

- **AI image generation** (create/edit/expand/infill from text or image), **LoRA management**, and the **job queue / job control pane** workflow tied to generation.
- **Chat** pane and chat-related tools.
- **Whisper / LM Studio** voice input and **AI recaption** flows in EXIF comment editing.
- **Help** entries that exist only in the full Python app (e.g. some **PF Keys** / **Hidden Gems** style help), where Swift still uses placeholders or omits them.
- **Full floating-frame slideshow (Slideshow3) tuning**: several number keys used in Python for extra frame controls are **not** assigned in Swift yet.

If a settings tab or menu item would depend on the above, Swift may show **“not available in the Swift-only image browser”** or hide the entry entirely.

---

## Features in Swift that differ from or extend Python

### Menus and naming

- **Settings** are labeled **Preferences…** (standard macOS wording). The window title is **Prowser Preferences**, with explicit **OK** and **Cancel** to apply or discard changes across tabs.
- Person search uses clearer menu titles: **Search for Known Person…** and **Search for Person in Current Image…** instead of **Search by Person…** and **Quick Person Search**.
- **Help → Image Search (Native)…** explains how on-device search in Swift relates to the Python app (ranking, models, caches). This item is Swift-specific.
- **Resize…** appears on the **thumbnail context menu** in Swift as well as in Edit; in Python, resize is typically reached from **Edit** only.
- Some **File** / **Edit** items are grouped or ordered to follow macOS conventions (e.g. copy actions, undo placement). A few Swift-only navigation items (such as **Back/Forward** in history) may appear at the bottom of **File** where Python does not list them the same way.

### Keyboard shortcuts

- **Copy path**: **⌘⇧C** in Swift (Edit menu and tree context). Python often uses **⌘C** for path on the thumbnail grid, with **⌃C** for copying image pixels.
- **Copy image pixels**: **⌘C** in Swift vs **⌃C** in Python in many contexts.
- **Show one sidebar pane only**: **⌥T**, **⌥P**, **⌥O**, **⌥I** hide sibling panes on that side of the window (Swift).
- **Browse view**: **F6** toggles **sharpening when zoomed in** (persisted in preferences).
- **Browse view**: **⌥−** / **⌥=** fit the image to **viewport width** / **viewport height** (Swift-only; Python uses **^W** for width only).
- **EXIF date / year sorts**: available from **View → Sort By** and the status bar in Swift; Python also exposes some of these via **letter keys** that Swift does not assign yet.
- **Floating Slideshow3**: fewer on-key adjustments than Python (see above).

### Preferences and path fields

- Preference tabs use **collapsible sections** (macOS-style disclosure groups).
- Path fields show **`~/…`** while editing; leaving a field **normalizes spelling to match the disk** (folder/file name casing) and shortens home paths for display—so typed paths in favorites, destinations, and directories **match real volume casing** after you tab or click away.
- **Directories** root list is presented in **column-major order** (sorted case-insensitively), which can feel different from Python’s row layout.
- **Caches** separates **background indexing** controls for native search and documents **Clear Face** vs other cache types; face model files are **downloaded on first use** with a consent dialog rather than relying on a Python `pip` environment.
- Tabs for **captioning**, **LoRA**, and similar generation-only settings are absent or stubbed in the Swift-only browser.

### Image and text search

- **Find similar images (⌘K)** and **search by text (⌘F)** run **on the Mac** (Core ML and/or Apple Vision). Result **order and scores may differ** from Python’s PyTorch/ResNet/CLIP stack even when model names look similar.
- If CNN models are not installed, Swift may use **Vision “feature print”** search; the status area reflects that mode.
- Search indexes and model files for Swift live under a **Swift-specific cache area** when using a shared profile root, so Python and Swift do **not** share the same on-disk feature files for ⌘K/⌘F—only settings and (when configured) **face** libraries overlap.
- Changing search models in preferences can take effect **without restarting** the app (Swift).
- **Background idle indexing** for search is started from the **image count / status bar** menu when models are installed; behavior and progress reporting follow the native implementation.
- Long **find similar** and **search by text** operations show **progress feedback** (including staged updates during multi-step similar-image searches).

### Face recognition and people

- Face features use **built-in native libraries** with **first-run model download**, not the Python `face_recognition` package UI flow.
- When both apps share a profile, **known people** and **face scan caches** can be shared; users should avoid running heavy face scans in **both apps at once** on the same library.
- Settings and progress copy refer to **“known person”** wording consistently in dialogs and status messages.

### Thumbnails, list, and browse

- **Transparent images** in the grid use a **checkerboard** under the image instead of showing transparency as flat white.
- **Filename overlays** can **wrap** long names; row heights adjust in standard, duplicate, EXIF-grouped, and reference-graph layouts.
- **EXIF date sectioning** (grouping thumbnails by capture date) and related overlay behavior follow Swift layout rules.
- **Inline rename** by clicking the filename on a thumbnail or using **F2** in the grid or tree.
- **List view** supports **draggable columns**, extension/comment sorting options, and a **banner** when viewing a single directory’s images.
- **Locked files** can show a **lock overlay** on thumbnails when locking is enabled.
- **Exclude thumbs from view (⌘X)** hides matching folders from the **current thumbnail list** only; it does not remove folders from the tree or from disk (Python’s “ignore” vs “exclude” distinction is preserved in labels and behavior).

### File tree and organize sidebar

- **Disambiguated short labels** for favorites and move/copy destinations: when two slots would both show as `tmp`, labels add parent segments only where needed (e.g. `fred/tmp` vs `/tmp`). **Tooltips and actions still use full paths.** This behavior was specified for Swift and is **not** in the Python mainline UI the same way.
- **Find visually similar files** from the tree groups images by **aspect ratio at a fixed comparison width**, so different resolutions with the same shape can compare together; Python groups by **exact pixel dimensions** (after orientation).

### Information sidebar

- Metadata is shown in a **native structured panel** (not an HTML page). Layout, typography, and link styling aim for the same information but **will not look identical** to Python’s rich HTML view.
- **Speak comment**, reference graph, and comment actions are available where ported; some Python-only comment actions tied to **image generation** are absent in Swift.

### File operations and dialogs

- **Resize** uses the same filter **names** as Python but **output pixels can differ slightly** because resizing is done with the system graphics stack rather than Pillow.
- **About** uses a **custom non-modal about window** (version, build, license/credits in separate readers) rather than only the system about panel.
- **Tools → Debug → View log** opens a **live session log** viewer for the current run.
- **AI captioning / speech** entries in comment or tools menus are omitted in the Swift-only browser; **speak** via the system voice for existing comments remains.

### Slideshows and wallpaper

- Core slideshow modes (**Slideshow**, **panning slideshow**, **floating frames**) exist; floating frames have **reduced** keyboard tuning vs Python.
- Wallpaper and screen-copy tools are present where ported; confirmation text and fullscreen **Space** behavior follow macOS patterns (including launch flags **`--fullscreen`** / **`--no-fullscreen`**).

---

## Shared behavior with known cosmetic or minor UX gaps

These are **not** necessarily intentional long-term differences, but users may notice them today:

- **Sort By** submenu in Swift may lack some separators, reverse-sort placement, or dynamic checkmarks Python shows on every open.
- **Information pane** date/GPS/file-size strings may differ in rounding or punctuation from Python’s HTML formatting.
- **Menu section headers** (group labels inside long menus) from Python may be missing in Swift.
- **Thumbnail / duplicate detection** and **metadata cache** aim to share files with Python when profiles align, but edge cases after **bulk rename** may not migrate every cache type the Python app would update.

---

## How to use this document

- For **“is this a bug?”**: check `PARITY.md` and whether the item is listed here as intentional.
- For **search and faces** when sharing `~/.prowser` with Python: read **Help → Image Search (Native)…** and face-related text in **Preferences → Face Recognition** and **Caches**.
- For **keyboard reference** in Swift only, see `KEYBOARD.md`.
