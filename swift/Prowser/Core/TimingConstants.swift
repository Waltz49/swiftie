import Foundation

/// Debounce and delay values aligned with the Python app (`thumbnails/thumbnail_constants.py` and call sites).
enum TimingConstants {
    /// Coalesce rapid current-image changes before reloading EXIF in the File Information pane.
    /// Port of `information_sidebar.py` `_schedule_metadata_overlay_refresh()` (260 ms).
    static let metadataOverlayRefreshDebounceMs = 1
    /// Port of `image_browser_window.py` `on_scroll_changed` debounce (100 ms).
    static let thumbnailScrollLoadDebounceMs = 100
    /// Retry when viewport layout is not ready (`_restart_canvas_thumbnail_loading_for_visible`).
    static let thumbnailVisibleLoadRetryMs = 50
    /// Delay before first background thumbnail batch (`_restart_canvas_thumbnail_loading_for_visible`).
    static let thumbnailBackgroundLoadInitialDelayMs = 100
    /// Pause between background thumbnail batches (Python `MAX_BACKGROUND_BATCH` follow-up).
    static let thumbnailBackgroundLoadBatchDelayMs = 500
    /// Max thumbnails queued per background batch (Python `MAX_BACKGROUND_BATCH`).
    static let thumbnailBackgroundLoadBatchSize = 200
    /// Qt default `SH_ToolTip_WakeUpDelay` used by `IconGraphicTooltipFilter`.
    static let graphicButtonTooltipDelayMs = 700
}
