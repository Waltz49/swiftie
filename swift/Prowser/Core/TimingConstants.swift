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
    static let thumbnailBackgroundLoadInitialDelayMs = 150
    /// Pause between background thumbnail batches (Python `MAX_BACKGROUND_BATCH` follow-up).
    static let thumbnailBackgroundLoadBatchDelayMs = 250
    /// Max paths submitted per background batch (Swift caps async fan-out; Python queues to a worker heap).
    static let thumbnailBackgroundLoadBatchSize = 8
    /// Stagger within a batch so scroll/reprioritize can cancel before the whole batch is queued.
    static let thumbnailBackgroundLoadChunkDelayMs = 40
    /// Qt default `SH_ToolTip_WakeUpDelay` used by `IconGraphicTooltipFilter`.
    static let graphicButtonTooltipDelayMs = 700
    /// Idle before background CLIP/CNN indexing (`BACKGROUND_CLIP_IDLE_TIMEOUT_SECONDS` is 5 in Python).
    /// Temporarily 10s for easier idle-background testing.
    static let backgroundClipIdleSeconds: TimeInterval = 5
    /// Max images per idle batch shortly after the user stops interacting.
    static let backgroundClipBatchSize = 54
    /// After this much continuous idle, use `backgroundClipExtendedIdleBatchSize` instead.
    static let backgroundClipExtendedIdleSeconds: TimeInterval = 30
    /// Larger idle batch when the user has been inactive for `backgroundClipExtendedIdleSeconds`.
    static let backgroundClipExtendedIdleBatchSize = 150
    /// Idle gather scans each listed folder plus immediate subfolders (e.g. `/Volumes/MiscFS` → `bg/`).
    static let backgroundIdleScanSubfolderDepth = 1
}
