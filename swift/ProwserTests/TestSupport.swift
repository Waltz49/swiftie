import Foundation
@testable import Prowser

enum ProwserTestSupport {
    /// Isolated profile root under the system temp directory (not the user's `~/.swift-prowser`).
    @MainActor
    static func ephemeralAppConfig(profileRoot: URL? = nil) -> AppConfig {
        let root = profileRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("prowser-test-\(UUID().uuidString)", isDirectory: true)
        return AppConfig(profilePath: root.path)
    }
}
