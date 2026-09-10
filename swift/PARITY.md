# Prowser Swift Parity Checklist

Gate for removing the Python PySide6 UI. Check items only when behavior matches the Python app.

Legend: `[ ]` not started · `[~]` partial · `[x]` done

Python references: `menu_manager.py`, `thumbnail_context_menu.py`, `tree_tools_menu.py`, `information_tools_menu.py`, `jobs_tools_menu.py`, `chat_tools_menu.py`, `status_bar_config.py`, `files/file_tree_handler.py`.

## App shell

- [~] Single-instance lock (`data/instance.lock`) + named-pipe forward/listen (`NamedPipeListener`)
- [~] CLI: paths, `-f`/`--filter`, `-p`/`--profile`, `--no-fullscreen`, `--debug`, `--min`
- [~] Apple Events / Finder open-with (`AppDelegate.openFiles`, `Info.plist` document types)
- [~] Default OS fullscreen on launch (unless `--no-fullscreen`; restores `last_macos_space_mode`)
- [~] 3-pane layout: left sidebar | main stack | right sidebar (`ProwserMainSplitView` / NSSplitView; inner pane titlebar drag/double-click fit; persisted splitter sizes + outer column widths)
- [~] Chrome hide/show all panes (F4, `.`, ⌃.` — `AppState.toggleChrome()`; View → Hide/Show Panes)
- [~] Sidebar column collapse when last pane on a side closes (`noteSidebarLayoutChanged`, `right_sidebar_visible` sync)
- [~] Main content relayout on sidebar hide (`mainContentLayoutChanged` → thumbnail grid viewport refresh)
- [~] No window toolbar (navigation by menu + keys only)
- [~] Status bar (`StatusBarView` — image count; `NotificationBubbleOverlay` for transient messages)

## View modes

- [~] Thumbnail grid (`ThumbnailGridNSView` — cache-backed, selection, arrow/return keyboard nav + wrap-around + menu sync + drag-reorder → `.prsort`, browse-exit scroll restore)
- [~] List view (`ImageListView` with thumbnails)
- [~] Browse (`BrowseImageNSView` — zoom, pan, pinch, checkerboard, actual size toggle A + persist across images)
- [~] Slideshow (multiple images — `SlideshowView`, Tools → Slideshow / S key)
- [~] Slideshow2 (panning — `Slideshow2View`, ⇧S)
- [~] Slideshow3 (floating frames — `Slideshow3View` MVP; full Qt parity deferred)

## Left sidebar panes

- [~] File tree (`FileTreeView` — lazy NSOutlineView, root dirs from settings)
- [~] Preview (`PreviewPaneView` — click opens browse)
- [~] Chat (`ChatPaneView` + `ChatController` via `ChatBridge`; persistence when preserve enabled)
- [ ] Jobs (left strip when applicable)

## Right sidebar panes

- [~] Shortcuts (`ShortcutsSidebarView` — favorites + destinations, Click Mode, gear → settings, path tooltips, scroll position persist)
- [~] Information (EXIF, metadata, actions — `InformationPaneView`)
- [~] Jobs queue panel (`JobQueuePanelView` — strip/one/all size modes, ^J cycle, ⌥[/]\\, floating panel ⌘J, progressive preview image)

## Pane titlebars & inline toolbars

Swift panes have **+/−** collapse only. Python `HeaderWidget` panes also expose gear/tools menus and optional action bars.

### All panes (shared)

- [~] Titlebar minus/plus hide/show pane (`SidebarPaneChrome`, config keys per pane)
- [~] Titlebar drag resize (preview, chat, information, jobs)
- [~] Titlebar double-click fit / jobs size cycle
- [ ] Titlebar **context menu** (right-click / control-click on empty titlebar → pane tools menu; Python wires per-pane)
- [ ] Titlebar **gear / tools button** menu (tree, information, jobs, chat)

### File tree pane

- [ ] Inline toolbar: collapse all, rename status, settings, filter presets (all / images only / use filter)
- [ ] Toolbar visibility toggle (“Show Toolbar”) in tools/context menu
- [ ] Tree pane empty-area context menu → same as tools menu (`tree_tools_menu.py`)

### Preview pane

- [ ] Preview-specific titlebar tools (if any beyond drag/fit)

### Chat pane

- [ ] Toolbar actions: system prompt, copy images, clear chat (`chat_tools_menu.py`)
- [ ] Menu extras: preserve chat across sessions, tips dialog, show toolbar toggle

### Information pane

- [ ] Action bar / menu: edit user comment, copy, speak, create image from comment, edit with AI, delete comment (`information_tools_menu.py`)
- [ ] “Show Menu Bar” toggle in context menu

### Job Control pane

- [ ] Toolbar actions: intermediate images, hold queue, skip copy (`jobs_tools_menu.py`)
- [ ] Floating panel: “Always on Top” (when opened as panel)
- [ ] “Show Toolbar” toggle in context menu

### Organize pane

- [~] Favorites/destination links + settings gear (HTML parity)
- [ ] Suppress default WebKit/link context menus on organize links (Python `_NoContextMenuLabel`)

## Context menus

**None ported to Swift yet** (no `NSMenu` / SwiftUI `contextMenu` wiring in `swift/Prowser`).

### Thumbnail grid & list view

Source: `browser_window/managers/thumbnail_context_menu.py`, `thumbnail_canvas.py`, `list_canvas.py`, `list_models.py`.

Trigger: **control-click** on thumbnail (not ⌘-click; multiselect uses ⌘). List rows use same handler.

- [~] Rename (F2 — alert rename in `FileOperationsService.beginRename`; inline rename deferred)
- [~] Delete / Delete… (`ThumbnailContextMenu` + `confirm_delete`)
- [~] Copy pathname (⌘C)
- [~] Copy image (⌃C, single selection)
- [~] Duplicate file(s) (`FileOperationsService.duplicateFiles`)
- [~] Find Similar Images… (⌘K)
- [ ] Show in Directory (⇧⌘H, specific-files mode only)
- [~] Edit in \<external editor\> (⌘E; Pixelmator Pro multi-select exception deferred)
- [~] Edit EXIF User Comment… (⇧⌘E)
- [ ] Convert Format… (⌘M)
- [~] Extract Faces (single file via `FaceBridge.scanDirectory` imagePaths)
- [ ] Show Location on Map (⌘G, when GPS in EXIF)
- [ ] Show Reference Graph (when resolvable EXIF refs)
- [~] Find References to This Image…
- [~] Open in Finder (single)
- [~] Set as Wallpaper submenu (fit/fill/width/height)
- [~] Multiselect disabled-items note at bottom
- [ ] List view row context menu (reuse `ThumbnailContextMenu`)

### File tree — directory entries

Source: `files/file_tree_handler.py` `contextMenuEvent`.

- [ ] Rename… (F2, permission-checked)
- [ ] Search by Description… (⌘F)
- [ ] Search by Person… (⌘P)
- [ ] Copy Directory Path (⌘C)
- [ ] Open in Finder
- [ ] Show All Images inc. Subdirs (⇧A)
- [ ] Find Duplicate Image Files (⇧F)
- [ ] Find Visually Similar Image Files (recursive, folder-scoped)
- [ ] Clear Cache (folder subtree)

### Status bar

Source: `status_bar_config.py` (click/right-click sections).

- [ ] Filter section menu: Edit…, No Filter (\*), saved filter presets with checkmarks
- [ ] Sort section menu: all sort modes + reverse + random + custom (mirrors keyboard sort keys)
- [ ] Image count / selection section menus (properties, date tools, etc. — see Python status bar widgets)
- [ ] Status bar peek-on-hover chrome behavior

## Settings tabs (⌘,)

- [~] General (`GeneralSettingsTab`)
- [~] Favorites (`FavoritesSettingsTab`)
- [~] Directories (`DirectoriesSettingsTab`)
- [~] File Types (`ExtensionsSettingsTab`)
- [~] Destinations (`DestinationsSettingsTab`)
- [~] Excludes (`ExcludesSettingsTab`)
- [~] Theme (`ThemeSettingsTab` + `ThemeService` — subset of color editor)
- [ ] Maps and Editor (deferred)
- [~] Slideshow (`SlideshowSettingsTab` — core timing fields)
- [ ] Models for Search (deferred — Python bridge)
- [ ] Face Recognition (`--min` hidden; deferred)
- [ ] Captioning (`--min` hidden; deferred)
- [ ] LoRA (`--min` hidden; deferred)
- [~] Caches (`CacheSettingsTab` — clear thumbnails)

## Menus — File

- [~] Open Directory… (⌘O)
- [ ] Open File… (⌘⇧O)
- [~] Recent… (`directory_menu_history`; dynamic labels on show)
- [~] Favorites submenu (^1–9 slots)
- [~] Back / Forward (⌘[ / ⌘])
- [~] Move to submenu (destinations 1–9, last drop — currently under File; Python uses top-level Move/Copy menu)
- [ ] Settings… (⌘,)
- [~] Reveal in Finder (⇧⌘R)
- [~] Move to Trash (⌘Delete; `confirm_delete`)
- [~] Refresh (⌘R)
- [ ] View Copy of Trash… (⌘⇧T, when trash has images)
- [ ] Last Image (⌘; browse history swap)
- [ ] Image History (F3)
- [~] Close Window (⌘W) / Quit (⌘Q)
- [~] About (Help menu in Swift; File menu in Python)

## Menus — Edit

- [x] Undo delete (⌘Z — `TrashRestore`)
- [~] Undo move (⌘Z after move — `FileUndoStack`)
- [~] Select All (⌘A) / Deselect All
- [~] Copy Path (⌘⇧C in Swift; Python ⌘C copies path — verify shortcut parity)
- [~] Copy Image (⌘C in Swift; Python ⌃C copies image)
- [ ] Copy user comment
- [~] Lock / Unlock files (⌘L / ⇧⌘L — in Edit menu; Python also in Tools)
- [~] Edit with external editor (⌃E)
- [ ] Rename with Custom Prefix… (⌘N)
- [ ] Convert Image Format… (⌘M)
- [ ] Resize… (⌘⇧Z)

## Menus — View

- [~] Thumbnail / List / Browse (⌘1–3)
- [~] Toggle file tree (View menu + **T** key)
- [~] Toggle preview (**P**)
- [~] Toggle organize / shortcuts sidebar (**O**)
- [~] Toggle information sidebar (**I**; ⌘I still cycles overlay in browse)
- [~] Toggle jobs pane (**J**; ⌘J opens floating panel)
- [~] Show Chat (View menu + **,** key; F9 deferred)
- [~] Toggle status bar (**B**)
- [~] Hide/Show Panes (**F4**, **.**, **⌃.** — `toggleChrome`)
- [ ] Toggle list view (**F12**)
- [ ] Enter / Exit Image Viewer (**F**)
- [~] Cycle thumbnail overlay (⌘I — filename/size states)
- [~] Actual Size toggle (**A** in browse)
- [~] Sort By submenu (static list; Python adds separators, reverse, dynamic checkmarks)
- [~] Theme actions (flat list; Python Theme submenu + custom theme entries)
- [~] macOS Space toggle (⌃⌘F)
- [ ] View Last Image (⌘;, browse-only menu item)
- [ ] Dynamic `aboutToShow` enable/check states (`update_view_menu_enabled_states`)

## Menus — Move / Copy (top-level in Python)

Swift folds destinations into File → Move to. Python has a dedicated menu whose title follows `destination_menu_action` (Move to / Copy to / hidden).

- [~] Destination slots 1–9 (⌘1–9 move; ⌥⌘1–9 copy via keyboard)
- [~] Last drop location (⌘0 / ⌥⌘0)
- [ ] Move Work Files…
- [ ] Edit Destinations… (opens Settings → Destinations)
- [ ] Dynamic visibility when `destination_menu_action` is `none`
- [ ] Per-slot labels from configured paths on menu open

## Menus — Search

- [~] Find Similar Image Files… (⌘K — CNN worker)
- [ ] Search by Text… (⌘F / ⌘⇧K — CLIP reorder)
- [~] Search by Person… (⌘P)
- [ ] Quick Person Search (⌃⌘P)
- [~] Extract Faces (⇧⌘P in Python Search menu)
- [~] Find Duplicate Image Files — in directory
- [~] Find Duplicate Image Files — recursive (⇧F)
- [ ] Find Similar Image Files submenu (in directory / recursive — separate from ⌘K reorder)
- [ ] Show Image in Directory (⇧⌘H)
- [ ] Dynamic `aboutToShow` (`update_search_menu_states`)

## Menus — Image (generation)

- [~] Create an image from text…
- [ ] Fast create / preset submenu entries (`image_gen_menu.py`)
- [ ] Edit / Expand / Infill dialogs
- [ ] Cancel generation
- [ ] Download models / LoRAs
- [~] Show Job Queue (⌘J floating panel)
- [~] Job queue in right sidebar pane
- [~] Progressive preview path display (full image preview pending)
- [ ] LoRA picker UI (`--min` hidden)

## Menus — Tools

- [ ] Quick Mass Rename… (⌘⇧M)
- [ ] Backup Custom Sort / Restore Custom Sort
- [~] Lock / Unlock (see Edit)
- [~] EXIF and Dates submenu (reset dates, edit/delete user comment; **delete EXIF date** deferred)
- [~] Slideshows submenu (S / ⇧S / ⇧⌃S)
- [~] Create Screen Size Copy submenu
- [~] Wallpaper submenu (⇧⌘W last used + fit modes)
- [~] Find References to This Image…
- [ ] LM Studio / voice / transcription tools (when enabled)
- [~] Debug submenu (⇧⌘D debug, ⌃D view log, ⇧⌘I number overlay)

## Menus — Help

- [~] Keyboard shortcuts (`/` — `KeyboardShortcutsHelpView`)
- [~] About (`AboutView`)

## Dynamic menu & shortcut infrastructure

- [ ] `aboutToShow` handlers refresh labels, checkmarks, enabled state (Python `menu_manager.py` update_* methods)
- [ ] Window-level QAction shortcuts for focus-independent keys (Python adds actions to `main_window`)
- [ ] Menu section headers (UI Elements, Thumbnail Control, etc. — `TextSeparator` widgets)
- [ ] Edit menu macOS system-item stripping (`_clean_edit_menu_periodically`)
- [ ] Destination menu title follows move/copy/none setting
- [ ] Favorites/Recent menus rebuild from config on each open

## Sorting & order

- [~] SortMode: date, exif_date, exif_year, name, size, filesize, dimensions, permissions, custom, random, duplicates (`SortingService`)
- [x] `.prsort` custom order read/write (`PrsortIO`; drag-drop write + directory refresh suppress)
- [~] Drag-drop thumbnail reorder with mtime adjustment (date sort + `drag_drop_auto_date_change`)

## EXIF

- [~] Read/display in Information pane (`ExifService.loadRecord`)
- [~] Edit UserComment (sheet + Tools menu)
- [~] Reset file date to EXIF / reset EXIF to file date (Tools menu)
- [~] Delete UserComment (pane + Tools menu)
- [ ] Delete EXIF date from file
- [~] Batch EXIF confirmation dialogs (`ExifBatchConfirmationSheet`)
- [~] Write UserComment on generated images (`ImageGenController` on completion)
- [ ] Speak user comment (information pane / menu)
- [ ] Reference graph viewer (context menu + EXIF refs)

## File operations

- [~] Move, copy to destinations, delete (Trash)
- [ ] Inline thumbnail rename (F2)
- [ ] Duplicate file
- [ ] Convert image format
- [ ] Resize images
- [ ] Quick mass rename
- [~] Lock / unlock files (⌘L / ⇧⌘L)
- [x] Undo delete (⌘Z)
- [~] Undo move
- [~] External editor (⌃E)
- [~] Find references dialog (`FindReferencesSheet`)
- [ ] Show image in directory (specific-files workflow)
- [ ] Move work files dialog
- [ ] GPS / map display (⌘G)

## Caches & profile compatibility

- [~] Read/write `~/.prowser/data/settings.json`
- [~] Thumbnail disk cache key parity (MD5)
- [~] Metadata cache JSON compatibility
- [~] Chat session persistence

## Python worker bridges

- [~] `ModelTasksBridge` — generate, caption, flux_prompt, progress, cancel
- [~] `CLIPBridge` — Unix socket IPC
- [~] `ChatBridge` — streaming chat worker
- [~] `FaceBridge` — directory scan worker
- [~] `SimilaritySearchBridge` — CNN search worker
- [~] `PersonSearchBridge` — face match worker
- [~] `WhisperBridge` — WAV transcription worker
- [~] `workers/ipc_json.py`
- [~] ImageGen UI wiring (create sheet, job queue)
- [~] Chat pane; person-search dialog

## Keyboard shortcuts

- [~] `KeyboardHandlerController` — core navigation, sort keys, sidebars (partial: T/O/P/B/J/F12/F9/, gaps remain)
- [~] Browse zoom, transforms, actual size, overlay
- [~] ⌘1–9 destinations, ^1–^9 favorites, / help
- [~] ⌘+arrow multiselect, ⇧-range select
- [~] Thumbnail cell size +/- / 0, Page Up/Down
- [~] Slideshow keys
- [ ] F2 rename, F3 image history, F12 list toggle
- [ ] ⌘F CLIP search, ⌘G map, ⌘⇧H show in directory
- [ ] ⌘N rename prefix, ⌘M convert, ⌘⇧Z resize

## Suggested implementation order (M9+)

1. **Context menus — thumbnails** (highest user-visible gap; reuse existing services)
2. **View menu completeness** (T/O/P/B/J/F12/F9/, status bar toggle, dynamic labels)
3. **Pane titlebar tools menus** (tree, information, jobs, chat)
4. **File tree directory context menu**
5. **Status bar context menus** (filter, sort)
6. **List view row context menu** (delegate to shared thumbnail menu builder)
7. **Remaining File/Edit/Search/Tools menu entries** + `aboutToShow` refresh
8. **Image gen menu expansion** (edit/expand/infill, downloads)

## Build variants

- [ ] Full build (all AI features)
- [ ] `--min` build (browser + search only, no imagegen/LM Studio/voice UI)
