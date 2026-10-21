import Foundation

/// Resolves `Prowser_Prowser.bundle` for a packaged `.app` and for `swift run` / tests.
///
/// SwiftPM's generated `Bundle.module` looks beside `Bundle.main.bundleURL`, which does not
/// match `Contents/Resources/Prowser_Prowser.bundle` when the app is installed on another Mac.
enum ProwserResourceBundle {
    static let bundle: Bundle = {
        if let embedded = bundleInMainResources() {
            return embedded
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()

    private static func bundleInMainResources() -> Bundle? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("Prowser_Prowser.bundle", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bundle(url: url)
    }

    /// Resource lookup for packaged `.app` and `swift run` (never use `Bundle.main` for SPM-copied assets).
    static func url(
        forResource name: String,
        withExtension ext: String?,
        subdirectory: String? = nil
    ) -> URL? {
        if let subdirectory,
           let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        return bundle.url(forResource: name, withExtension: ext)
    }
}
