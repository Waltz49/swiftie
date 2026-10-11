import Foundation

/// How aggressively `listPlugins` checks install/runtime before returning.
enum ImageGenPluginListAvailability: Sendable {
    /// Cheap filesystem checks only (dialog first paint).
    case fast
    /// Full probes: diffusers import, HF cache walks, per-pipeline MFLUX binaries.
    case full
}
