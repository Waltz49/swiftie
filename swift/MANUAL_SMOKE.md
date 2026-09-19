# Manual smoke checklist (Swift maintainability / event bus)

Run after `swift build` and launching the app.

- With preview hidden: single-click a thumbnail opens browse; with preview visible: double-click opens browse, single-click only selects.
- Change filename filter from the status bar and from the menu; file tree and thumbnails stay in sync.
- Enter Browse mode and exit five times; keyboard zoom and pan still work.
- Select an image in the thumbnail grid; file tree highlights the folder; status bar updates.
- Change a settings option that affects thumbnails (e.g. show filenames); grid refreshes without a visible refresh loop.
- **Find duplicates:** With **file tree focused** on a folder (click the tree so the titlebar highlights), press **⇧F**; recursive scan starts from that folder. With focus on the thumbnail grid, **⇧F** must do nothing. **Search → Find Duplicate Image Files (Recursive)** still works via the menu (uses current directory). On a folder with known byte-identical files in different subfolders, confirm thumbnail view shows hash-group separators, path-style filename overlays when filenames are on, and preselection (lexicographically smallest path in each hash group kept unselected; other copies multiselected, including one copy per subfolder). Cancel the hashing progress dialog mid-run; list should not change.
- After duplicate view, navigate to another directory; section layout clears and normal grid returns.
- **Background extracts:** With no Core ML search models installed, clicking the status bar file-count section must not offer a background toggle; Settings → Caches must not show idle collection toggles. After installing CLIP+ResNet (⌘K/⌘F or Settings → Models), enable idle collection from status bar or Caches; after ~5s idle, file count shows `●` while indexing and `○` when enabled but paused; typing resumes pause; ⌘K/⌘F pauses background until search finishes.
