// Hidden Gems Help — modifier + click (and related modifier + drag) actions.
//
// MAINTAINER: When you add or change behavior that uses Option, Control, Command, or
// Shift together with a mouse click, drag, or letter key, update `markdown()` below
// and keep the in-app tooltips in sync where they exist. Also update KEYBOARD.md
// and drag-and-drop drop targets / drag sources when those change.

enum HiddenGemsHelpContent {
    // MAINTAINER: Add new modifier+click / modifier+drag rows here when implementing them.
    static func markdown() -> String {
        let opt = "⌥"
        let cmd = "⌘"
        let ctrl = "⌃"
        let shift = "⇧"
        return """
        #
        # Hidden Gems: Modifier + Click

        Many useful actions are not in the menus. Some are hinted in tooltips only; this page collects them.

        This page is really just a development aid to guide future design and possibly document some design shortcomings.

        #

        ## macOS key names

        AppKit reports keyboard modifiers in `NSEvent.ModifierFlags`:

        | Label | Key | AppKit note |
        |-------|-----|-------------|
        | **\(cmd)** Command | ⌘ | `.command` |
        | **\(ctrl)** Control | ⌃ | `.control` |
        | **\(opt)** Option | ⌥ | `.option` |
        | **\(shift)** Shift | ⇧ | `.shift` |

        Throughout Prowser, **\(cmd)+click** means Command, **\(ctrl)+click** means Control (not Command).

        #

        ## Thumbnails and list view

        | Modifier + click | Where | Action |
        |------------------|-------|--------|
        | **\(cmd)+click** | Thumbnail grid or list | Add or toggle the clicked image in the selection (multiselect). |
        | **\(shift)+click** | Thumbnail grid or list | Extend selection from the anchor to the clicked image (range select). |
        | **\(ctrl)+click** or **right-click** | Thumbnail grid or list | Open the thumbnail context menu. **\(cmd)+click** does *not* open the menu — it is reserved for multiselect. |
        | plain click | Thumbnail grid or list | Select and open browse mode (when preview is hidden). |
        | plain click | Filename or size pill on thumbnail | Inline rename (when that overlay is shown). |

        #

        ## Drag and drop (where supported)

        ### Drop targets (receive files)

        | Where | Action |
        |-------|--------|
        | **Folder tree** | Move or copy image files onto a folder (highlight shows the target folder). |
        | **Thumbnail grid** | Reorder thumbnails within the current folder (insertion indicator shows drop position). |

        ### Drag sources (drag files out)

        | Where | Action |
        |-------|--------|
        | **Thumbnail grid** | Drag selected image(s) to Finder, another folder, or another app. Multiselect drags all selected files. |

        ### Modifier keys while dragging

        | Modifier | Where | Action |
        |----------|-------|--------|
        | **\(opt)** (hold while dragging) | Thumbnail grid | Force **copy** when dragging files to another folder or app. Default is move (macOS still copies across volumes). |
        | **\(opt)** (at drop) | Folder tree | Copy instead of move. Also copies **locked** files when move is blocked. |

        #

        ## Information sidebar (EXIF / description links)

        These links and controls appear in the information pane when a user comment is present.

        | Modifier + click | Link / control | Action |
        |------------------|----------------|--------|
        | click | **References** level link | Show the full reference graph (complete history). |
        | **\(opt)+click** | **References** level link | Show only this image and its **direct** references. |
        | **F5** | Thumbnail or browse view | Show reference graph for the **active** image (same EXIF reference data; shows a dialog if none is found). |
        | click | **Copy** toolbar button or context menu | Copy the prompt text (truncated before generation metadata). |
        | **\(opt)+click** | **Copy** toolbar button or context menu | Copy the **full** raw user comment. |
        | click | Section header (▶ / ▼) | Expand or collapse that section. |
        | **\(opt)+click** | Section header (▶ / ▼) | Expand or collapse **all** sections at once. |

        #

        ## Edit EXIF user comment dialog

        | Modifier + click | Control | Action |
        |------------------|---------|--------|
        | click | Copy button | Copy processed comment text (prompt portion, semicolons normalized). |
        | **\(opt)+click** | Copy button | Copy **raw** text from the editor without processing. |

        #

        ## Sidebar panes (Option + pane letter)

        **T**, **P**, **O**, and **I** toggle each pane on or off. With **\(opt)** held, the same letters show **only** that pane in its combined sidebar and hide sibling panes on that side (left: tree / preview; right: Organize / Information). Restores sidebars after **F4** hide-all-chrome. **⌥T** and **⌥P** are thumbnail and list view only; **⌥O** and **⌥I** follow the same availability as **O** and **I**.

        Related (keyboard, not click):

        | Modifier + key | Action |
        |----------------|--------|
        | **\(opt)\(cmd)+1 … \(opt)\(cmd)+9** | Copy selection to move destination slot |
        | **\(opt)\(cmd)+0** | Copy to last folder-tree drop location |
        | **\(opt)− / \(opt)=** | In browse view, fit image to viewport width / height |

        #

        ## Not finding something?

        Press **/** for the full keyboard-shortcut list. This page covers modifier + click actions, drag-and-drop locations, and a few related shortcuts. Chat, image generation, and settings-only modifier actions from the PySide6 app are not in this Swift build.
        """
    }
}
