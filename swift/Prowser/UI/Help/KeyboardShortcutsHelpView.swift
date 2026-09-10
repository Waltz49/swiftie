import SwiftUI

struct KeyboardShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    shortcutSection("Navigation", rows: [
                        ("← → ↑ ↓", "Move selection (thumbnail grid respects columns)"),
                        ("⇧← → ↑ ↓", "Range select"),
                        ("H / E", "First / last image"),
                        ("Return / Space", "Open browse view"),
                        ("Esc", "Clear selection or go back in history"),
                        ("⇧Esc", "Forward in directory history"),
                    ])
                    shortcutSection("Views", rows: [
                        ("⌘1 / ⌘2 / ⌘3", "Thumbnails / List / Browse"),
                        ("S", "Start slideshow"),
                        ("Esc", "Exit slideshow"),
                        ("Q", "Exit list view → thumbnails"),
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
                        ("⇧← →", "Rotate image"),
                        ("⇧↑ ↓", "Flip vertical / horizontal"),
                        ("⇧R", "Reset transforms"),
                        ("A", "Toggle actual size"),
                        ("+ / −", "Zoom in / out"),
                        ("Space", "Next image"),
                        ("Esc / Return / Q / F", "Return to thumbnails"),
                    ])
                    shortcutSection("Thumbnail grid", rows: [
                        ("+ / − / 0", "Larger / smaller / reset cell size"),
                        ("⌘← → ↑ ↓", "Multi-select toggle"),
                    ])
                    shortcutSection("File & Search", rows: [
                        ("⌘O", "Open folder"),
                        ("⌘R", "Refresh"),
                        ("⇧⌘R", "Reveal in Finder"),
                        ("⌘Delete", "Move to Trash"),
                        ("⌘Z", "Undo delete (restore from Trash)"),
                        ("⇧F", "Find duplicate files (recursive)"),
                        ("⌘1–⌘9", "Move to destination"),
                        ("⌘0", "Move to last drop location"),
                        ("⌥⌘1–⌥⌘9", "Copy to destination"),
                        ("^1–^9", "Open favorite directory"),
                    ])
                    shortcutSection("Help", rows: [
                        ("/ or F1", "This dialog"),
                    ])
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Prowser").font(.title)
            Text("Native macOS image browser (Swift port)")
                .foregroundStyle(.secondary)
            Text("Version 0.1 (Swift migration)")
                .font(.caption)
            Spacer()
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 320, height: 200)
    }
}
