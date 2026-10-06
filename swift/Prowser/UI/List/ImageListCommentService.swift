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
        guard let comment = ExifService.readUserDescription(path: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else {
            return ImageListCommentInfo(indicator: .blank, fullComment: "")
        }
        if ExifService.isProwserFormattedUserComment(comment) {
            return ImageListCommentInfo(indicator: .prowserFormatted, fullComment: comment)
        }
        return ImageListCommentInfo(indicator: .exifComment, fullComment: comment)
    }
}
