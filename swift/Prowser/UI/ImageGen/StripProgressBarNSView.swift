import AppKit

/// Progress bar for the active-job strip. Port of `StripProgressBar` in Python.
final class StripProgressBarNSView: NSView {
    var fillPercent: Int = 0
    var slotText: String = ""
    var showPendingStart = false

    private var colors: ThemeColors = .dark

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

    func setValues(fillPercent: Int, slotText: String, showPendingStart: Bool) {
        self.fillPercent = fillPercent
        self.slotText = slotText
        self.showPendingStart = showPendingStart
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: JobQueueLayout.stripBarMinWidth, height: JobQueueLayout.stripBarHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if !slotText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: JobQueueLayout.fontSize),
                .foregroundColor: NSColor(colors.progressBarText),
            ]
            let size = (slotText as NSString).size(withAttributes: attrs)
            let point = NSPoint(
                x: (rect.width - size.width) / 2,
                y: (rect.height - size.height) / 2
            )
            (slotText as NSString).draw(at: point, withAttributes: attrs)
            return
        }

        ctx.setFillColor(NSColor(colors.progressBarBackground).cgColor)
        ctx.fill(rect)

        let barW = rect.width
        let barH = rect.height
        if showPendingStart && fillPercent <= 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: JobQueueLayout.fontSize),
                .foregroundColor: NSColor.white,
            ]
            ("→" as NSString).draw(
                at: NSPoint(x: (barW - 8) / 2, y: (barH - 12) / 2),
                withAttributes: attrs
            )
        } else {
            let filledW = max(0, min(barW, CGFloat(fillPercent) / 100.0 * barW))
            if filledW > 0 {
                ctx.setFillColor(NSColor(colors.progressBarFill).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: filledW, height: barH))
            }
        }

        ctx.setStrokeColor(NSColor(colors.progressBarBorder).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: max(0, barW - 1), height: max(0, barH - 1)))
    }
}
