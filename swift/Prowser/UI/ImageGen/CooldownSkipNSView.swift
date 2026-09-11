import AppKit

/// Port of ``CooldownSkipLabel`` — paints ``Prefix ▶ (N)`` as one tight unit.
@MainActor
final class CooldownSkipNSView: NSView {
    var onSkip: (() -> Void)?

    private static let buttonSize: CGFloat = 16
    private var prefixText = ""
    private var countText = ""
    private var showSkip = true
    private var arrowHovered = false
    private var colors: ThemeColors = .dark
    private var arrowRect = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        self.colors = colors
        needsDisplay = true
    }

    func configure(prefix: String, count: String, showSkip: Bool) {
        let prefixChanged = prefixText != prefix
        let countChanged = countText != count
        let skipChanged = self.showSkip != showSkip
        prefixText = prefix
        countText = count
        self.showSkip = showSkip
        toolTip = showSkip ? "Skip copy cooldown" : ""
        if prefixChanged || countChanged || skipChanged {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    func setArrowHovered(_ hovered: Bool) {
        guard showSkip else { return }
        let hovered = hovered
        guard hovered != arrowHovered else { return }
        arrowHovered = hovered
        needsDisplay = true
    }

    private static func formatCountLabel(_ count: String) -> String {
        let text = count.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("(") {
            return " \(text)"
        }
        return " (\(text))"
    }

    private func layoutMetrics() -> (totalWidth: CGFloat, totalHeight: CGFloat, arrowRect: CGRect) {
        let font = NSFont.systemFont(ofSize: JobQueueLayout.fontSize)
        let prefixWidth = (prefixText as NSString).size(withAttributes: [.font: font]).width
        let countWidth = (Self.formatCountLabel(countText) as NSString).size(withAttributes: [.font: font]).width
        let spaceWidth = ((" " as NSString).size(withAttributes: [.font: font]).width)
        let textHeight = font.ascender - font.descender
        var totalWidth = prefixWidth
        var arrow = CGRect.zero
        if showSkip {
            totalWidth += spaceWidth + Self.buttonSize + countWidth
            let arrowY = max(0, (textHeight - Self.buttonSize) / 2)
            arrow = CGRect(x: prefixWidth + spaceWidth, y: arrowY, width: Self.buttonSize, height: Self.buttonSize)
        } else {
            totalWidth += countWidth
        }
        return (max(1, ceil(totalWidth)), max(1, ceil(textHeight)), arrow)
    }

    override var intrinsicContentSize: NSSize {
        let metrics = layoutMetrics()
        return NSSize(width: metrics.totalWidth, height: metrics.totalHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: JobQueueLayout.fontSize)
        let metrics = layoutMetrics()
        arrowRect = metrics.arrowRect
        var x: CGFloat = 0

        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(colors.sidebarText),
        ]
        let prefixSize = (prefixText as NSString).size(withAttributes: prefixAttrs)
        (prefixText as NSString).draw(
            at: NSPoint(x: x, y: (bounds.height - prefixSize.height) / 2),
            withAttributes: prefixAttrs
        )
        x += prefixSize.width

        if showSkip {
            x += ((" " as NSString).size(withAttributes: [.font: font]).width)
            drawPlayTriangle(in: arrowRect)
            x = arrowRect.maxX + 1
        }

        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(colors.sidebarText),
        ]
        let countLabel = Self.formatCountLabel(countText)
        let countSize = (countLabel as NSString).size(withAttributes: countAttrs)
        (countLabel as NSString).draw(
            at: NSPoint(x: x, y: (bounds.height - countSize.height) / 2),
            withAttributes: countAttrs
        )
    }

    private func drawPlayTriangle(in rect: CGRect) {
        let margin: CGFloat = 2
        let availW = max(1, rect.width - 2 * margin)
        let availH = max(1, rect.height - 2 * margin)
        let side = min(availH, availW * 2 / sqrt(3))
        let cx = rect.midX
        let cy = rect.midY
        let x0 = cx - (side * sqrt(3) / 4)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: cy - side / 2))
        path.line(to: NSPoint(x: x0, y: cy + side / 2))
        path.line(to: NSPoint(x: x0 + side * sqrt(3) / 2, y: cy))
        path.close()
        let fill = NSColor(colors.currentImageBorder)
        // Qt ``QColor.lighter(125)`` parity.
        let arrowFill = arrowHovered
            ? (fill.blended(withFraction: 0.25, of: .white) ?? fill)
            : fill
        arrowFill.setFill()
        path.fill()
    }

    private func arrowHit(_ point: NSPoint) -> Bool {
        showSkip && arrowRect.contains(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showSkip {
            addCursorRect(arrowRect, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        setArrowHovered(arrowHit(convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setArrowHovered(false)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if arrowHit(point) {
            onSkip?()
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}
