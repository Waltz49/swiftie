import Foundation

enum ViewMode: String, CaseIterable, Sendable {
    case thumbnail
    case list
    case browse
    case slideshow
    case slideshow2
    case slideshow3

    var displayName: String {
        switch self {
        case .thumbnail: return "Thumbnails"
        case .list: return "List"
        case .browse: return "Browse"
        case .slideshow: return "Slideshow"
        case .slideshow2: return "Panning Slideshow"
        case .slideshow3: return "Floating Frames"
        }
    }

    /// Python slideshow managers: hide sidebars and status bar for immersive presentation.
    var hidesSlideshowChrome: Bool {
        switch self {
        case .slideshow, .slideshow2, .slideshow3:
            return true
        default:
            return false
        }
    }
}
