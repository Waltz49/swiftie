import Foundation

enum ImageListCommentIndicator: Int, Sendable {
    case blank = 0
    case exifComment = 1
    case prowserFormatted = 2

    var displayText: String {
        switch self {
        case .blank: return ""
        case .exifComment: return "✅"
        case .prowserFormatted: return "🔥"
        }
    }

    /// Default list sort: fire → check → blank.
    var sortRank: Int { rawValue }

    var debugLabel: String {
        switch self {
        case .blank: return "blank"
        case .exifComment: return "exifComment"
        case .prowserFormatted: return "prowserFormatted"
        }
    }
}

struct ImageListCommentInfo: Equatable, Sendable {
    var indicator: ImageListCommentIndicator
    var fullComment: String

    var tooltipText: String {
        switch indicator {
        case .blank:
            return ""
        case .exifComment:
            return fullComment
        case .prowserFormatted:
            return ImageGenExifCommentFormatting.extractedPromptText(from: fullComment)
        }
    }
}

/// Classifies EXIF user comments for the list view comments column.
enum ImageListCommentService {
    static func classify(path: String) -> ImageListCommentInfo {
        guard let data = ExifCommentData.read(from: path) else {
            return ImageListCommentInfo(indicator: .blank, fullComment: "")
        }
        let indicator: ImageListCommentIndicator
        if data.kind == .mflux || data.kind == .prowserFormatted {
            indicator = .prowserFormatted
        } else {
            indicator = .exifComment
        }
        return ImageListCommentInfo(indicator: indicator, fullComment: data.rawText)
    }
}
