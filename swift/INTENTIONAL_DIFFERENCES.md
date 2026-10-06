# Swift vs Python — UI/UX differences (quick reference)

Planning reference only. Python reference: `~/dev/testchat/image_browser`. Each row is one remaining difference (not exact parity). See `PARITY.md` for port status.

| Swift | Python |
|-------|--------|
| Standalone browser: no **Image** menu, **Chat** pane, or **Job Control** sidebar | **Image** creation/editing, **Chat**, and **Job Control** are part of the full app |
| **`--min`**: hides **Face Recognition** in Preferences | **`--min`**: hides image-generation-related UI (frozen bundle / launch flag) |
| **Preferences…** under the application menu (⌘,) | **Settings…** under **File** (⌘,); both use window title **Prowser Preferences** |
| **Move to** / **Copy to** as its own menu-bar menu (title follows move vs copy setting) | Separate **Move to** or **Copy to** top-level menu (same title rules) |
| **Help → Image Search (Native)…** | No equivalent help entry |
| No **PF Keys…** or **Hidden Gems…** help | **Help → PF Keys…** and **Help → Hidden Gems…** |
| **F6** toggles sharpen when zoomed in browse (persisted) | No **F6** sharpen toggle |
| **⌥T**, **⌥P**, **⌥O**, **⌥I** show one sidebar pane and hide siblings on that side | No matching shortcuts |
| Search menu: **Identify Faces in Current Image…** (⇧⌘P) | Search menu: **Extract Faces** (⇧⌘P); thumbnail menu uses **Extract Faces** |
| Information sidebar: native structured layout | Information sidebar: HTML page |
| **⌘I** cycles thumbnail overlay (none → name → size → both) | **View → Information Overlay Toggle** (⌘I) with a single menu item whose label changes with state |
| Search / View menus: fewer labeled section breaks | Menus use section headings (e.g. **Physical File**, **UI elements**, **macOS Display Mode**) |
| **Find visually similar** (tree): compares across resolutions with the same aspect shape | **Find visually similar**: compares only within the same oriented pixel width×height |
| Similar-image and text search may rank or order results differently; optional on-device fallback when models are missing | Similar/text search follows installed PyTorch model behavior |
| Face Recognition: in-app **download face models** prompts when weights are missing | Face stack assumes models available via install / bundle (no Swift-style first-run download sheet) |
| Preferences: no **Captioning** or **LoRA** tabs | **Captioning** and **LoRA** tabs when not in minimal bundle |
| Floating **Slideshow3**: basic speed keys; not all tuning keys wired | Floating **Slideshow3**: additional number-key controls (e.g. 3–6, 9, 0) |
| **About Prowser** primarily from the application menu | **About…** also listed under **File** |
| Edit menu: **Copy Path** | Edit menu: **Copy File Path** (same ⌘C shortcut on thumbnails) |
| **⌘E** Edit User Comment opens MFLUX JSON as formatted **Image model** / **Prompt** text | **⌘E** shows raw MFLUX JSON in the editor (File Information still formats JSON for display) |
