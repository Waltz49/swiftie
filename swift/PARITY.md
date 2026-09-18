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
- [x] Jobs — N/A on left; Python jobs pane is on the right sidebar only (Swift: `RightSidebarView` / `JobQueuePanelView`)

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
- [x] Titlebar **context menu** (right-click / control-click on empty titlebar → pane tools menu; Python wires per-pane)
- [x] Titlebar **gear / tools button** menu (tree, information, jobs, chat)

### File tree pane

- [x] Inline toolbar: collapse all, rename status, settings, filter presets (all / images only / use filter)
- [x] Toolbar visibility toggle (“Show Toolbar”) in tools/context menu
- [x] Tree pane empty-area context menu → same as tools menu (`tree_tools_menu.py`)
- [x] **Keyboard focus:** tree-context shortcuts (⇧F, ⇧A, F2, ⌘C directory path) require file-tree first responder; selecting a folder claims focus (`fileTreeKeyboardFocused`, titlebar highlight)

### Preview pane

- [ ] Preview-specific titlebar tools (if any beyond drag/fit)

### Chat pane

- [x] Toolbar actions: system prompt, copy images, clear chat (`chat_tools_menu.py`)
- [x] Menu extras: preserve chat across sessions, tips dialog, show toolbar toggle

### Information pane

- [x] Action bar / menu: edit user comment, copy, speak, create image from comment, edit with AI, delete comment (`information_tools_menu.py`)
- [x] “Show Menu Bar” toggle in context menu

### Job Control pane

- [x] Toolbar actions: intermediate images, hold queue, skip copy (`jobs_toolbar.py`)
- [x] Floating panel: “Always on Top” (when opened as panel)
- [~] “Show Toolbar” toggle in context menu
- [x] Job cards with structured status rows, drag reorder, edit/cancel, selection + action bar, active progress strip
- [x] Header queue count (`+N` / `=N`) and hold suffix (` - HOLD` / ` - Quiesce`)

### Organize pane

- [~] Favorites/destination links + settings gear (HTML parity)
- [x] Suppress default WebKit/link context menus on organize links (Python `_NoContextMenuLabel`)

## Context menus

Swift uses AppKit `NSMenu` builders (`ThumbnailContextMenu`, `FileTreeContextMenu`, `SidebarPaneContextMenus`, `StatusBarMenus`).

### Thumbnail grid & list view

Source: `browser_window/managers/thumbnail_context_menu.py`, `thumbnail_canvas.py`, `list_canvas.py`, `list_models.py`.

Trigger: **control-click** on thumbnail (not ⌘-click; multiselect uses ⌘). List rows use same handler.

- [x] Rename (F2 — inline rename in `ThumbnailGridNSView`; file-tree F2 uses alert dialog)
- [~] Delete / Delete… (`ThumbnailContextMenu` + `confirm_delete`)
- [~] Copy pathname (⌘C)
- [~] Copy image (⌃C, single selection)
- [~] Duplicate file(s) (`FileOperationsService.duplicateFiles`)
- [~] Find Similar Images… (⌘K) — native Core ML + consent download
- [~] Show in Directory (⇧⌘H — `showImageInDirectory()`)
- [~] Edit in \<external editor\> (⌘E; Pixelmator Pro multi-select exception deferred)
- [~] Edit EXIF User Comment… (⇧⌘E)
- [~] Convert Format… (⌘M — `ConvertFormatSheet`)
- [~] Extract Faces (single file via `FaceBridge.scanDirectory` imagePaths)
- [~] Show Location on Map (⌘G, when GPS in EXIF)
- [~] Show Reference Graph (`ReferenceGraphView` sheet)
- [~] Find References to This Image…
- [~] Open in Finder (single)
- [~] Set as Wallpaper submenu (fit/fill/width/height)
- [~] Multiselect disabled-items note at bottom
- [~] List view row context menu (`ImageListNSView` → `ThumbnailContextMenu`)

### File tree — directory entries

Source: `files/file_tree_handler.py` `contextMenuEvent`. Menu in `FileTreeContextMenu.swift`.

- [~] Rename… (F2, permission-checked)
- [~] Search by Text… (⌘F / ⌘⇧K) — `ClipSearchSheet` + native Core ML
- [~] Search by Person… (⌘P)
- [~] Copy Directory Path (⌘C)
- [~] Open in Finder
- [~] Show All Images inc. Subdirs (⇧A)
- [x] Find Duplicate Image Files (⇧F — file tree keyboard focus only; highlighted folder)
- [~] Find Visually Similar Image Files — `findSimilarInFolder` via `SimilaritySearchBridge`
- [~] Clear Cache (folder subtree)

### Status bar

Source: `status_bar_config.py`. Sort/filter/date menus in `StatusBarMenus.swift`.

