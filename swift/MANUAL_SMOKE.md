# Manual smoke checklist (Swift maintainability / event bus)

Run after `swift build` and launching the app.

- With preview hidden: single-click a thumbnail opens browse; with preview visible: double-click opens browse, single-click only selects.
- Change filename filter from the status bar and from the menu; file tree and thumbnails stay in sync.
- Enter Browse mode and exit five times; keyboard zoom and pan still work.
- Select an image in the thumbnail grid; file tree highlights the folder; status bar updates.
- Change a settings option that affects thumbnails (e.g. show filenames); grid refreshes without a visible refresh loop.
