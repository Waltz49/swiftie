import Foundation

/// Tree image visibility vs `DirectoryScanner` / thumbnail listing.
enum FileTreeImageFileFilter {
    /// `show_hidden_directories` lists hidden folders; UF_HIDDEN image files still must not count as tree images.
    nonisolated static func isHiddenImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }

    nonisolated static func isHiddenImageFile(isHidden: Bool?) -> Bool {
        isHidden == true
    }
}
