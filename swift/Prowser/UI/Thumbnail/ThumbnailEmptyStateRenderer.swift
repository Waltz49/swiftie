import AppKit
import SwiftUI

struct ThumbnailEmptyStateStyle {
    var background: NSColor
    var text: NSColor
    var buttonBackground: NSColor
    var buttonBackgroundHover: NSColor
    var buttonBorder: NSColor
    var buttonBorderHover: NSColor
    var buttonTextHover: NSColor

    static func from(theme: ThemeColors) -> ThumbnailEmptyStateStyle {
        ThumbnailEmptyStateStyle(
            background: theme.thumbnailGridBackground.nsColor,
            text: theme.text.nsColor,
            buttonBackground: theme.thumbnailEmptyFilterButtonBackground.nsColor,
            buttonBackgroundHover: theme.thumbnailEmptyFilterButtonBackgroundHover.nsColor,
            buttonBorder: theme.thumbnailEmptyFilterButtonBorder.nsColor,
            buttonBorderHover: theme.thumbnailEmptyFilterButtonBorderHover.nsColor,
            buttonTextHover: theme.thumbnailEmptyFilterButtonTextHover.nsColor
        )
    }
}

struct ThumbnailEmptyFilterButton {
    var rect: NSRect
    var label: String
}

@MainActor
enum ThumbnailEmptyStateRenderer {
    static func message(
        directory: String?,
        filterPattern: String,
        directoryListingDenied: Bool,
        isLoadingDirectory: Bool = false
    ) -> String? {
        guard let directory else { return nil }
        let displayDirectory = StatusBarFormatter.displayPath(directory)
        if isLoadingDirectory {
            return "Loading\n\n\(displayDirectory)"
        }
        if directoryListingDenied {
            return """
            macOS denied access to list images in

            \(displayDirectory)

            Enable Full Disk Access for swift-prowser (or your terminal) under
            System Settings → Privacy & Security
            """
        }
        if filterPattern != "*" {
            return "No Images matching filter pattern \"\(filterPattern)\" are available in\n\n\(displayDirectory)"
        }
        return "No Images are available in\n\n\(displayDirectory)"
    }

    static func draw(
        in bounds: NSRect,
        message: String,
        style: ThumbnailEmptyStateStyle,
        suggestedFilters: [String],
        hasImagesInFolder: Bool,
        hoveredButtonIndex: Int
    ) -> [ThumbnailEmptyFilterButton] {
        style.background.setFill()
        bounds.fill()

        let canvasWidth = bounds.width
        let canvasHeight = bounds.height
        drawMessageWithIcon(
            message: message,
            width: canvasWidth,
            height: canvasHeight,
            style: style
        )

        guard hasImagesInFolder else { return [] }
        return drawFilterButtons(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            suggestedFilters: suggestedFilters,
            style: style,
            hoveredButtonIndex: hoveredButtonIndex
        )
    }

    private static func drawMessageWithIcon(
        message: String,
        width: CGFloat,
        height: CGFloat,
        style: ThumbnailEmptyStateStyle
    ) {
        let fontSize: CGFloat = 20
        let iconSize: CGFloat = 64
        let iconSpacing: CGFloat = 20
        let font = NSFont(name: "Arial", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let lines = message.components(separatedBy: "\n")

        let icon = NSApplication.shared.applicationIconImage
        let iconWidth = icon?.size.width ?? 0
        let iconHeight = icon?.size.height ?? 0
        let scaledIconSize = min(iconSize, max(iconWidth, iconHeight))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.text,
        ]
        var maxTextWidth: CGFloat = 0
        var totalTextHeight: CGFloat = 0
        for line in lines {
            let size = (line as NSString).size(withAttributes: attributes)
            maxTextWidth = max(maxTextWidth, size.width)
            totalTextHeight += size.height
        }

        let totalContentWidth = (icon != nil ? scaledIconSize + iconSpacing : 0) + maxTextWidth
        let startX = (width - totalContentWidth) / 2
        let startY = (height - max(scaledIconSize, totalTextHeight)) / 2

        if let icon {
            let iconY = startY + (max(scaledIconSize, totalTextHeight) - scaledIconSize) / 2
            let iconRect = NSRect(x: startX, y: iconY, width: scaledIconSize, height: scaledIconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let textStartX = startX + (icon != nil ? scaledIconSize + iconSpacing : 0)
        var textY = startY + (max(scaledIconSize, totalTextHeight) - totalTextHeight) / 2
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: textStartX, y: textY), withAttributes: attributes)
            textY += (line as NSString).size(withAttributes: attributes).height
        }
    }

    private static func drawFilterButtons(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        suggestedFilters: [String],
        style: ThumbnailEmptyStateStyle,
        hoveredButtonIndex: Int
    ) -> [ThumbnailEmptyFilterButton] {
        let buttonHeight: CGFloat = 32
        let buttonPaddingH: CGFloat = 16
        let buttonSpacing: CGFloat = 8
        let font = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)

        var labels = suggestedFilters.map { FilterPatternFormatting.buttonLabel(prefix: $0) }
        labels.append("All files(*)")

        var buttonWidths: [CGFloat] = []
        for label in labels {
            let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
            buttonWidths.append(textWidth + buttonPaddingH * 2)
        }

        let totalWidth = buttonWidths.reduce(0, +) + buttonSpacing * CGFloat(max(0, buttonWidths.count - 1))
        let startX = (canvasWidth - totalWidth) / 2
        let startY = (canvasHeight / 2) + 120

        let labelFont = NSFont.boldSystemFont(ofSize: 12)
        let labelText = "Suggested filters:"
        let labelWidth = (labelText as NSString).size(withAttributes: [.font: labelFont]).width
        let labelX = (canvasWidth - labelWidth) / 2
        let labelY = startY - 30
        (labelText as NSString).draw(
            at: NSPoint(x: labelX, y: labelY),
            withAttributes: [.font: labelFont, .foregroundColor: style.text]
        )

        var buttons: [ThumbnailEmptyFilterButton] = []
        var currentX = startX
        for (index, label) in labels.enumerated() {
            let width = buttonWidths[index]
            let rect = NSRect(x: currentX, y: startY, width: width, height: buttonHeight)
            buttons.append(ThumbnailEmptyFilterButton(rect: rect, label: label))

            let isHovered = hoveredButtonIndex == index
            let borderColor = isHovered ? style.buttonBorderHover : style.buttonBorder
            let fillColor = isHovered ? style.buttonBackgroundHover : style.buttonBackground
            let textColor = isHovered ? style.buttonTextHover : style.text

            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            borderColor.setStroke()
            fillColor.setFill()
            path.lineWidth = 1
            path.fill()
            path.stroke()

            let textSize = (label as NSString).size(withAttributes: [.font: font])
            let textX = currentX + buttonPaddingH
            let textY = startY + (buttonHeight - textSize.height) / 2
            (label as NSString).draw(
                at: NSPoint(x: textX, y: textY),
                withAttributes: [.font: font, .foregroundColor: textColor]
            )

            currentX += width + buttonSpacing
        }
        return buttons
    }
}
