import AppKit
import SwiftUI

/// Port of Python `tooltip_popup_utils.GraphicTooltipPopup` / `IconGraphicTooltipFilter`.
/// Floating icon+text tooltip placed near the hovered graphic button (cursor, clamped to the host window).
@MainActor
final class GraphicButtonTooltipPopup: NSObject {
    static let shared = GraphicButtonTooltipPopup()

    static let iconPx: CGFloat = 48
    private static let textMaxWidth: CGFloat = 320
    private static let offsetX: CGFloat = 12
    private static let offsetY: CGFloat = 20
    private static let margin: CGFloat = 10

    private let panel: GraphicTooltipPanel
    private let chrome: GraphicTooltipChromeView
    private let stack: NSStackView
    private let iconView: NSImageView
    private let iconWidthConstraint: NSLayoutConstraint
    private let iconHeightConstraint: NSLayoutConstraint
    private let textColumn: NSStackView
    private let textField: NSTextField
    private let footerField: NSTextField
    private static let importNoDataMarker = ImageGenExifImport.importTooltipNoDataLine
    private var showTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var forceHideTask: Task<Void, Never>?
    private weak var activeAnchorView: NSView?
    private var activeToken: UUID?

    private override init() {
        panel = GraphicTooltipPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: Self.iconPx)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: Self.iconPx)
        NSLayoutConstraint.activate([iconWidthConstraint, iconHeightConstraint])

        textField = NSTextField(wrappingLabelWithString: "")
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.font = NSFont.systemFont(ofSize: 11)
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.preferredMaxLayoutWidth = Self.textMaxWidth
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        footerField = NSTextField(wrappingLabelWithString: "")
        footerField.isEditable = false
        footerField.isSelectable = false
        footerField.isBezeled = false
        footerField.drawsBackground = false
        footerField.backgroundColor = .clear
        footerField.font = NSFont.systemFont(ofSize: 11)
        footerField.maximumNumberOfLines = 0
        footerField.lineBreakMode = .byWordWrapping
        footerField.preferredMaxLayoutWidth = Self.textMaxWidth
        footerField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerField.setContentCompressionResistancePriority(.required, for: .vertical)
        footerField.isHidden = true

        textColumn = NSStackView(views: [textField, footerField])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 6
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stack = NSStackView(views: [iconView, textColumn])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        chrome = GraphicTooltipChromeView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -1),
            // Python ``GraphicTooltipPopup``: ``setMaximumWidth(320)`` on the text label.
            textColumn.widthAnchor.constraint(equalToConstant: Self.textMaxWidth),
        ])
        panel.contentView = chrome
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppResign),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func scheduleShow(
        token: UUID,
        text: String,
        icon: NSImage,
        colors: ThemeColors,
        anchorView: NSView?,
        iconPixelSize: CGFloat = 48
    ) {
        showTask?.cancel()
        stopMonitoring()
        panel.orderOut(nil)
        activeToken = token
        let delayNs = UInt64(TimingConstants.graphicButtonTooltipDelayMs) * 1_000_000
        let pixelSize = iconPixelSize
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, activeToken == token else { return }
            present(
                text: text,
                icon: icon,
                colors: colors,
                anchorView: anchorView,
                iconPixelSize: pixelSize
            )
        }
    }

    func hide(token: UUID) {
        guard activeToken == token else { return }
        dismiss()
    }

    private func dismiss() {
        showTask?.cancel()
        showTask = nil
        stopMonitoring()
        activeToken = nil
        activeAnchorView = nil
        panel.orderOut(nil)
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        forceHideTask?.cancel()
        forceHideTask = nil
    }

    private func startMonitoring(token: UUID, anchorView: NSView?) {
        stopMonitoring()
        activeAnchorView = anchorView
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                pollDismissIfNeeded(token: token)
                if !panel.isVisible { return }
            }
        }
        let maxNs = UInt64(TimingConstants.graphicButtonTooltipMaxVisibleSeconds * 1_000_000_000)
        forceHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: maxNs)
            guard !Task.isCancelled, activeToken == token else { return }
            dismiss()
        }
    }

    private func pollDismissIfNeeded(token: UUID) {
        guard panel.isVisible, activeToken == token else {
            stopMonitoring()
            return
        }
        guard let host = activeAnchorView else { return }
        if !hostEffectiveVisible(host) || !hostUnderCursor(host) {
            hide(token: token)
        }
    }

    /// Python `_host_effective_visible` — suppress tips when the anchor is hidden or faded out.
    private func hostEffectiveVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.isHidden || node.alphaValue < 0.01 {
                return false
            }
            current = node.superview
        }
        guard let window = view.window, window.isVisible else { return false }
        return true
    }

    private func hostUnderCursor(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let locationInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = view.convert(locationInWindow, from: nil)
        return view.bounds.contains(pointInView)
    }

    private func present(
        text: String,
        icon: NSImage,
        colors: ThemeColors,
        anchorView: NSView?,
        iconPixelSize: CGFloat = 48
    ) {
        let iconSide = max(1, iconPixelSize)
        iconWidthConstraint.constant = iconSide
        iconHeightConstraint.constant = iconSide
        if iconSide > Self.iconPx {
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        } else {
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 8)
        }
        // Python `graphic_button_tooltip_stylesheet`: qtooltip_bg_hex / fg / border.
        // Draw in sRGB AppKit colors — SwiftUI layer colors and light NSPanel chrome
        // otherwise yield a white system tooltip fill.
        let bg = Self.srgbColor(colors.tooltipBackground, fallback: NSColor.black)
        let fg = Self.srgbColor(colors.tooltipText, fallback: NSColor(srgbRed: 0.867, green: 0.933, blue: 1, alpha: 1))
        let border = Self.srgbColor(colors.tooltipBorder, fallback: NSColor(srgbRed: 0.698, green: 0.698, blue: 0.722, alpha: 1))
        chrome.fillColor = bg
        chrome.strokeColor = border
        panel.backgroundColor = .clear
        let appearanceName: NSAppearance.Name = (bg.usingColorSpace(.sRGB)?.redComponent ?? 0) < 0.5
            ? .darkAqua
            : .aqua
        panel.appearance = NSAppearance(named: appearanceName)
        applyTooltipText(text, appearanceName: appearanceName, foreground: fg)
        iconView.image = icon
        iconView.isHidden = false

        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        size.width = ceil(size.width)
        size.height = ceil(size.height)
        guard size.width > 0, size.height > 0 else { return }

        panel.setContentSize(size)
        let origin = positionNearButton(
            size: size,
            anchorView: anchorView
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if let token = activeToken {
            startMonitoring(token: token, anchorView: anchorView)
        }
    }

    /// Python `position_tooltip_near_cursor`: below-right of the cursor, flipped/clamped to the host window.
    /// Cursor is taken only when it is still over the hovered button so the box stays near that control.
    private func applyTooltipText(_ text: String, appearanceName: NSAppearance.Name, foreground fg: NSColor) {
        let appearance = NSAppearance(named: appearanceName)
        textField.appearance = appearance
        footerField.appearance = appearance
        textField.textColor = fg
        footerField.textColor = fg
        let font = textField.font ?? NSFont.systemFont(ofSize: 11)
        let marker = Self.importNoDataMarker
        let markerPrefix = "\n\n" + marker
        if let range = text.range(of: markerPrefix, options: .backwards) {
            let body = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            textField.stringValue = body
            footerField.stringValue = marker
            footerField.isHidden = false
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines) == marker {
            textField.stringValue = ""
            footerField.stringValue = marker
            footerField.isHidden = false
        } else {
            textField.stringValue = text
            footerField.stringValue = ""
            footerField.isHidden = true
        }
        for field in [textField, footerField] {
            if let cell = field.cell as? NSTextFieldCell {
                cell.wraps = true
                cell.isScrollable = false
                cell.truncatesLastVisibleLine = false
            }
        }
        let bodyText = textField.stringValue
        if bodyText.contains("\n") || !footerField.isHidden {
            textField.preferredMaxLayoutWidth = Self.textMaxWidth
            footerField.preferredMaxLayoutWidth = Self.textMaxWidth
        } else {
            let textBounds = (bodyText as NSString).boundingRect(
                with: NSSize(width: Self.textMaxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            textField.preferredMaxLayoutWidth = min(Self.textMaxWidth, max(ceil(textBounds.width), 1))
        }
    }

    private func positionNearButton(size: NSSize, anchorView: NSView?) -> NSPoint {
        let cursor = NSEvent.mouseLocation
        let buttonRect = Self.screenRect(for: anchorView)
        let anchor: NSPoint
        if let buttonRect {
            let padded = buttonRect.insetBy(dx: -24, dy: -24)
            anchor = padded.contains(cursor)
                ? cursor
                : NSPoint(x: buttonRect.midX, y: buttonRect.midY)
        } else {
            anchor = cursor
        }

        let bounds: NSRect
        if let window = anchorView?.window, window.isVisible {
            bounds = window.frame
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            bounds = screen.visibleFrame
        } else {
            bounds = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        var x = anchor.x + Self.offsetX
        var y = anchor.y - Self.offsetY - size.height
        if x + size.width > bounds.maxX - Self.margin {
            x = anchor.x - size.width - Self.offsetX
        }
        if y < bounds.minY + Self.margin {
            y = anchor.y + Self.offsetY
        }

        let left = bounds.minX + Self.margin
        let bottom = bounds.minY + Self.margin
        let right = bounds.maxX - Self.margin - size.width
        let top = bounds.maxY - Self.margin - size.height
        x = max(left, min(x, right))
        y = max(bottom, min(y, top))
        return NSPoint(x: x, y: y)
    }

    @objc private func handleAppResign() {
        if activeToken != nil {
            dismiss()
        } else {
            showTask?.cancel()
            showTask = nil
            panel.orderOut(nil)
        }
    }

    private static func screenRect(for view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private static func srgbColor(_ color: Color, fallback: NSColor) -> NSColor {
        let ns = color.nsColor
        if let srgb = ns.usingColorSpace(.sRGB) {
            let r = srgb.redComponent
            let g = srgb.greenComponent
            let b = srgb.blueComponent
            // Unresolved SwiftUI colors can snapshot as white in a light
            // EnvironmentValues; treat that as a miss when the fallback is dark.
            if r > 0.95, g > 0.95, b > 0.95, fallback.usingColorSpace(.sRGB)?.redComponent ?? 0 < 0.2 {
                return fallback
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: srgb.alphaComponent)
        }
        return fallback
    }
}

private final class GraphicTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Opaque rounded fill + 1px border. CALayer on NSStackView was showing the
/// system (light) window background instead of `qtooltip_bg_hex`.
private final class GraphicTooltipChromeView: NSView {
    var fillColor: NSColor = .black {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor = NSColor(srgbRed: 0.698, green: 0.698, blue: 0.722, alpha: 1) {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSRect(
            x: bounds.minX + 0.5,
            y: bounds.minY + 0.5,
            width: max(0, bounds.width - 1),
            height: max(0, bounds.height - 1)
        )
        let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private struct GraphicTooltipAnchorView: NSViewRepresentable {
    @Binding var nsView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { nsView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.nsView = nsView }
    }
}

struct GraphicButtonTooltipModifier: ViewModifier {
    let text: String
    let icon: NSImage?
    var iconPixelSize: CGFloat = 48

    @Environment(\.themeColors) private var colors
    @State private var token = UUID()
    @State private var anchorView: NSView?

    @ViewBuilder
    func body(content: Content) -> some View {
        let hasIcon = icon.map { $0.size.width > 0 && $0.size.height > 0 } ?? false
        let decorated = content
            .background {
                if hasIcon {
                    GraphicTooltipAnchorView(nsView: $anchorView)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: text) { _, _ in
                GraphicButtonTooltipPopup.shared.hide(token: token)
            }
            .onHover { hovering in
                let tip = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tip.isEmpty else { return }
                if hovering {
                    if hasIcon, let icon {
                        GraphicButtonTooltipPopup.shared.scheduleShow(
                            token: token,
                            text: tip,
                            icon: icon,
                            colors: colors,
                            anchorView: anchorView,
                            iconPixelSize: iconPixelSize
                        )
                    }
                } else {
                    GraphicButtonTooltipPopup.shared.hide(token: token)
                }
            }
            .onDisappear {
                GraphicButtonTooltipPopup.shared.hide(token: token)
            }
        let tip = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasIcon || tip.isEmpty {
            decorated
        } else {
            decorated.help(tip)
        }
    }
}

extension View {
    func graphicButtonTooltip(
        text: String,
        icon: NSImage?,
        iconPixelSize: CGFloat = 48
    ) -> some View {
        modifier(GraphicButtonTooltipModifier(text: text, icon: icon, iconPixelSize: iconPixelSize))
    }
}
