import Foundation

/// Mirrors Python `bundle_capabilities.py` for `--min` builds.
enum BundleCapabilities {
    static var isMinBundle: Bool {
        LaunchOptions.parse().minBundle
            || ProcessInfo.processInfo.environment["PROWSER_MIN_BUNDLE"] == "1"
    }

    static var imageGenUIEnabled: Bool { !isMinBundle }
    static var lmStudioUIEnabled: Bool { !isMinBundle }
    static var voiceInputUIEnabled: Bool { !isMinBundle }
    static var chatUIEnabled: Bool { !isMinBundle }
    static var facesUIEnabled: Bool { !isMinBundle }
    static var modelJobsUIEnabled: Bool { !isMinBundle }
}