- [~] Filter section menu: Edit…, No Filter (\*), saved filter presets with checkmarks
- [~] Sort section menu: all sort modes + random + custom (mirrors keyboard sort keys)
- [x] Image count section menu (background CLIP toggle); filename/dimensions display-only
- [x] Status bar peek-on-hover chrome behavior

## Settings tabs (⌘,)

- [~] General (`GeneralSettingsTab`)
- [~] Favorites (`FavoritesSettingsTab`)
- [~] Directories (`DirectoriesSettingsTab`)
- [~] File Types (`ExtensionsSettingsTab`)
- [~] Destinations (`DestinationsSettingsTab`)
- [~] Excludes (`ExcludesSettingsTab`)
- [x] Theme (`ThemeSettingsTab` + `ThemeService` — full color editor, custom themes, browse transparency)
- [x] Maps and Editor — `MapsEditorSettingsTab` (map app, external editor)
- [~] Slideshow (`SlideshowSettingsTab` — core timing fields)
- [~] Models for Search — `ModelsSearchSettingsTab` (similarity metric/threshold; background CLIP toggles moved to Caches tab)
- [x] Face Recognition — `FaceRecognitionSettingsTab` (`--min` hidden)
- [x] Captioning — `CaptioningSettingsTab` (`--min` hidden)
- [x] LoRA — `LoRASettingsTab` (minimal; imagegen keys)
- [~] Caches (`CacheSettingsTab` — clear thumbnails, image rec, face, scrub; background CLIP toggles)

## Menus — File

- [~] Open Directory… (⌘O)
- [~] Open File… (⌘⇧O)
- [~] Recent… (`directory_menu_history`; dynamic labels on show)
- [~] Favorites submenu (^1–9 slots)
- [~] Back / Forward (⌘[ / ⌘])
- [~] Move to submenu (destinations 1–9, last drop — currently under File; Python uses top-level Move/Copy menu)
- [x] Settings… (⌘,)
- [~] Reveal in Finder (⇧⌘R)
- [~] Move to Trash (⌘Delete; `confirm_delete`)
- [~] Refresh (⌘R)
- [x] View Copy of Trash… (⌘⇧T, when trash has images)
- [x] Last Image (⌘; browse history swap)
- [x] Image History (F3)
- [~] Close Window (⌘W) / Quit (⌘Q)
- [x] About (File + Help menus — non-modal window, License/Credits HTML popups)

## Menus — Edit

- [x] Undo delete (⌘Z — `TrashRestore`)
- [~] Undo move (⌘Z after move — `FileUndoStack`)
- [~] Select All (⌘A) / Deselect All
- [~] Copy Path (⌘⇧C in Swift; Python ⌘C copies path — verify shortcut parity)
- [~] Copy Image (⌘C in Swift; Python ⌃C copies image)
- [x] Copy user comment
- [~] Lock / Unlock files (⌘L / ⇧⌘L — in Edit menu; Python also in Tools)
- [~] Edit with external editor (⌃E)
- [x] Rename with Custom Prefix… (⌘N) — `RenamePrefixSheet` + `RenamePrefixService`/`RenamePrefixPlanner` (names, 3-phase plan, dates, .prsort locks, metadata migration; CNN/CLIP/face MD5 feature hand-off not ported)
- [~] Convert Image Format… (⌘M)
- [x] Resize… (⌘⇧Z)

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
- [x] Toggle list view (**F12**)
- [x] Enter / Exit Image Viewer (**F**)
- [x] Cycle thumbnail overlay (⌘I — filename/size states; centered below thumb, name before size)
- [~] Actual Size toggle (**A** in browse)
- [~] Sort By submenu (static list; Python adds separators, reverse, dynamic checkmarks)
- [x] Theme actions (Theme submenu + custom theme entries)
- [~] macOS Space toggle (⌃⌘F)
- [x] View Last Image (⌘;, browse-only menu item)
- [~] Dynamic `aboutToShow` enable/check states (`MenuRefreshState` + dynamic menu buttons)

## Menus — Move / Copy (top-level in Python)

Swift folds destinations into File → Move to. Python has a dedicated menu whose title follows `destination_menu_action` (Move to / Copy to / hidden).

- [~] Destination slots 1–9 (⌘1–9 move; ⌥⌘1–9 copy via keyboard)
- [~] Last drop location (⌘0 / ⌥⌘0)
- [x] Move Work Files…
- [x] Edit Destinations… (opens Settings → Destinations)
- [x] Dynamic visibility when `destination_menu_action` is `none`
- [~] Per-slot labels from configured paths on menu open

## Menus — Search

