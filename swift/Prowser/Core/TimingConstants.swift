import Foundation

/// Debounce and delay values aligned with the Python app (`thumbnails/thumbnail_constants.py` and call sites).
enum TimingConstants {
    /// Coalesce rapid current-image changes before reloading EXIF in the File Information pane.
    /// Port of `information_sidebar.py` `_schedule_metadata_overlay_refresh()` (260 ms).
    static let metadataOverlayRefreshDebounceMs = 1
    /// Port of `image_browser_window.py` `on_scroll_changed` debounce (100 ms).
    static let thumbnailScrollLoadDebounceMs = 100
}
