import AppKit
import Foundation
import ImageIO

@MainActor
protocol ThumbnailGridDelegate: AnyObject {
    func thumbnailGridDidSelect(index: Int, path: String)
    func thumbnailGridDidOpenBrowse(index: Int, path: String)
    func thumbnailGridDidReorder(path: String, insertionIndex: Int)
    func thumbnailGridNeedsThumbnail(path: String, size: Int, completion: @escaping (NSImage?) -> Void)
    func thumbnailGridShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView)
    func thumbnailGridDidApplyFilter(label: String)
}

/// Custom-painted thumbnail grid. Port of `thumbnails/thumbnail_canvas.py` (phase 1).
@MainActor
final class ThumbnailGridNSView: NSView {
    weak var gridDelegate: ThumbnailGridDelegate?
    weak var configSource: AppConfig?

    var imagePaths: [String] = [] {
        didSet {
            imageDimensionCache.removeAll()
            reloadLayout()
        }
    }

    var currentIndex: Int = 0 {
        didSet { needsDisplay = true }
    }

    var showFilenames: Bool = false {
        didSet { reloadLayout() }
    }

    var showImageSize: Bool = false {
        didSet { reloadLayout() }
    }

    var overlayBoxColor: NSColor = NSColor.black.withAlphaComponent(0.94)
    var emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: ThemeColors.dark)
    private var themeColors = ThemeColors.dark
    var currentDirectory: String?
    var filterPattern: String = "*"
    var imageExtensions: [String] = []
    var directoryListingDenied = false

    private var suggestedFilters: [String] = []
    private var hasImagesInFolder = false
    private var filterButtons: [ThumbnailEmptyFilterButton] = []
    private var hoveredFilterButtonIndex = -1
    private var trackingArea: NSTrackingArea?

    private var metrics = ThumbnailLayout.metrics(for: 800, itemCount: 0, showFilename: false, showImageSize: false)
    private var imageDimensionCache: [String: String] = [:]
    private var thumbnails: [String: NSImage] = [:]
    private var loadingPaths: Set<String> = []
    private var thumbnailPixelSize: Int = 256
    private var isUpdatingDocumentSize = false
    private var lastLayoutViewportWidth: CGFloat = 0
    var wrapAround = true

    private var dragSourceIndex: Int?
    private var dragStartPoint: NSPoint?
    private var dropInsertionIndex: Int?
    private var dropIndicatorRect: NSRect?
    private let dragThreshold: CGFloat = 6

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: colors)
        overlayBoxColor = NSColor(colors.thumbnailFilenameOverlay)
        needsDisplay = true
    }

    func reloadLayout() {
        let viewportWidth = viewportWidthForLayout()
        let width = max(viewportWidth, 200)
        lastLayoutViewportWidth = width
        if imagePaths.isEmpty {
            let viewport = emptyStateViewportSize()
            applyDocumentSize(
                NSSize(
                    width: max(width, viewport.width),
                    height: max(viewport.height, 300)
                )
            )
            needsDisplay = true
            return
        }
        let cellSize = CGFloat(
            configSource?.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
                ?? ThumbnailLayout.defaultCellSize
        )
        metrics = ThumbnailLayout.metrics(
            for: width,
            itemCount: imagePaths.count,
            showFilename: showFilenames,
            showImageSize: showImageSize,
            cellSize: cellSize
        )
        applyDocumentSize(metrics.contentSize)
        needsDisplay = true
        loadVisibleThumbnails()
    }

    /// Called when the user scrolls; reloads thumbnails for newly visible cells only.
    func noteVisibleRectChanged() {
        noteContainerSizeChanged()
        loadVisibleThumbnails()
    }

    /// Reload grid columns when the scroll view width changes (sidebar hide/show, window resize).
    func noteContainerSizeChanged() {
        let viewportWidth = viewportWidthForLayout()
        if abs(viewportWidth - lastLayoutViewportWidth) > 0.5 {
            reloadLayout()
        }
    }

    func invalidateThumbnail(path: String) {
        thumbnails.removeValue(forKey: path)
        loadingPaths.remove(path)
    }

    func invalidateThumbnails(for paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths {
            thumbnails.removeValue(forKey: path)
            loadingPaths.remove(path)
            imageDimensionCache.removeValue(forKey: path)
        }
        needsDisplay = true
        loadVisibleThumbnails()
    }

    func clearThumbnails() {
        thumbnails.removeAll()
        loadingPaths.removeAll()
        needsDisplay = true
    }

    func updateEmptyStateContext() {
        guard imagePaths.isEmpty else {
            suggestedFilters = []
            hasImagesInFolder = false
            filterButtons = []
            hoveredFilterButtonIndex = -1
            return
        }
        guard let directory = currentDirectory else {
            suggestedFilters = []
            hasImagesInFolder = false
            return
        }

        let supportedFiles = Self.supportedImageFilenames(in: directory, extensions: imageExtensions)
        hasImagesInFolder = !supportedFiles.isEmpty
        if hasImagesInFolder, filterPattern != "*" {
            let basenames = supportedFiles.map { ($0 as NSString).deletingPathExtension }
            suggestedFilters = SuggestedFiltersService.determineSuggestedFilters(filenames: basenames)
        } else {
            suggestedFilters = []
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if imagePaths.isEmpty {
            emptyStateStyle.background.setFill()
            bounds.fill()
            let area = NSRect(origin: .zero, size: emptyStateViewportSize())
            if let message = ThumbnailEmptyStateRenderer.message(
                directory: currentDirectory,
                filterPattern: filterPattern,
                directoryListingDenied: directoryListingDenied
            ) {
                filterButtons = ThumbnailEmptyStateRenderer.draw(
                    in: area,
                    message: message,
                    style: emptyStateStyle,
                    suggestedFilters: suggestedFilters,
                    hasImagesInFolder: hasImagesInFolder,
                    hoveredButtonIndex: hoveredFilterButtonIndex
                )
            } else {
                filterButtons = []
            }
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        emptyStateStyle.background.setFill()
        bounds.fill()

        for index in 0..<imagePaths.count {
            let cell = ThumbnailLayout.frame(for: index, metrics: metrics)
            guard cell.intersects(dirtyRect) else { continue }

            let imageFrame = ThumbnailLayout.imageFrame(
                for: index,
                metrics: metrics,
                showFilename: showFilenames,
                showImageSize: showImageSize
            )
            let borderRect = ThumbnailLayout.thumbnailBorderRect(in: imageFrame)
            let contentRect = ThumbnailLayout.imageContentRect(in: imageFrame)
            let isCurrent = index == currentIndex

            drawThumbnailBackground(in: borderRect, isCurrent: isCurrent, context: context)

            let path = imagePaths[index]
            if let image = thumbnails[path] {
                drawThumbnail(image, in: contentRect, context: context)
            } else {
                NSColor.quaternaryLabelColor.setFill()
                contentRect.fill()
                drawPlaceholder(for: path, in: contentRect)
            }

            drawThumbnailBorder(in: borderRect, isCurrent: isCurrent, context: context)

            if showFilenames || showImageSize {
                drawOverlay(
                    for: path,
                    in: cell,
                    showFilename: showFilenames,
                    showImageSize: showImageSize
                )
            }
        }

        if let rect = dropIndicatorRect {
            drawDropIndicator(in: rect)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
        noteVisibleRectChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reloadLayout()
        installWindowKeyObserver()
        claimKeyboardFocus()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let observer = windowKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowKeyObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private var windowKeyObserver: NSObjectProtocol?

    private func installWindowKeyObserver() {
        guard windowKeyObserver == nil, let window else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            let view = self
            Task { @MainActor in view?.claimKeyboardFocus() }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard imagePaths.isEmpty, !filterButtons.isEmpty else {
            if hoveredFilterButtonIndex != -1 {
                hoveredFilterButtonIndex = -1
                needsDisplay = true
            }
            NSCursor.arrow.set()
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let hovered = filterButtons.firstIndex { $0.rect.contains(point) } ?? -1
        if hovered != hoveredFilterButtonIndex {
            hoveredFilterButtonIndex = hovered
            needsDisplay = true
        }
        if hovered >= 0 {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command) {
            showContextMenu(for: event)
            return
        }

        if imagePaths.isEmpty {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexAt(point: point) else { return }
        dragSourceIndex = index
        dragStartPoint = point
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        let path = imagePaths[index]
        currentIndex = index
        gridDelegate?.thumbnailGridDidSelect(index: index, path: path)
    }

    override func mouseUp(with event: NSEvent) {
        if imagePaths.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            handleEmptyStateClick(at: point)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let start = dragStartPoint,
           hypot(point.x - start.x, point.y - start.y) >= dragThreshold,
           let sourceIndex = dragSourceIndex,
           let insertion = dropInsertionIndex,
           insertion != sourceIndex,
           sourceIndex < imagePaths.count {
            let path = imagePaths[sourceIndex]
            gridDelegate?.thumbnailGridDidReorder(path: path, insertionIndex: insertion)
        } else if event.clickCount >= 2, let index = indexAt(point: point) {
            gridDelegate?.thumbnailGridDidOpenBrowse(index: index, path: imagePaths[index])
        }
        dragSourceIndex = nil
        dragStartPoint = nil
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        needsDisplay = true
    }

    private func handleEmptyStateClick(at point: NSPoint) {
        guard let button = filterButtons.first(where: { $0.rect.contains(point) }) else { return }
        gridDelegate?.thumbnailGridDidApplyFilter(label: button.label)
        suggestedFilters = []
        filterButtons = []
        hoveredFilterButtonIndex = -1
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStartPoint, dragSourceIndex != nil else { return }
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance >= dragThreshold else { return }

        let insertion = ThumbnailReorderService.insertionIndex(
            at: CGPoint(x: point.x, y: point.y),
            metrics: metrics,
            itemCount: imagePaths.count
        )
        dropInsertionIndex = insertion
        dropIndicatorRect = dropIndicatorRect(for: insertion)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        logKey("ThumbnailGridNSView.keyDown keyCode=\(event.keyCode) index=\(currentIndex)")
        guard !imagePaths.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: navigate(.left)
        case 124: navigate(.right)
        case 125: navigate(.down)
        case 126: navigate(.up)
        case 36: // return
            let path = imagePaths[currentIndex]
            gridDelegate?.thumbnailGridDidOpenBrowse(index: currentIndex, path: path)
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func claimKeyboardFocus() {
        guard window != nil else {
            logKey("claimKeyboardFocus skipped (no window)")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard window.isKeyWindow || window.canBecomeKey else {
                self.logKey("claimKeyboardFocus skipped (window not key)")
                return
            }
            window.makeFirstResponder(self)
            let responder = window.firstResponder
            let name = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let isGrid = responder === self
            self.logKey(
                "claimKeyboardFocus firstResponder=\(name) isGrid=\(isGrid) keyWindow=\(window.isKeyWindow)"
            )
        }
    }

    private func logKey(_ message: String) {
        guard let configSource else { return }
        KeyboardInputTracer.log(message, config: configSource)
    }

    func navigate(_ direction: ThumbnailNavigateDirection) {
        guard !imagePaths.isEmpty else { return }
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -metrics.columns
        case .down: delta = metrics.columns
        }
        applySelectionDelta(delta, wrap: wrapAround && (direction == .left || direction == .right))
    }

    func selectIndex(_ index: Int, scroll: Bool, notifyDelegate: Bool = true) {
        guard !imagePaths.isEmpty else { return }
        let clamped = min(max(0, index), imagePaths.count - 1)
        guard clamped != currentIndex else {
            if scroll { scrollToCurrent() }
            return
        }
        currentIndex = clamped
        if notifyDelegate {
            gridDelegate?.thumbnailGridDidSelect(index: clamped, path: imagePaths[clamped])
        }
        if scroll { scrollToCurrent() }
    }

    func scrollToSelection() {
        scrollToCurrent()
    }

    /// Scroll after layout is ready (browse exit, delayed highlight).
    func scrollToSelectionAfterLayout() {
        layoutSubtreeIfNeeded()
        enclosingScrollView?.layoutSubtreeIfNeeded()
        scrollToCurrent()
    }

    private func applySelectionDelta(_ delta: Int, wrap: Bool) {
        let next = nextIndex(currentIndex, delta: delta, wrap: wrap)
        guard next != currentIndex else { return }
        currentIndex = next
        gridDelegate?.thumbnailGridDidSelect(index: next, path: imagePaths[next])
        scrollToCurrent()
    }

    private func nextIndex(_ index: Int, delta: Int, wrap: Bool) -> Int {
        guard !imagePaths.isEmpty else { return 0 }
        let count = imagePaths.count
        let raw = index + delta
        if wrap {
            return ((raw % count) + count) % count
        }
        return min(max(0, raw), count - 1)
    }

    private func scrollToCurrent() {
        guard let scrollView = enclosingScrollView else { return }
        guard currentIndex >= 0, currentIndex < imagePaths.count else { return }
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let cell = ThumbnailLayout.frame(for: currentIndex, metrics: metrics)
        scrollView.contentView.scrollToVisible(cell.insetBy(dx: -20, dy: -20))
    }

    private func showContextMenu(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexAt(point: point) else { return }
        gridDelegate?.thumbnailGridShowContextMenu(for: event, clickedIndex: index, in: self)
    }

    private func indexAt(point: NSPoint) -> Int? {
        for index in 0..<imagePaths.count {
            if ThumbnailLayout.frame(for: index, metrics: metrics).contains(point) {
                return index
            }
        }
        return nil
    }

    private func viewportWidthForLayout() -> CGFloat {
        if let scrollView = enclosingScrollView {
            return scrollView.contentSize.width
        }
        return bounds.width
    }

    private func emptyStateViewportSize() -> NSSize {
        if let scrollView = enclosingScrollView {
            return scrollView.contentSize
        }
        return bounds.size
    }

    private static func supportedImageFilenames(in directory: String, extensions: [String]) -> [String] {
        let normalized = Set(extensions.map { $0.lowercased() })
        let url = URL(fileURLWithPath: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            guard normalized.contains(entry.pathExtension.lowercased()) else { return nil }
            return entry.lastPathComponent
        }
    }

    private func applyDocumentSize(_ newSize: NSSize) {
        guard !isUpdatingDocumentSize else { return }
        if sizesAreClose(frame.size, newSize) { return }
        isUpdatingDocumentSize = true
        setFrameSize(newSize)
        isUpdatingDocumentSize = false
    }

    private func sizesAreClose(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private func loadVisibleThumbnails() {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.documentVisibleRect
        let indices = ThumbnailLayout.visibleIndices(
            in: visible,
            metrics: metrics,
            itemCount: imagePaths.count
        )
        let pixelSize = max(thumbnailPixelSize, Int(metrics.cellWidth * 2))
        for index in indices {
            let path = imagePaths[index]
            if thumbnails[path] != nil || loadingPaths.contains(path) { continue }
            loadingPaths.insert(path)
            gridDelegate?.thumbnailGridNeedsThumbnail(path: path, size: pixelSize) { [weak self] image in
                Task { @MainActor in
                    guard let self else { return }
                    self.loadingPaths.remove(path)
                    if let image {
                        self.thumbnails[path] = image
                        self.setNeedsDisplay(self.thumbnailRect(for: index))
                    }
                }
            }
        }
    }

    private func thumbnailRect(for index: Int) -> NSRect {
        ThumbnailLayout.frame(for: index, metrics: metrics)
    }

    private func drawThumbnailBackground(in rect: NSRect, isCurrent: Bool, context: CGContext) {
        let radius = ThumbnailLayout.cornerRadius
        let path = CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        context.addPath(path)
        if isCurrent {
            context.setFillColor(NSColor(themeColors.currentImageBackground).cgColor)
        } else {
            context.setFillColor(NSColor(themeColors.defaultImageBackground).cgColor)
        }
        context.fillPath()
        context.restoreGState()
    }

    private func drawThumbnailBorder(in rect: NSRect, isCurrent: Bool, context: CGContext) {
        let radius = ThumbnailLayout.cornerRadius
        let path = CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        context.addPath(path)
        if isCurrent {
            let width = CGFloat(themeColors.currentImageBorderWidth)
            if width > 0 {
                context.setStrokeColor(NSColor(themeColors.currentImageBorder).cgColor)
                context.setLineWidth(width)
                context.strokePath()
            }
        } else {
            let width = CGFloat(themeColors.defaultImageBorderWidth)
            if width > 0 {
                context.setStrokeColor(NSColor(themeColors.defaultImageBorder).cgColor)
                context.setLineWidth(width)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private func drawThumbnail(_ image: NSImage, in rect: NSRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let imageSize = pixelSize(of: image)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.interpolationQuality = .high
        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        context.restoreGState()
    }

    private func pixelSize(of image: NSImage) -> NSSize {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func drawOverlay(
        for path: String,
        in cell: NSRect,
        showFilename: Bool,
        showImageSize: Bool
    ) {
        let overlayHeight = ThumbnailLayout.overlayLabelHeight(
            showFilename: showFilename,
            showImageSize: showImageSize
        )
        guard overlayHeight > 0 else { return }

        let labelRect = NSRect(
            x: cell.minX + 4,
            y: cell.minY + cell.height - overlayHeight,
            width: max(0, cell.width - 8),
            height: overlayHeight
        )
        var lines: [String] = []
        if showFilename {
            lines.append((path as NSString).lastPathComponent)
        }
        if showImageSize, let sizeText = dimensionText(for: path) {
            lines.append(sizeText)
        }
        guard !lines.isEmpty else { return }

        let textHeight = CGFloat(lines.count) * ThumbnailLayout.labelHeight
        let pillRect = NSRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: labelRect.width,
            height: min(labelRect.height, textHeight + 4)
        )
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        overlayBoxColor.setFill()
        pillPath.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        var y = pillRect.minY + 2
        for line in lines {
            let lineRect = NSRect(
                x: pillRect.minX + 4,
                y: y,
                width: pillRect.width - 8,
                height: ThumbnailLayout.labelHeight
            )
            (line as NSString).draw(
                with: lineRect,
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: attrs
            )
            y += ThumbnailLayout.labelHeight
        }
    }

    private func dimensionText(for path: String) -> String? {
        if let cached = imageDimensionCache[path] { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let text = "\(width)x\(height)"
        imageDimensionCache[path] = text
        return text
    }

    private func dropIndicatorRect(for insertion: Int) -> NSRect {
        guard !imagePaths.isEmpty else {
            return NSRect(
                x: ThumbnailLayout.canvasInset,
                y: ThumbnailLayout.canvasInset,
                width: 2,
                height: metrics.cellHeight
            )
        }

        let refIndex = min(max(insertion, 0), imagePaths.count - 1)
        let cell = ThumbnailLayout.frame(for: refIndex, metrics: metrics)
        let x = insertion < imagePaths.count
            ? cell.minX
            : cell.maxX + ThumbnailLayout.horizontalSpacing
        return NSRect(x: x - 1, y: cell.minY, width: 2, height: cell.height)
    }

    private func drawDropIndicator(in rect: NSRect) {
        NSColor(themeColors.currentImageBorder).withAlphaComponent(0.85).setFill()
        rect.fill()
    }

    private func drawPlaceholder(for path: String, in rect: NSRect) {
        let ext = (path as NSString).pathExtension.uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (ext as NSString).draw(
            in: rect,
            withAttributes: attrs
        )
    }
}
