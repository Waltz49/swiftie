import AppKit

/// Transparent hover target for active-strip progress rows (matches job-card click overlay).
@MainActor
final class StripProgressTooltipHostNSView: NSView {
    var progressTooltipText: String = ""
    var themeColors: ThemeColors = .dark

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), !isHidden, alphaValue > 0.01 else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        let tip = progressTooltipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.isEmpty else { return }
        ListPromptTooltip.shared.scheduleShow(
            text: tip,
            colors: themeColors,
            anchorView: self,
            delayMs: 1000
        )
    }

    override func mouseExited(with event: NSEvent) {
        ListPromptTooltip.shared.hide(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        ListPromptTooltip.shared.hide(for: self)
        super.mouseDown(with: event)
    }
}
