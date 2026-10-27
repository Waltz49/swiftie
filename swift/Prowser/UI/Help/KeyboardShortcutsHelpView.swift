import SwiftUI

struct KeyboardShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(\.themeColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    shortcutSection("Navigation", rows: [
                        ("← → ↑ ↓", "Move selection (thumbnail grid respects columns)"),
                        ("⇧← → ↑ ↓", "Range select"),
                        ("Home / End", "First / last image"),
                        ("⇧Home / ⇧End", "Range select to first / last"),
                        ("H / E", "First / last image"),
                        ("Return / Space", "Open browse view"),
                        ("Esc", "Clear selection or go back in history"),
                        ("⇧Esc", "Forward in directory history"),
                        ("F3", "Browse image history"),
                        ("F10", "Clear directory history stacks"),
                    ])
                    shortcutSection("Views", rows: [
                        ("F", "Enter browse view"),
                        ("F12", "Toggle list view"),
                        ("S", "Start slideshow"),
                        ("Esc", "Exit slideshow"),
                        ("Q", "Exit list view → thumbnails"),
                    ])
                    shortcutSection("Slideshow (mode 1)", rows: [
                        ("1 / 2", "Slower / faster slide rate"),
                        ("3 / 4", "Slower / faster transitions"),
                        ("5 / 6", "Less / more max rotation"),
                        ("7 / 8", "Less / more overlap"),
                        ("0 / 9", "Apply slow / fast preset"),
                        ("N", "Advance slide"),
                        ("Arrows", "Set direction (tap again to advance)"),
                        ("⇧R", "Random direction"),
                        ("C", "No transition"),
                    ])
                    shortcutSection("Sort", rows: [
                        ("N / ⇧N", "Sort by name (A-Z / Z-A)"),
                        ("D / ⇧D", "Sort by date (newest / oldest)"),
                        ("X / ⇧X", "Sort by EXIF month (newest / oldest)"),
                        ("Y / ⇧Y", "Sort by EXIF year (newest / oldest)"),
                        ("Z / ⇧Z", "Sort by size (largest / smallest)"),
                        ("R", "Random sort"),
                        ("C", "Custom sort (.prsort)"),
                    ])
                    shortcutSection("Sidebars", rows: [
                        ("I", "Toggle information pane"),
                        ("I (double-tap)", "Hide organize and jobs (only if first I showed information)"),
                        ("O", "Toggle shortcuts sidebar"),
                        ("T", "Toggle file tree"),
                        ("⌥T / ⌥P", "Show file tree or preview only (left)"),
                        ("⌥O / ⌥I", "Show organize or information pane only (right)"),
                        ("B", "Toggle status bar"),
                        ("Double-click titlebar", "Expand pane to fit content"),
                        ("Drag titlebar", "Resize pane (preview, info)"),
                        ("⌘I", "Cycle thumbnail overlay (none → name → size → both)"),
                        ("⌘⇧I", "Toggle number overlay (browse)"),
                    ])
                    shortcutSection("Browse", rows: [
                        ("← →", "Previous / next image"),
                        ("Home / End", "First / last image"),
                        ("⇧← →", "Rotate image"),
                        ("⇧↑ ↓", "Flip vertical / horizontal"),
                        ("⇧R", "Reset transforms"),
                        ("A", "Toggle actual size"),
                        ("+ / −", "Zoom in / out"),
                        ("⌥− / ⌥=", "Fit to viewport width / height"),
                        ("F6", "Toggle sharpen when zoomed in"),
                        ("⌘← → ↑ ↓", "Pan when zoomed"),
                        ("^W", "Fit image width to canvas"),
                        ("T / P (double-tap)", "Exit browse, show file tree / preview"),
                        ("Space", "Next image (or exit when space mode is exit)"),
                        ("⇧Space", "Toggle space key mode (exit vs advance)"),
                        ("Esc / Return / Q / F", "Return to thumbnails"),
                        ("Right-click", "Return to thumbnails"),
                        ("F5", "Find references to current image"),
                    ])
                    shortcutSection("Search", rows: [
                        ("⌘K", "Find similar images (CNN)"),
                        ("⌘F / ⌘⇧K", "Search by text (CLIP)"),
                        ("⌘P", "Search for Known Person"),
                        ("⌃⌘P", "Search for Person in Current Image"),
                        ("⇧⌘P", "Identify Faces in Current Image"),
                    ])
                    shortcutSection("Thumbnail grid", rows: [
                        ("+ / − / 0", "Larger / smaller / reset cell size (list: row height)"),
                        ("⌘← → ↑ ↓", "Multi-select toggle"),
                        ("⌘Return / ⌘⇧Return", "Collapse / expand file tree"),
                        ("F2", "Rename selected file"),
                    ])
                    shortcutSection("File tree (when tree has focus)", rows: [
                        ("F2", "Rename highlighted directory"),
                        ("⌘F", "Search by text (CLIP) in selected folder"),
                        ("⌘P", "Search for Known Person in selected folder"),
                        ("⌘C", "Copy path of selected row"),
                        ("⇧A", "Show all images including subdirectories"),
                        ("⇧⌘C", "Cache thumbnails for the highlighted folder and subdirectories"),
                        ("⇧F", "Find duplicate image files (recursive from highlighted folder)"),
                        ("Return / Space", "Open folder or expand/collapse"),
                        ("Tab", "Move focus to thumbnail grid"),
                    ])
                    shortcutSection("File & Search", rows: [
                        ("⌘O", "Open directory"),
                        ("⌘⇧O", "Open file"),
                        ("⌘R", "Refresh"),
                        ("⇧⌘R", "Reveal in Finder"),
                        ("⌘Delete", "Move File to Trash"),
                        ("⌘C", "Copy path"),
                        ("^C", "Copy image"),
                        ("⌘⇧H", "Show image in directory"),
                        ("⌘Z", "Undo delete (restore from Trash)"),
                        ("⌘⇧Z", "Resize images"),
                        ("Search menu", "Find duplicate files (recursive) — no keyboard shortcut"),
                        ("⌘1–⌘9", "Move to destination"),
                        ("⌘0", "Move to last drop location"),
                        ("⌥⌘1–⌥⌘9", "Copy to destination"),
                        ("^1–^9", "Open favorite directory"),
                    ])
                    shortcutSection("Tools", rows: [
                        ("⌘E", "Edit in external editor"),
                        ("⌘G", "Show GPS location on map"),
                        ("⇧⌘E", "Edit EXIF user comment"),
                        ("⇧⌘C", "Cache thumbnails (tree folder if focused, else active image directory)"),
                    ])
                }
            }

            DialogButtonRow([
                DialogButton("Close", isDefault: true, isCancel: true) { closeDialog(); dismiss() },
            ], focusDefaultOnAppear: true)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.keyboardHelp,
            defaultWidth: 520,
            defaultHeight: 520,
            minWidth: 480,
            minHeight: 400
        )
    }

    private func shortcutSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { key, action in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130, alignment: .leading)
                    Text(action)
                        .foregroundStyle(colors.dialogMutedText)
                }
            }
        }
    }
}

