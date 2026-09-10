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
- [x] Jobs queue panel (`JobQueuePanelView` — strip/one/all size modes, ^J cycle, ⌥[/]\\, floating panel ⌘J, progressive preview image)

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

- [x] Toolbar actions: intermediate images, hold queue, skip copy (`jobs_toolbar.py`)
- [x] Floating panel: “Always on Top” (when opened as panel)
- [~] “Show Toolbar” toggle in context menu
- [x] Job cards with structured status rows, drag reorder, edit/cancel, selection + action bar, active progress strip
- [x] Header queue count (`+N` / `=N`) and hold suffix (` - HOLD` / ` - Quiesce`)

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
- [~] Show Location on Map (⌘G, when GPS in EXIF)
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
- [x] Theme (`ThemeSettingsTab` + `ThemeService` — full color editor, custom themes, browse transparency)
- [ ] Maps and Editor (deferred)
- [~] Slideshow (`SlideshowSettingsTab` — core timing fields)
- [ ] Models for Search (deferred — Python bridge)
- [ ] Face Recognition (`--min` hidden; deferred)
- [ ] Captioning (`--min` hidden; deferred)
- [ ] LoRA (`--min` hidden; deferred)
- [~] Caches (`CacheSettingsTab` — clear thumbnails)

## Menus — File

- [~] Open Directory… (⌘O)
- [~] Open File… (⌘⇧O)
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
- [x] Cycle thumbnail overlay (⌘I — filename/size states; centered below thumb, name before size)
- [~] Actual Size toggle (**A** in browse)
- [~] Sort By submenu (static list; Python adds separators, reverse, dynamic checkmarks)
- [x] Theme actions (Theme submenu + custom theme entries)
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

- [~] Create an image from text… (`ImageGenUnifiedDialog` — intro, scroll fields, collapsible AI + custom size)
- [ ] Fast create / preset submenu entries (`image_gen_menu.py`)
- [~] Edit / Expand / Infill dialogs (unified shell: icon switcher, source nav, footer Cancel/Close/Replace/Generate)
- [~] Cancel generation (Image menu + information pane)
- [ ] Download models / LoRAs
- [~] Show Job Queue (⌘J floating panel)
- [~] Job queue in right sidebar pane (AppKit cards + drag reorder)
- [~] Progressive preview path display (tap opens browse)
- [~] Job shortcuts: J pane, ⌘J panel, ⌃J size cycle, ⌥[/]\\, ⌥/, ⇧⌥/, ⌘⌥/
- [ ] LoRA stack picker UI (`--min` hidden; field layout via registry bridge)

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
- [~] Edit UserComment (full dialog: actions, Recaption, image-gen; sheet not non-modal yet)
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
- [~] GPS / map display (⌘G)

## Persistence (`settings.json` and related)

Swift reads/writes the same profile `settings.json` as Python. Items marked **done** are saved/restored in Swift; **partial** has gaps; **missing** is not implemented.

### Window & layout

| Key / area | Python | Swift |
|------------|--------|-------|
| `sidebar_width`, `right_sidebar_width` | done | done |
| `left_splitter_sizes`, `shortcuts_splitter_sizes` | done | done |
| Pane visibility (`file_tree_visible`, `preview_visible`, `chat_visible`, `jobs_visible`, `shortcuts_sidebar_visible`, `information_sidebar_visible`, `status_bar_visible`, `left_sidebar_visible`, `right_sidebar_visible`) | done | done |
| Pane toolbar visibility (`file_tree_show_toolbar`, etc.) | done | done |
| `shortcuts_sidebar_scroll_position` | done | done (`PersistedScrollOffsetReader`) |
| `information_section_expanded` | done | missing (info pane sections not collapsible yet) |
| Main window geometry / position | not persisted (Qt fullscreen) | not persisted |
| `window_size` (browse thumb size memory) | done | missing |

### Session restore

| Key / area | Python | Swift |
|------------|--------|-------|
| `restore_state` nested dict (`last_file`, `last_directory`, `last_view_mode`, `last_macos_space_mode`, `enabled`) | done | done |
| `last_macos_space_mode` | done | done (`WindowFullscreen`) |

### Dialog geometry (`*_dialog_geometry` hex)

