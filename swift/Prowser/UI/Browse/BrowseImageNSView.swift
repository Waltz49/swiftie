import AppKit
import Foundation

/// Browse view with zoom and pan. Port of `files/browse_view_handler.py` (phase 1).
final class BrowseImageNSView: NSView {
    weak var appState: AppState?
    var imagePath: String? {
        didSet { loadImage() }
    }

    var numberOverlayVisible = false {
        didSet { needsDisplay = true }
    }

    var overlayIndex = 0
    var overlayCount = 0
    var onActualSizeModeChanged: ((Bool) -> Void)?
    var onExitBrowse: (() -> Void)?

    private var sourceImage: NSImage?
    private var scaleFactor: CGFloat = 1.0
    private var scrollOffset = CGPoint.zero
    private var isActualSize = false
    private var preferredActualSize = false
    private var dragStart: CGPoint?
    private var scrollAtDragStart = CGPoint.zero
    private var rotationDegrees: CGFloat = 0
    private var isFlippedHorizontally = false
    private var isFlippedVertically = false
    private var themeColors = ThemeColors.dark

    override var isFlipped: Bool { true }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func resetView() {
        scaleFactor = 1.0
        scrollOffset = .zero
        isActualSize = false
        resetTransforms()
        needsDisplay = true
    }

    func zoomIn() { applyZoom(factor: scaleFactor * 1.15, anchor: bounds.center) }
    func zoomOut() { applyZoom(factor: scaleFactor / 1.15, anchor: bounds.center) }

    func setActualSizeMode(_ enabled: Bool) {
        if preferredActualSize != enabled {
            onActualSizeModeChanged?(enabled)
        }
        applyDisplayMode(actualSize: enabled)
    }

    func applyDisplayMode(actualSize: Bool) {
        preferredActualSize = actualSize
        applyCurrentDisplayMode()
    }

    private var contentRevision = 0

    func setImage(path: String?, actualSize: Bool, contentRevision: Int = 0) {
        let pathChanged = imagePath != path
        let modeChanged = preferredActualSize != actualSize
        let contentChanged = self.contentRevision != contentRevision
        preferredActualSize = actualSize
        self.contentRevision = contentRevision
        if pathChanged {
            imagePath = path
        } else if contentChanged {
            loadImage()
        } else if modeChanged {
            applyCurrentDisplayMode()
        }
    }

    private func applyCurrentDisplayMode() {
        guard sourceImage != nil else { return }
        isActualSize = preferredActualSize
        if preferredActualSize {
            scaleFactor = 1.0
            scrollOffset = .zero
        } else {
            fitToWindow()
        }
        needsDisplay = true
    }