- [~] Find Similar Image Files… (⌘K — CNN worker)
- [x] Search by Text… (⌘F / ⌘⇧K — CLIP reorder)
- [~] Search by Person… (⌘P)
- [x] Quick Person Search (⌃⌘P)
- [~] Extract Faces (⇧⌘P in Python Search menu)
- [x] Find Duplicate Image Files — in directory
- [x] Find Duplicate Image Files — recursive (Search menu, click only; no ⇧F — use tree context menu or tree focus + ⇧F)
- [~] Find Similar Image Files submenu (pixel MSE; in directory / recursive)
- [x] Show Image in Directory (⇧⌘H)
- [~] Dynamic `aboutToShow` (`update_search_menu_states`)

## Menus — Image (generation)

- [x] Create an image from text… (`ImageGenUnifiedDialog` — intro, scroll fields, collapsible AI + custom size with pipeline dim limits)
- [~] Fast create / preset submenu entries (`image_gen_menu.py` — ⇧⌥/ fast-open; per-function submenu partial)
- [~] Edit / Expand / Infill dialogs (unified shell: icon switcher, source nav, footer Cancel/Close/Replace/Generate)
- [~] Cancel generation (Image menu + information pane)
- [~] Download models / LoRAs (Help → Downloading AI Models; Check LoRAs in Debug)
- [~] Show Job Queue (⌘J floating panel)
- [~] Job queue in right sidebar pane (AppKit cards + drag reorder)
- [~] Progressive preview path display (tap opens browse)
- [~] Job shortcuts: J pane, ⌘J panel, ⌃J size cycle, ⌥[/]\\, ⌥/, ⇧⌥/, ⌘⌥/
- [x] LoRA stack picker UI (`--min` hidden; field layout via registry bridge)

## Menus — Tools

- [x] Quick Mass Rename… (⌘⇧M)
- [x] Backup Custom Sort / Restore Custom Sort
- [~] Lock / Unlock (see Edit)
- [x] EXIF and Dates submenu (reset dates, edit/delete user comment, delete EXIF date)
- [~] Slideshows submenu (S / ⇧S / ⇧⌃S)
- [~] Create Screen Size Copy submenu
- [~] Wallpaper submenu (⇧⌘W last used + fit modes)
- [~] Find References to This Image…
- [ ] LM Studio / voice / transcription tools (when enabled)
- [~] Debug submenu (⇧⌘D debug, ⌃D view log, ⇧⌘I number overlay, Check LoRAs)

## Menus — Help

- [~] Keyboard shortcuts (`/` — `KeyboardShortcutsHelpView`)
- [x] About (`AboutDialogController` — icon, version, Python version, build date, background jobs, License/Credits HTML windows)

## Dynamic menu & shortcut infrastructure

- [~] `aboutToShow` handlers refresh labels, checkmarks, enabled state (`MenuRefreshState` + dynamic SwiftUI menu buttons)
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
- [x] Delete EXIF date from file
- [~] Batch EXIF confirmation dialogs (`ExifBatchConfirmationSheet`)
- [~] Write UserComment on generated images (`ImageGenController` on completion)
- [x] Speak user comment (information pane / menu)
- [x] Reference graph viewer (context menu + EXIF refs)

## File operations

- [~] Move, copy to destinations, delete (Trash)
- [x] Inline thumbnail rename (F2)
- [x] Duplicate file
- [x] Convert image format
- [x] Resize images (dimensions + percent modes, copy/replace, EXIF UserComment, batch progress+cancel)
- [x] Quick mass rename (`RenamePrefixService.quickMassRename`, gated by `allow_quick_mass_rename`)
- [~] Lock / unlock files (⌘L / ⇧⌘L)
- [x] Undo delete (⌘Z)
- [~] Undo move
- [~] External editor (⌃E)
- [~] Find references dialog (`FindReferencesSheet`)
- [x] Show image in directory (specific-files workflow)
- [x] Move work files dialog
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
| `information_section_expanded` | done | done (`InformationSectionState`) |
| Main window geometry / position | not persisted (Qt fullscreen) | not persisted |
| `window_size` (browse thumb size memory) | done | done (browse return state) |

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
| `raise_status_bar_on_cursor_near_bottom` | done | done (status bar peek) |

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
| `image_creation_directory`, `temporary_files_directory` | done | done (settings + `AppConfig.temporaryFilesDirectory`) |
| `ui_theme`, `*_theme_colors`, `custom_themes`, `browse_transparency_settings` | done | done |
| `shift_cmd_depth` | done | done (`FileTreeView` ⌘⇧↩ expand) |

### Image-gen & jobs (nested `imagegen` + job JSON files)