| Dialog | Python | Swift |
|--------|--------|-------|
| Settings | done | done |
| Filter | done | done |
| Image-gen unified (`dialog_geometry` in `imagegen`) | done | done |
| Job queue panel (`job_queue_geometry`) | done | done |
| Edit EXIF user comment | done | done |
| Similarity / person search | done | done |
| Find references | done | done |
| Keyboard help / About | done | done |
| EXIF batch confirmation | done | done |
| Generation timing | done | missing |
| Download models / LoRAs debug dialogs | done | missing (image-gen tooling) |

### View & browsing preferences

| Key | Python | Swift |
|-----|--------|-------|
| `thumbnail_filename_visible`, `show_image_size`, `show_extensions` | done | done |
| `thumbnail_cell_size`, `manual_thumbnail_size` | done | done |
| `list_view_row_height` | done | done |
| `browse_view_actual_size` | done | done |
| `sort_mode`, `sort_reversed`, `use_exif_date`, `ignore_exif_rotation` | done | done |
| `filter_pattern`, `filtered_tree`, `saved_filters` | done | done |
| `space_key_mode`, `browse_image_history_save_after_ms` | done | done |
| Slideshow presets / rates / slideshow2/3 tuning | done | done |
| `wrap_around`, `confirm_delete`, `debug_mode` | done | done |
| `raise_status_bar_on_cursor_near_bottom` | done | missing |

### Settings UI state

| Key | Python | Swift |
|-----|--------|-------|
| `theme_settings_groups_expanded`, `general_settings_groups_expanded`, `directories_settings_groups_expanded` | done | done (`CollapsibleSettingsSection`) |
| `settings_dialog_size` fallback | done | partial (geometry hex only) |
| `edit_exif_usercomment_splitter_sizes`, instructions fields | done | partial (geometry + instructions; no splitter) |

### Directories, destinations, theme

| Key | Python | Swift |
|-----|--------|-------|
| `root_directories`, `favorite_directories`, `move_destinations` | done | done |
| `exclude_directories`, `ignore_directories` | done | done |
| `image_creation_directory`, `temporary_files_directory` | done | partial (UI exists; verify all paths) |
| `ui_theme`, `*_theme_colors`, `custom_themes`, `browse_transparency_settings` | done | done |
| `directory_menu_history` | done | done |

### Image-gen & jobs (nested `imagegen` + job JSON files)

| Key / file | Python | Swift |
|------------|--------|-------|
| Per-plugin dialog values / `last_function` | done | done |
| `imagegen_fast_open_action`, queue UI prefs | done | done |
| `jobs_pane_compact`, `jobs_display_mode` | done | done |
| Job queue / active job JSON (`job_step_persistence`) | done | done |

### Chat & search

| Key | Python | Swift |
|-----|--------|-------|
| Chat messages / system prompts (`chat_system_prompts.json`) | done | done |
| CNN / person search last directory settings | done | done |

### On-disk caches (not in `settings.json`)

| Cache | Python | Swift |
|-------|--------|-------|
| Thumbnail MD5 cache | done | done |
| Metadata JSON cache | done | done |
| `.prsort` custom order | done | done |

## Caches & profile compatibility

- [~] Read/write `~/.prowser/data/settings.json`
- [~] Thumbnail disk cache key parity (MD5)
- [~] Metadata cache JSON compatibility
- [~] Chat session persistence

## Python worker bridges

- [~] `ModelTasksBridge` — generate, caption, flux_prompt, progress, cancel
- [~] `ImageGenRegistryBridge` — list_plugins, build_payload, normalize_values, materialize_steps
- [~] `foregroundModelTasks` — second worker for flux_prompt during generation
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

- [~] `KeyboardHandlerController` — core navigation, sort keys, sidebars, F/F12/F5/F10, Home/End
- [~] Browse zoom, transforms, actual size, overlay, ⌘+arrow pan, ^W fit width
- [~] ⌘1–9 destinations, ^1–^9 favorites, / help, ⌘K similar search
- [~] ⌘+arrow multiselect, ⇧-range select, ⇧Home/End range
- [~] Thumbnail cell size +/- / 0; list row height +/- / 0; Page Up/Down
- [~] Slideshow keys (mode 1–3 partial; overlap/presets 7/8/0/9 ported for mode 1)
- [~] F2 rename, F12 list toggle, ⌘Return tree collapse/expand
- [~] F3 browse image history; ⇧Space browse space mode toggle
- [~] ⌘⇧H show image in directory
- [ ] ⌘; last image swap
- [ ] ⌘F CLIP search
- [x] ⌘G map, ⌘O open directory, ⌘⇧O open file, browse double-tap T/P
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
