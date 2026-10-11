import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Source image preview canvas for edit (Python ``_SourceImagePreview`` / ``_MultiSourceImagePreview``).
@MainActor
struct ImageGenEditSourcePreview: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var themeColors
    @Binding var sourcePaths: [String]
    var onPathsChanged: (() -> Void)?

    var body: some View {
        Group {
            if sourcePaths.count == 1, let path = sourcePaths.first {
                ImageGenSourceNavRow(currentPath: path, onSelectPath: { newPath in
                    applyPaths([newPath])
                }) {
                    previewCanvas
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                previewCanvas
            }
        }
    }

    private var previewCanvas: some View {
        ImageGenEditSourcePreviewRepresentable(
            sourcePaths: sourcePaths,
            imageExtensions: appState.config.imageExtensions,
            themeColors: themeColors,
            onPathsChanged: { paths in
                applyPaths(paths)
            },
            onOpenInBrowse: { path in
                appState.openImageInBrowse(path: path)
            }
        )
        .frame(minWidth: 160, minHeight: 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyPaths(_ paths: [String]) {
        let normalized = ImageGenEditSourcePaths.normalizedPaths(paths)
        guard !normalized.isEmpty else { return }
        sourcePaths = normalized
        onPathsChanged?()
    }
}

@MainActor
struct ImageGenEditSourcePreviewRepresentable: NSViewRepresentable {
    var sourcePaths: [String]
    var imageExtensions: [String]
    var themeColors: ThemeColors
    var onPathsChanged: ([String]) -> Void
    var onOpenInBrowse: (String) -> Void

    func makeNSView(context: Context) -> ImageGenEditSourcePreviewNSView {
        let view = ImageGenEditSourcePreviewNSView()
        view.onPathsChanged = onPathsChanged
        view.onOpenInBrowse = onOpenInBrowse
        view.imageExtensions = imageExtensions
        view.applyTheme(themeColors)
        view.sourcePaths = sourcePaths
        return view
    }

    func updateNSView(_ nsView: ImageGenEditSourcePreviewNSView, context: Context) {
        nsView.onPathsChanged = onPathsChanged
        nsView.onOpenInBrowse = onOpenInBrowse
        nsView.imageExtensions = imageExtensions
        nsView.applyTheme(themeColors)
        nsView.sourcePaths = sourcePaths
    }
}

/// Pasteboard writer for reorder drags inside the edit preview.
private final class EditSourcePathDragWriter: NSObject, NSPasteboardWriting {
    static let pasteboardType = NSPasteboard.PasteboardType(ImageGenEditSourcePaths.internalDragType)

    let path: String

    init(path: String) {
        self.path = path
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [Self.pasteboardType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == Self.pasteboardType else { return nil }
        return path
    }
}

@MainActor
final class ImageGenEditSourcePreviewNSView: NSView, NSDraggingSource {
    var sourcePaths: [String] = [] {
        didSet {
            let normalized = ImageGenEditSourcePaths.normalizedPaths(sourcePaths)
            if normalized != sourcePaths {
                sourcePaths = normalized
                return
            }
            rebuildThumbsIfNeeded()
            needsDisplay = true
        }
    }

    var imageExtensions: [String] = []
    var onPathsChanged: (([String]) -> Void)?
    var onOpenInBrowse: ((String) -> Void)?

    private var themeColors = ThemeColors.dark
    private var thumbViews: [ImageGenEditSourceThumbView] = []
    private let dropLine = NSView()
    private var dropInsertIndex: Int?
    private var dragSourcePath: String?
    private var dragStartPoint: NSPoint?
    private var dragStarted = false
    private var imageCache: [String: (mtime: TimeInterval, image: NSImage)] = [:]

    private static let internalDragType = EditSourcePathDragWriter.pasteboardType
    private static let thumbSpacing: CGFloat = 6

    private static func internalDragPath(from pasteboard: NSPasteboard) -> String? {
        guard pasteboard.types?.contains(internalDragType) == true else { return nil }
        if let text = pasteboard.string(forType: internalDragType), !text.isEmpty {
            return text
        }
        guard let data = pasteboard.data(forType: internalDragType) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, Self.internalDragType])
        wantsLayer = true
        dropLine.wantsLayer = true
        dropLine.isHidden = true
        addSubview(dropLine)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        layer?.backgroundColor = NSColor(colors.browseBorderColor).cgColor
        dropLine.layer?.backgroundColor = NSColor(colors.text).cgColor
        for thumb in thumbViews {
            thumb.applyTheme(colors)
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutThumbs()
        updateDropLineFrame()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if sourcePaths.count == 1 {
            drawSinglePreview()
        }
    }

    private func drawSinglePreview() {
        guard let path = sourcePaths.first else { return }
        NSColor(themeColors.browseBorderColor).setFill()
        bounds.fill()
        guard let image = cachedImage(for: path) else {
            drawLoadError()
            return
        }
        let rect = aspectFitRect(for: image.size, in: bounds)
        ImageDisplayLoader.draw(image, in: rect)
    }

    private func drawLoadError() {
        let text = "Could not load image" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(themeColors.text),
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: origin, withAttributes: attrs)
    }

    private func rebuildThumbsIfNeeded() {
        if sourcePaths.count <= 1 {
            thumbViews.forEach { $0.removeFromSuperview() }
            thumbViews = []
            return
        }
        if thumbViews.count != sourcePaths.count {
            thumbViews.forEach { $0.removeFromSuperview() }
            thumbViews = []
            for path in sourcePaths {
                let thumb = ImageGenEditSourceThumbView(path: path)
                thumb.applyTheme(themeColors)
                thumb.onRemove = { [weak self] path in
                    self?.removePath(path)
                }
                thumb.onOpenInBrowse = { [weak self] path in
                    self?.onOpenInBrowse?(path)
                }
                thumb.onBeginDrag = { [weak self] path, event in
                    self?.beginInternalDrag(path: path, event: event, from: thumb)
                }
                thumb.imageProvider = { [weak self] path in
                    self?.cachedImage(for: path)
                }
                addSubview(thumb)
                thumbViews.append(thumb)
            }
        } else {
            for (index, path) in sourcePaths.enumerated() {
                thumbViews[index].path = path
                thumbViews[index].needsDisplay = true
            }
        }
        layoutThumbs()
    }

    private func layoutThumbs() {
        guard !thumbViews.isEmpty else { return }
        let count = CGFloat(thumbViews.count)
        let totalSpacing = Self.thumbSpacing * max(0, count - 1)
        let width = max(1, (bounds.width - totalSpacing) / count)
        var x: CGFloat = 0
        for thumb in thumbViews {
            thumb.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.thumbSpacing
        }
    }

    private func cachedImage(for path: String) -> NSImage? {
        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: abs)[.modificationDate] as? Date)?.timeIntervalSince1970
        if let row = imageCache[abs], let mtime, row.mtime == mtime {
            return row.image
        }
        guard let image = ImageDisplayLoader.orientedImage(for: abs), image.isValid else { return nil }
        if let mtime {
            imageCache[abs] = (mtime, image)
        }
        return image
    }

    private func aspectFitRect(for imageSize: NSSize, in container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func removePath(_ path: String) {
        guard sourcePaths.count > 1 else { return }
        let paths = sourcePaths.filter { $0 != path }
        guard !paths.isEmpty else { return }
        commitPaths(paths)
    }

    private func commitPaths(_ paths: [String]) {
        let normalized = ImageGenEditSourcePaths.normalizedPaths(paths)
        guard !normalized.isEmpty else { return }
        sourcePaths = normalized
        onPathsChanged?(normalized)
    }

    private func mergeExternal(_ paths: [String], insertIndex: Int?) {
        let result = ImageGenEditSourcePaths.mergeExternalPaths(
            existing: sourcePaths,
            incoming: paths,
            insertIndex: insertIndex,
            extensions: imageExtensions
        )
        if !result.warnings.isEmpty {
            StyledMessageDialog.showWarning(
                title: "Drop Images",
                message: result.warnings.joined(separator: "\n\n")
            )
        }
        if result.paths != sourcePaths {
            commitPaths(result.paths)
        }
    }

    private func insertIndex(at point: NSPoint) -> Int {
        guard !thumbViews.isEmpty else { return 0 }
        for (index, thumb) in thumbViews.enumerated() where point.x < thumb.frame.midX {
            return index
        }
        return thumbViews.count
    }

    private func updateDropLineFrame() {
        guard let index = dropInsertIndex else {
            dropLine.isHidden = true
            return
        }
        let x: CGFloat
        if thumbViews.isEmpty {
            x = 2
        } else if index <= 0 {
            x = thumbViews[0].frame.minX
        } else if index >= thumbViews.count {
            x = thumbViews[thumbViews.count - 1].frame.maxX
        } else {
            let left = thumbViews[index - 1].frame.maxX
            let right = thumbViews[index].frame.minX
            x = (left + right) / 2
        }
        dropLine.frame = NSRect(x: x, y: 4, width: 2, height: max(1, bounds.height - 8))
        dropLine.isHidden = false
    }

    private func beginInternalDrag(path: String, event: NSEvent, from thumb: ImageGenEditSourceThumbView) {
        dragSourcePath = path
        let writer = EditSourcePathDragWriter(path: path)
        let dragging = NSDraggingItem(pasteboardWriter: writer)
        let preview = thumb.dragPreviewImage() ?? NSImage(size: NSSize(width: 96, height: 96))
        let previewSize = NSSize(
            width: max(preview.size.width, 1),
            height: max(preview.size.height, 1)
        )
        dragging.setDraggingFrame(NSRect(origin: .zero, size: previewSize), contents: preview)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    // MARK: - Mouse (single-image drop target)

    override func mouseDown(with event: NSEvent) {
        if sourcePaths.count == 1 {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            dragStarted = false
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard sourcePaths.count == 1 else {
            super.mouseUp(with: event)
            return
        }
        if !dragStarted, event.clickCount >= 2, let path = sourcePaths.first {
            onOpenInBrowse?(path)
        }
        dragStartPoint = nil
        dragStarted = false
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptDrag(sender) else { return [] }
        return sender.draggingSourceOperationMask.intersection([.copy, .move])
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptDrag(sender) else { return [] }
        if sourcePaths.count > 1 {
            dropInsertIndex = insertIndex(at: convert(sender.draggingLocation, from: nil))
            updateDropLineFrame()
        }
        return sender.draggingSourceOperationMask.intersection([.copy, .move])
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropInsertIndex = nil
        dropLine.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let insertIndex = sourcePaths.count > 1 ? insertIndex(at: point) : nil
        dropInsertIndex = nil
        dropLine.isHidden = true

        if let path = Self.internalDragPath(from: sender.draggingPasteboard) {
            let reordered = ImageGenEditSourcePaths.reorder(
                paths: sourcePaths,
                moving: path,
                to: insertIndex ?? sourcePaths.count
            )
            if reordered != sourcePaths {
                commitPaths(reordered)
            }
            return true
        }

        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]
        let paths = urls?.map(\.path) ?? []
        mergeExternal(paths, insertIndex: insertIndex)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSourcePath = nil
    }

    private func acceptDrag(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if Self.internalDragPath(from: pasteboard) != nil {
            return sourcePaths.count > 1
        }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

@MainActor
final class ImageGenEditSourceThumbView: NSView {
    var path: String {
        didSet {
            needsDisplay = true
        }
    }

    var onRemove: ((String) -> Void)?
    var onOpenInBrowse: ((String) -> Void)?
    var onBeginDrag: ((String, NSEvent) -> Void)?
    var imageProvider: ((String) -> NSImage?)?

    private var themeColors = ThemeColors.dark
    private var hoverRemove = false
    private var dragStartPoint: NSPoint?
    private var dragStarted = false

    private static let removeBox: CGFloat = 32
    private static let removeBorder: CGFloat = 2
    private static let removeInset: CGFloat = 3

    override var isFlipped: Bool { true }

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        layer?.backgroundColor = NSColor(colors.browseBorderColor).cgColor
        needsDisplay = true
    }

    func dragPreviewImage() -> NSImage? {
        guard let image = imageProvider?(path) else { return nil }
        let maxSide: CGFloat = 96
        let scale = min(maxSide / image.size.width, maxSide / image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let preview = NSImage(size: size)
        preview.lockFocus()
        ImageDisplayLoader.draw(image, in: NSRect(origin: .zero, size: size))
        preview.unlockFocus()
        return preview
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(themeColors.browseBorderColor).setFill()
        bounds.fill()
        guard let image = imageProvider?(path) else { return }
        let rect = aspectFitRect(for: image.size, in: bounds)
        ImageDisplayLoader.draw(image, in: rect)
        if hoverRemove, let removeRect = removeButtonRect(imageRect: rect) {
            drawRemoveButton(in: removeRect)
        }
    }

    private func aspectFitRect(for imageSize: NSSize, in container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func removeButtonRect(imageRect: NSRect) -> NSRect? {
        guard let parent = superview as? ImageGenEditSourcePreviewNSView,
              parent.sourcePaths.count > 1 else { return nil }
        let box = Self.removeBox
        let inset = Self.removeInset
        return NSRect(
            x: imageRect.maxX - inset - box + 1,
            y: imageRect.minY + inset,
            width: box,
            height: box
        )
    }

    private func drawRemoveButton(in rect: NSRect) {
        NSColor.white.setFill()
        rect.fill()
        let inner = rect.insetBy(dx: Self.removeBorder, dy: Self.removeBorder)
        NSColor.black.setFill()
        inner.fill()
        let xRect = inner.insetBy(dx: 3, dy: 3)
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.move(to: NSPoint(x: xRect.minX, y: xRect.minY))
        path.line(to: NSPoint(x: xRect.maxX, y: xRect.maxY))
        path.move(to: NSPoint(x: xRect.maxX, y: xRect.minY))
        path.line(to: NSPoint(x: xRect.minX, y: xRect.maxY))
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hoverRemove = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverRemove = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hoverRemove,
           let image = imageProvider?(path) {
            let imageRect = aspectFitRect(for: image.size, in: bounds)
            if let removeRect = removeButtonRect(imageRect: imageRect),
               removeRect.contains(point) {
                onRemove?(path)
                return
            }
        }
        dragStartPoint = point
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragStarted, hypot(point.x - start.x, point.y - start.y) >= 16 {
            dragStarted = true
            onBeginDrag?(path, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted, event.clickCount >= 2 {
            onOpenInBrowse?(path)
        }
        dragStartPoint = nil
        dragStarted = false
    }
}

private extension NSImage {
    var isValid: Bool {
        !size.width.isZero && !size.height.isZero
    }
}
