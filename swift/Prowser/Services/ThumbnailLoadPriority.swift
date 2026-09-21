import Foundation

/// Matches Python canvas thumbnail priorities (`image_browser_window.py` `_restart_canvas_thumbnail_loading_for_visible`).
enum ThumbnailLoadPriority: Int, Sendable {
    case background = 0
    case `default` = 1
    case nearVisible = 2
    case visible = 3
}

enum ThumbnailQueueOrdering {
    /// Decode order for non-viewport work (after any viewport `queueOrder`).
    static let background = Int.max
}

enum ThumbnailDecodeLimits {
    /// Leave decode slots for viewport work while a large folder is gathering.
    static let maxConcurrentBackgroundDecodes = 2
}
