import SwiftUI

struct KeyboardShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
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
                        ("Z / ⇧Z", "Sort by size (largest / smallest)"),
                        ("R", "Random sort"),
                        ("C", "Custom sort (.prsort)"),
                    ])
                    shortcutSection("Sidebars", rows: [
                        ("I", "Toggle information pane"),
                        ("O", "Toggle shortcuts sidebar"),
                        ("T", "Toggle file tree"),
                        ("J", "Toggle jobs pane"),
                        ("⌘J", "Toggle floating job queue panel"),
                        ("⌃J", "Cycle jobs pane/panel size (strip → one → all)"),
                        ("⌥[ / ⌥] / ⌥\\", "Jobs size: strip / one job / all jobs"),
                        ("B", "Toggle status bar"),
                        ("F9 / ,", "Toggle chat pane"),
                        ("Double-click titlebar", "Expand pane to fit content (jobs: cycle size)"),
                        ("Drag titlebar", "Resize pane (preview, chat, info, jobs)"),
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
                        ("⌘← → ↑ ↓", "Pan when zoomed"),
                        ("^W", "Fit image width to canvas"),
                        ("T / P (double-tap)", "Exit browse, show file tree / preview"),
                        ("Space", "Next image (or exit when space mode is exit)"),
                        ("⇧Space", "Toggle space key mode (exit vs advance)"),
                        ("Esc / Return / Q / F", "Return to thumbnails"),
                        ("F5", "Show reference graph for active image"),
                    ])
                    shortcutSection("Thumbnail grid", rows: [
                        ("+ / − / 0", "Larger / smaller / reset cell size (list: row height)"),
                        ("⌘← → ↑ ↓", "Multi-select toggle"),
                        ("⌘Return / ⌘⇧Return", "Collapse / expand file tree"),
                        ("F2", "Rename selected file"),
                    ])
                    shortcutSection("File & Search", rows: [
                        ("⌘O", "Open directory"),
                        ("⌘⇧O", "Open file"),
                        ("⌘R", "Refresh"),
                        ("⇧⌘R", "Reveal in Finder"),
                        ("⌘Delete", "Move to Trash"),
                        ("⌘C", "Copy path"),
                        ("^C", "Copy image"),
                        ("⌘K", "Find similar images"),
                        ("⌘⇧H", "Show image in directory"),
                        ("⌘Z", "Undo delete (restore from Trash)"),
                        ("⇧F", "Find duplicate files (recursive)"),
                        ("⌘1–⌘9", "Move to destination"),
                        ("⌘0", "Move to last drop location"),
                        ("⌥⌘1–⌥⌘9", "Copy to destination"),
                        ("^1–^9", "Open favorite directory"),
                    ])
                    shortcutSection("Tools", rows: [
                        ("⌘G", "Show GPS location on map"),
                        ("⇧⌘E", "Edit EXIF user comment"),
                    ])
                    if BundleCapabilities.imageGenUIEnabled {
                        shortcutSection("Image Generation", rows: [
                            ("⌥/", "Open last-used image function dialog"),
                            ("⇧⌥/", "Open image-gen dialog from current image EXIF"),
                            ("⌘J", "Toggle floating job queue panel"),
                        ])
                    }
                    shortcutSection("Help", rows: [
                        ("/ or F1", "This dialog"),
                    ])
                }
            }

            DialogButtonRow([
                DialogButton("Close", isDefault: true, isCancel: true) { dismiss() },
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

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors

    var body: some View {
        VStack(spacing: 16) {
            Text("Prowser").font(.title)
            Text("Native macOS image browser (Swift port)")
                .foregroundStyle(colors.dialogMutedText)
            Text("Version 0.1 (Swift migration)")
                .font(.caption)
                .foregroundStyle(colors.dialogMutedText)
            Spacer()
            DialogButtonRow([
                DialogButton("OK", isDefault: true, isCancel: true) { dismiss() },
            ], focusDefaultOnAppear: true)
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 200)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.about,
            defaultWidth: 320,
            defaultHeight: 200,
            minWidth: 280,
            minHeight: 180
        )
    }
}
