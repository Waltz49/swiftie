# Keyboard Shortcuts

This document lists keyboard shortcuts available in the Swift **Prowser** app. On macOS, **Cmd** refers to the Command key (⌘). In the Python/Qt app, `Ctrl+` in `QKeySequence` strings maps to ⌘ on macOS; this file uses macOS conventions throughout.

Physical **Control** (⌃) appears in shortcuts as `Meta+` in Qt source code (for example ⌃1–9 for favorites, ⌃W to fit image width).

Press **F1** or **/** in the app for context-sensitive help. Menu items also show their shortcuts.

## Table of Contents

- [Thumbnail View](#thumbnail-view)
- [List View](#list-view)
- [Browse View (Fullscreen)](#browse-view-fullscreen)
- [Slideshow Mode](#slideshow-mode)
- [Slideshow2 Mode (Panning Image)](#slideshow2-mode-panning-image)
- [Slideshow3 Mode (Floating Frames)](#slideshow3-mode-floating-frames)
- [Global Menu Shortcuts](#global-menu-shortcuts)
- [Notes](#notes)

## Thumbnail View

### Navigation
| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Navigate thumbnails |
| H / Home | Go to first image |
| E / End | Go to last image |
| Page Up/Down | Page up/down through thumbnails |
| Shift+← → ↑ ↓ | Range selection |
| Cmd+← → ↑ ↓ | Add to multi-selection |
| Shift+H / Shift+Home | Select to first image |
| Shift+E / Shift+End | Select to last image |
| Cmd+[ / Cmd+] | Directory history back / forward (menu) |

### Actions
| Key | Action |
|-----|--------|
| Enter/Space | Open in browse view (image viewer) |
| F | Enter browse view (menu) |
| Esc | Clear selection, or navigate backward in directory history |
| Shift+Esc | Navigate forward in directory history |
| F10 | Clear forward and backward history stacks |
| Click | Select image |
| Cmd+Click | Add to multi-selection |
| Shift+Click | Range selection |

### Sorting
| Key | Action |
|-----|--------|
| R | Toggle random order |
| D | Sort by date (newest first) |
| Shift+D | Sort by date (oldest first) |
| N | Sort by name (A–Z) |
| Shift+N | Sort by name (Z–A) |
| Z | Sort by size (largest first) |
| Shift+Z | Sort by size (smallest first) |
| X | Sort by EXIF month (newest first) |
| Shift+X | Sort by EXIF month (oldest first) |
| Y | Sort by EXIF year (newest first) |
| Shift+Y | Sort by EXIF year (oldest first) |
| C | Custom sort |
| Cmd+T | Reverse sort order |

### Thumbnail Size
| Key | Action |
|-----|--------|
| +/- | Resize thumbnails |
| 0 | Reset thumbnail size to dynamic default |

### File Operations
| Key | Action |
|-----|--------|
| Cmd+C | Copy image path to clipboard |
| ⌃C | Copy image pixels to clipboard |
| ⌘E | Edit in external editor |
| Cmd+Backspace / Cmd+Delete | Delete selected files (move to Trash) |
| Cmd+Z | Undo file deletion |
| Cmd+N | Rename with custom prefix |
| Cmd+M | Convert selected images |
| Cmd+Shift+Z | Resize images |
| Cmd+L | Lock files (when locking enabled) |
| Cmd+Shift+L | Unlock files |
| F2 | Rename selected file (inline editor on filename overlay); in file tree, rename selected folder |

### View Options
| Key | Action |
|-----|--------|
| B | Toggle status bar |
| I | Toggle information sidebar |
| I (double-tap) | Hide organize sidebar and jobs pane when the first **I** showed information (ignored if the first **I** hid it) |
| O | Toggle shortcuts sidebar (favorites / move lists) |
| Cmd+I | Cycle thumbnail overlay (none → name → size → both) |
| Cmd+Shift+I | Toggle number overlay |
| T | Toggle file tree |
| P | Toggle preview widget |
| ⌥T | Show file tree only (hide other left sidebar panes) |
| ⌥P | Show preview only (hide other left sidebar panes) |
| ⌥O | Show organize sidebar only (hide other right panes) |
| ⌥I | Show information pane only (hide other right panes) |
| , | Toggle chat pane (when chat UI is enabled) |
| F4, ., ⌃. | Toggle chrome (menu bar, etc.) |
| F12 | Toggle list view |
| Cmd+Return | Collapse file tree |
| Cmd+Shift+Return | Expand file tree |

When the **file tree** has keyboard focus, **⌘F** (Find Images / CLIP), **⌘P** (Search for Known Person), and **⌘C** (copy path) use the selected row (folder scope, or parent folder if a file row is selected). **F2** renames the selected directory inline. Those shortcuts are handled in the tree before the global Search menu.

### Desktop & Maps
| Key | Action |
|-----|--------|
| Cmd+Shift+W | Set as desktop background |
| Cmd+G | Open GPS location in maps |

### Slideshow
| Key | Action |
|-----|--------|
| S | Start slideshow |
| Shift+S | Start slideshow 2 (panning) |
| Shift+⌃+S | Start slideshow 3 (floating frames) |

### Help & Settings
| Key | Action |
|-----|--------|
| F1 or / or ? | Show help |
| Cmd+, | Open settings dialog |
| Cmd+O | Open directory |
| Cmd+Shift+O | Open file |
| Cmd+R | Refresh directory |
| Cmd+Shift+R | Reveal in Finder |
| Cmd+Shift+T | View copy of Trash (if available) |
| F3 | Image history |

### Quick File Move
| Key | Action |
|-----|--------|
| Cmd+0 | Move selected files to last drop location |
| Cmd+1–9 | Move selected files to destination 1–9 |
| Option+Cmd+0 | Copy to last drop location |
| Option+Cmd+1–9 | Copy to destinations 1–9 |

### Favorites
| Key | Action |
|-----|--------|
| ⌃1–9 | Open favorite directory or file |

### Other
| Key | Action |
|-----|--------|
| Cmd+A | Select all images |
| Cmd+Q | Quit application |
| Cmd+Shift+D | Toggle debug mode |
| Cmd+D | Debug cache status |
| Cmd+Shift+C | Cache subdirectories' thumbnails |
| Cmd+Shift+H | Show image in directory |
| Shift+F | Find duplicate images (recursive) |
| ⌃L | View log (Tools → Debug) |
| F5 | Show reference graph for active image |

Search menu: **Cmd+P** Search for Known Person, **Ctrl+Cmd+P** Search for Person in Current Image, duplicate detection (**Shift+Cmd+F** recursive), **Shift+Cmd+H** show image in directory.

## List View

Toggle with **F12** from thumbnail view. In list view, **+** / **=** and **-** adjust row height; **0** resets row height to the default; **Q** returns to thumbnail view. Most thumbnail shortcuts (navigation, sorting, file ops) also apply in list view.

## Browse View (Fullscreen)

### Navigation
| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Previous/next image |
| H / E / Home / End | First/last image |
| Cmd+← → ↑ ↓ | Pan image when zoomed |

### Image Transformations
| Key | Action |
|-----|--------|
| Shift+← | Rotate counterclockwise |
| Shift+→ | Rotate clockwise |
| Shift+↑ | Flip vertical |
| Shift+↓ | Flip horizontal |
| Shift+R | Reset image transformations |

### Zoom & Pan
| Key | Action |
|-----|--------|
| +/- or = | Zoom in/out |
| A | Actual size (1:1 pixels) |
| F6 | Toggle sharpen when zoomed in |
| ⌃W | Fit image to canvas width |
| Mouse wheel | Zoom in/out |
| Right-click | Return to thumbnails |

### Actions
| Key | Action |
|-----|--------|
| Space | Next image / return to thumbnails (configurable) |
| Shift+Space | Toggle space bar behavior |
| Enter/Return/Esc/Q/F | Return to thumbnails |
| T / P (double-tap) | Return to thumbnails and show file tree / preview |
| I (double-tap) | Hide organize and jobs when first **I** showed information (same interval as T/P) |
| F10 | Clear history stacks |
| ⌃⌘F | macOS Space vs windowed display |

### File Operations
| Key | Action |
|-----|--------|
| Cmd+C | Copy image path |
| ⌃C | Copy image pixels |
| ⌘E | Edit in external editor |
| Cmd+Backspace / Cmd+Delete | Delete current file |
| Cmd+Z | Undo deletion |
| Cmd+L | Lock files (when locking enabled) |
| Cmd+Shift+L | Unlock files |
| Cmd+; | Last image (swap history) |

### View Options
| Key | Action |
|-----|--------|
| I | Toggle information sidebar |
| O | Toggle shortcuts sidebar |
| ⌥T / ⌥P | Show file tree or preview only (left sidebar) |
| ⌥O / ⌥I | Show organize or information pane only (right) |
| B | Toggle status bar |
| Cmd+I | Cycle filename/number overlay |
| Cmd+Shift+I | Toggle number overlay |
| F3 | Image history |
| F5 | Find references to current image |
| F4, ., ⌃. | Toggle chrome |
| Cmd+Return / Cmd+Shift+Return | Collapse/expand file tree |

### Desktop & Maps
| Key | Action |
|-----|--------|
| Cmd+Shift+W | Set as desktop background (letterboxed) |
| Cmd+G | Open GPS location in maps |

### Sorting & Search
| Key | Action |
|-----|--------|
| R, D, N, Z, C, Cmd+T | Same as thumbnail view |

### Slideshow
| Key | Action |
|-----|--------|
| S | Start slideshow |
| Shift+S | Start slideshow 2 |
| Shift+⌃+S | Start slideshow 3 |

## Slideshow Mode

### Navigation
| Key | Action |
|-----|--------|
| N | Next slide immediately |
| ← → ↑ ↓ | Set slide direction (or advance if already set) |

### Speed Controls
| Key | Action |
|-----|--------|
| 1 / 2 | Slow down / speed up slideshow |
| 0 / 9 | Apply named presets (configurable in Settings → Slideshow) |

### Transition Controls
| Key | Action |
|-----|--------|
| 3 / 4 | Slow down / speed up transitions |
| 5 / 6 | Decrease / increase max rotation |
| 7 / 8 | Decrease / increase overlap |

### Direction & Effects
| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Set slide direction |
| Shift+R | Random transitions |
| C | No transitions |

### Actions
| Key | Action |
|-----|--------|
| Space/Enter/F | Pause and enter browse mode |
| Esc | Exit slideshow |

## Slideshow2 Mode (Panning Image)

### Navigation
| Key | Action |
|-----|--------|
| Shift+← → ↑ ↓ | Previous/next image |

### Speed Controls
| Key | Action |
|-----|--------|
| 1 / Shift+1 | Slow down (normal / large step) |
| 2 / Shift+2 | Speed up (normal / large step) |

### Zoom Controls
| Key | Action |
|-----|--------|
| +/- or = | Zoom in |
| - or _ | Zoom out |
| Q | Toggle high-quality scaling |
| ⌃W | Fit image to canvas width |

### Actions
| Key | Action |
|-----|--------|
| Space/Enter | Enter browse mode |
| Esc | Exit slideshow2 |

## Slideshow3 Mode (Floating Frames)

Start with **Shift+⌃+S** (Tools → Slideshows → Floating Frames).

| Key | Action |
|-----|--------|
| Esc / Space / Return | Exit to thumbnails |
| 1 / 2 | Slower / faster movement |
| F1, /, ? | Show help |
| Cmd+Return | Collapse file tree |

Additional floating-frame tuning keys from the Python app (3–6, 9, 0) are not wired in the Swift port yet.

## Global Menu Shortcuts

These work from most views via the menu bar:

- **Cmd+Shift+M** — Quick mass rename (when enabled)
- **Cmd+Shift+E** — Edit EXIF user comment
- **⌃H** — Open home directory
- **Cmd+Shift+W** — Wallpaper → resize window (last used scaling)

Screen-size copy actions are in **Tools → Create Screen Size Copy…** (no default keyboard shortcut).

## Notes

- **Cmd** in this document is ⌘ (Command). Qt `Ctrl+` shortcuts in the Python app map to ⌘ on macOS.
- **⌃** is the physical Control key (`Meta+` in Qt).
- Some shortcuts are context-sensitive (view mode, settings, or feature flags).
- **Cmd+L** locks files (when locking is enabled). **Cmd+;** is Last Image in browse view.
- **⌘E** opens the external editor; **E** alone jumps to the last image in browse view.
- The in-app help dialog (F1) is built from runtime bindings and may differ slightly from this file.
