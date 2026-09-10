import AppKit
import Foundation

/// Desktop wallpaper helpers. Port of `wallpaper_manager.py` (subset).
@MainActor
enum WallpaperService {
    enum Scaling {
        case contain
        case cover
        case fitWidth
        case fitHeight
    }

    static func setWallpaper(path: String, scaling: Scaling = .cover) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WallpaperError.fileNotFound
        }
        guard let screen = NSScreen.main else {
            throw WallpaperError.noScreen
        }

        let url = URL(fileURLWithPath: path)
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch scaling {
        case .contain:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = false
        case .cover:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        case .fitWidth, .fitHeight:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = false
        }

        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    enum WallpaperError: LocalizedError {
        case fileNotFound
        case noScreen

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Image file not found."
            case .noScreen: return "No main display found."
            }
        }
    }
}
