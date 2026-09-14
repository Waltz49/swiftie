import Foundation

/// Feature flags for the Swift-only image browser.
///
/// Python ML/AI workers (image generation, chat, CLIP, faces, Whisper) are not used.
/// Native browser features (thumbnails, EXIF via ImageIO, duplicates) stay enabled.
enum BundleCapabilities {
    /// Python ML/AI workers and their UI. Always off in the Swift-only browser.
    static var pythonMLEnabled: Bool { false }

    static var isMinBundle: Bool { !pythonMLEnabled }

    static var imageGenUIEnabled: Bool { pythonMLEnabled }
    static var lmStudioUIEnabled: Bool { pythonMLEnabled }
    static var voiceInputUIEnabled: Bool { pythonMLEnabled }
    static var chatUIEnabled: Bool { pythonMLEnabled }
    static var facesUIEnabled: Bool { pythonMLEnabled }
    static var modelJobsUIEnabled: Bool { pythonMLEnabled }
    static var clipSearchUIEnabled: Bool { pythonMLEnabled }
    static var similaritySearchUIEnabled: Bool { pythonMLEnabled }
    static var personSearchUIEnabled: Bool { pythonMLEnabled }
}