| Key / file | Python | Swift |
|------------|--------|-------|
| Per-plugin dialog values / `last_function` | done | done |
| `imagegen_fast_open_action`, queue UI prefs | done | done |
| `imagegen_job_cooldown_seconds`, `imagegen_inter_copy_cooldown_seconds` | done | done (`ImageGenDimLimits` + controller) |
| `imagegen_output_format` | done | done (output path extension) |
| `imagegen_max_generation_dimension`, `imagegen_low_ram` | done | done (Python worker/registry reads shared settings; Swift UI reclamps dims on change) |
| `resize_preserve_aspect`, `resize_resample_method`, `resize_delete_original`, `resize_preserve_dates`, `resize_anchor_is_width` | done | done |
| `imagegen_unload_models_when_queue_held` | done | done (`ModelTasksBridge.unloadImageModel`) |
| `use_prompt_filter_exits`, text/image exit scripts, prefix/postfix | done | partial (runtime on Python bridges for prompts) |
| `say_exit` | done | done (`UserCommentSpeaker` + `ExitScriptUtils.sayExitArgv`) |
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
- [~] ⌘; last image swap (`BrowseImageHistoryController.swapFirstTwoAndShow`)
- [~] ⌘F CLIP search (`ClipSearchSheet`)
- [x] ⌘G map, ⌘O open directory, ⌘⇧O open file, browse double-tap T/P
- [x] ⌘N rename prefix (done), ⌘M convert, ⌘⇧Z resize (full dialog)

## Suggested implementation order (M10+)

1. **Gate testing** — profile round-trip, `--min` build, PySide6 UI removal
2. **Slideshow3 full parity** (floating frames)
3. **Rename-prefix CNN/CLIP/face MD5 cache hand-off** after bulk rename
4. **PF Keys / Hidden Gems help** dialogs
5. **Image-gen voice input / favorite prompts** (stubs remain in `ImageGenActionButtons`)
6. **Top-level Move/Copy menu** (optional; destinations folded under File → Move to)

## Build variants

- [~] Full build (all AI features)
- [~] `--min` build (browser + search only, no imagegen/LM Studio/voice UI)

## Information pane (exact Python layout)

Source: `thumbnails/information_sidebar.py`, `information_action_nav.py`.

- [~] Collapsible sections with `information_section_expanded` persistence (9 keys)
- [~] Monospace two-column table layout (Courier 12pt, 18×15px margins)
- [~] Bordered EXIF grid vs borderless basic fields
- [~] Seed `copyseed://` links (copy to clipboard, hover styling)
- [~] Reference `reflevel://` links → reference graph sheet
- [~] Image Model param table (Seed, Steps, LoRA, Elapsed, etc.)
- [~] User comment h4 sections (Prompt, Title, References, Negative prompt)
- [~] "Add user comment" empty placeholder
- [~] Active job Input/Output headings with accent border
- [~] Action bar: edit → copy → speak → create → editai → delete
- [~] Option+click copy full comment; speak highlight while TTS active
- [~] Live refresh on `fileMetadataChanged` and theme change
- [~] Python-format field strings (dates, GPS 3dp, file size, MP line)

## Menu parity matrix (Python `menu_manager.py` ↔ Swift `ProwserCommands.swift`)

| Python menu | Swift status | Notes |
|---|---|---|
| File: Open, Recent, Favorites, Back/Forward | done | Dynamic favorite/destination labels via `MenuStateHelpers` |
| File: Settings, Last Image, Delete, Trash view | done | View Copy of Trash when readable trash has images |
| Edit: copy path/image, lock, rename prefix, convert, resize | done | Resize: CG vs Pillow filters (functional, not bit-identical) |
| View: pane toggles, sort (checkmarks), theme, chrome | done | Hide/Show dynamic labels |
| Search: similar, CLIP, person, duplicates, show in dir | done | Quick Person Search (⌃⌘P) |
| Move/Copy top-level menu | partial | Folded into File → Move to |
| Image: create/edit/expand/infill, job queue | partial | Fast-open ⇧⌥/; Check LoRAs + Downloading Models help added |
| Tools: EXIF, slideshows, wallpaper, screen copy, org | done | Mass rename gated by setting |
| Tools: Debug | partial | Check LoRAs headless runner; full Qt probe UI stays Python |
| Help: shortcuts, about, docs | partial | About complete; PF Keys / Hidden Gems placeholders |

## Intentional Swift differences (documented)

- Resize appears in thumbnail **context menu** (Swift-only; Python Edit menu only).
- Resize resampling uses Core Graphics interpolation (Python: Pillow); filter names match, output may differ slightly.
- Image-gen submit still delegates final dim alignment to Python `buildPayload`; Swift UI now mirrors live limit math.

## Remaining gate items (manual sign-off)

- Side-by-side screenshot compare: information pane collapsed/expanded, seed link, Image Model table
- Profile round-trip: open settings.json in Python after Swift session
- `--min` build hides imagegen/chat/faces UI end-to-end
- Remove PySide6 `ImageBrowserWindow` launch (keep `prowser.py` workers only)
- Chat named system prompt library; imagegen favorite prompts (acceptable Python-bridge deferrals)