    func rotateClockwise() {
        rotationDegrees = (rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
        needsDisplay = true
    }

    func rotateCounterclockwise() {
        rotationDegrees = (rotationDegrees - 90).truncatingRemainder(dividingBy: 360)
        needsDisplay = true
    }

    func flipHorizontal() {
        isFlippedHorizontally.toggle()
        needsDisplay = true
    }

    func flipVertical() {
        isFlippedVertically.toggle()
        needsDisplay = true
    }

    func resetTransforms() {
        rotationDegrees = 0
        isFlippedHorizontally = false
        isFlippedVertically = false
        needsDisplay = true
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        guard canPan() else { return }
        scrollOffset.x += dx
        scrollOffset.y += dy
        clampScroll()
        needsDisplay = true
    }

    /// Fit image width to the browse canvas and scroll to the top (Python ^W).
    func fitToCanvasWidth() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return }
        preferredActualSize = false
        isActualSize = false
        onActualSizeModeChanged?(false)
        scaleFactor = bounds.width / imageSize.width
        scrollOffset = CGPoint(x: 0, y: 0)
        needsDisplay = true
    }

    private func loadImage() {
        resetTransforms()
        guard let imagePath else {
            sourceImage = nil
            needsDisplay = true
            return
        }
        if let image = NSImage(contentsOfFile: imagePath) {
            sourceImage = image
            applyCurrentDisplayMode()
        }
    }

    private func fitToWindow() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        scaleFactor = fit
        scrollOffset = .zero
        isActualSize = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !isActualSize, sourceImage != nil {
            fitToWindow()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(themeColors.browseBorderColor).setFill()
        bounds.fill()

        guard let image = sourceImage else {
            drawEmptyState()
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let drawRect = imageDrawRect(for: image)

        if themeColors.browseUseCheckerboard {
            drawCheckerboard(in: drawRect)
        } else {
            NSColor(themeColors.browseTransparencyColor).setFill()
            drawRect.fill()
        }

        context.saveGState()
        context.translateBy(x: drawRect.midX, y: drawRect.midY)
        if isFlippedHorizontally { context.scaleBy(x: -1, y: 1) }
        if isFlippedVertically { context.scaleBy(x: 1, y: -1) }
        if rotationDegrees != 0 {
            context.rotate(by: rotationDegrees * .pi / 180)
        }
        let centered = NSRect(
            x: -drawRect.width / 2,
            y: -drawRect.height / 2,
            width: drawRect.width,
            height: drawRect.height
        )
        image.draw(in: centered, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        context.restoreGState()

        if numberOverlayVisible {
            drawNumberOverlay(in: bounds)
        }
    }

    private func drawNumberOverlay(in rect: NSRect) {
        let name = imagePath.map { ($0 as NSString).lastPathComponent } ?? ""
        let indexText = overlayCount > 0 ? "\(overlayIndex + 1) / \(overlayCount)" : ""
        var lines: [String] = []
        if !indexText.isEmpty { lines.append(indexText) }
        if !name.isEmpty { lines.append(name) }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0,
        ]
        var y: CGFloat = 16
        for line in lines {
            let size = (line as NSString).size(withAttributes: attrs)
            let drawRect = NSRect(
                x: rect.maxX - size.width - 20,
                y: y,
                width: size.width,
                height: size.height
            )
            (line as NSString).draw(in: drawRect, withAttributes: attrs)
            y += size.height + 4
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let delta = event.deltaY
            let factor = delta > 0 ? scaleFactor * 1.1 : scaleFactor / 1.1
            let point = convert(event.locationInWindow, from: nil)
            applyZoom(factor: factor, anchor: point)
            return
        }
        if canPan() {
            scrollOffset.x -= event.deltaX
            scrollOffset.y -= event.deltaY
            clampScroll()
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        applyZoom(factor: scaleFactor * (1.0 + event.magnification), anchor: point)
    }

    override func mouseDown(with event: NSEvent) {
        guard sourceImage != nil else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        scrollAtDragStart = scrollOffset
    }

    override func rightMouseDown(with event: NSEvent) {
        onExitBrowse?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard canPan() else { return }
        scrollOffset.x = scrollAtDragStart.x - (point.x - dragStart.x)
        scrollOffset.y = scrollAtDragStart.y - (point.y - dragStart.y)
        clampScroll()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.command), let appState {
            MainWindowKeyViewLoop.moveFromMainCanvas(appState: appState)
            return
        }
        super.keyDown(with: event)
    }

    private func imageDrawRect(for image: NSImage) -> NSRect {
        let imageSize = image.size
        let width = imageSize.width * scaleFactor
        let height = imageSize.height * scaleFactor
        let x = (bounds.width - width) / 2 - scrollOffset.x
        let y = (bounds.height - height) / 2 - scrollOffset.y
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func applyZoom(factor: CGFloat, anchor: CGPoint) {
        guard let image = sourceImage else { return }
        let clamped = min(max(factor, 0.05), 20.0)
        let before = imageDrawRect(for: image)
        let relX = anchor.x - before.minX
        let relY = anchor.y - before.minY
        let ratio = clamped / max(scaleFactor, 0.0001)
        scaleFactor = clamped
        if preferredActualSize {
            preferredActualSize = false
            isActualSize = false
            onActualSizeModeChanged?(false)
        }
        scrollOffset.x += relX * (ratio - 1.0)
        scrollOffset.y += relY * (ratio - 1.0)
        clampScroll()
        needsDisplay = true
    }

    private func canPan() -> Bool {
        guard let image = sourceImage else { return false }
        let draw = imageDrawRect(for: image)
        return draw.width > bounds.width + 1 || draw.height > bounds.height + 1
    }

    private func clampScroll() {
        guard let image = sourceImage else { return }
        let draw = imageDrawRect(for: image)
        let overflowX = max(0, draw.width - bounds.width)
        let overflowY = max(0, draw.height - bounds.height)
        scrollOffset.x = min(max(scrollOffset.x, -overflowX / 2), overflowX / 2)
        scrollOffset.y = min(max(scrollOffset.y, -overflowY / 2), overflowY / 2)
    }

    private func drawCheckerboard(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        let tile: CGFloat = 8
        // Match Python `_draw_diamond_pattern`: 128 base, 96 on alternating cells.
        let base = NSColor(calibratedRed: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0, alpha: 1)
        let alternate = NSColor(calibratedRed: 96.0 / 255.0, green: 96.0 / 255.0, blue: 96.0 / 255.0, alpha: 1)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        base.setFill()
        rect.fill()

        let startCol = Int(floor(rect.minX / tile))
        let startRow = Int(floor(rect.minY / tile))
        var row = startRow
        var y = CGFloat(startRow) * tile
        while y < rect.maxY {
            var col = startCol
            var x = CGFloat(startCol) * tile
            while x < rect.maxX {
                guard (row + col) % 2 == 0 else {
                    x += tile
                    col += 1
                    continue
                }
                let color = alternate
                color.setFill()
                NSRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile
                col += 1
            }
            y += tile
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEmptyState() {
        let text = "No image selected"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor(themeColors.text),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}

private extension NSRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
