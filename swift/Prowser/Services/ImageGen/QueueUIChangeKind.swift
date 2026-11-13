import Foundation

/// Why the image-gen queue surface is refreshing (pane vs strip-only).
enum QueueUIChangeKind: Sendable {
    /// Step/elapsed/cooldown ticks — strip live sinks only; no SwiftUI job-pane invalidation.
    case liveProgress
    /// Async status views finished building — card text refresh without full chrome bump when possible.
    case statusDetails
    /// Jobs added/removed/reordered, hold/error, or row structure change.
    case structure
}
