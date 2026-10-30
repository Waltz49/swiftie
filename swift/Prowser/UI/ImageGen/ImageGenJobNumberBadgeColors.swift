import AppKit
import SwiftUI

/// Job-card job number colors (Python ``JobCard._job_number_color_hex`` / ``JobNumberBadgeLabel``).
enum ImageGenJobNumberBadgeColors {
    static let queuedUnheld = NSColor(red: 0.8, green: 0.67, blue: 0.13, alpha: 1)
    static let activeRunning = NSColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1)
    static let heldRunning = NSColor(red: 0.6, green: 0.4, blue: 0.8, alpha: 1)
    static let errorBackground = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)

    static var queuedUnheldSwiftUI: Color { Color(queuedUnheld) }
    static var activeRunningSwiftUI: Color { Color(activeRunning) }
    static var heldRunningSwiftUI: Color { Color(heldRunning) }
    static var errorBackgroundSwiftUI: Color { Color(errorBackground) }

    static func textColor(isActive: Bool, held: Bool, inError: Bool) -> NSColor {
        let showError = inError && !isActive
        if showError { return .white }
        if isActive {
            return held ? heldRunning : activeRunning
        }
        if held { return errorBackground }
        return queuedUnheld
    }

    static func textColorSwiftUI(isActive: Bool, held: Bool, inError: Bool) -> Color {
        Color(textColor(isActive: isActive, held: held, inError: inError))
    }
}

struct ImageGenJobNumberBadgeView: View {
    let jobNumber: Int
    var isActive: Bool = false
    var held: Bool = false
    var inError: Bool = false
    var fontSize: CGFloat = NSFont.smallSystemFontSize

    private var showError: Bool { inError && !isActive }

    var body: some View {
        Text(ImageGenJobNumber.format(jobNumber))
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(
                ImageGenJobNumberBadgeColors.textColorSwiftUI(
                    isActive: isActive,
                    held: held,
                    inError: inError
                )
            )
            .padding(.horizontal, showError ? 4 : 0)
            .padding(.vertical, showError ? 1 : 0)
            .background {
                if showError {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ImageGenJobNumberBadgeColors.errorBackgroundSwiftUI)
                }
            }
    }
}
