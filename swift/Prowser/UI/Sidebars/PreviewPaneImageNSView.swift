import AppKit
import SwiftUI

/// Sidebar preview image: click opens browse; drag exports the active file URL.
struct PreviewPaneDraggableImage: NSViewRepresentable {
    var image: NSImage
    var filePath: String
    var onClick: () -> Void

    func makeNSView(context: Context) -> PreviewPaneImageNSView {
        let view = PreviewPaneImageNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: PreviewPaneImageNSView, context: Context) {
        nsView.image = image
        nsView.filePath = filePath
        nsView.onClick = onClick
        nsView.needsDisplay = true
    }
}

@MainActor
final class PreviewPaneImageNSView: NSView, NSDraggingSource {
    var image: NSImage?
    var filePath: String = ""
    var onClick: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragStarted = false
    private var fileDragPaths: [String] = []
    private let dragThreshold: CGFloat = 5

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let rect = aspectFitRect(for: image.size, in: bounds)
        image.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= dragThreshold else { return }
        guard readableDragPath() != nil else { return }
        dragStarted = true
        dragStart = nil
        beginFileDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted, event.clickCount == 1 {
            onClick?()
        }
        dragStart = nil
        dragStarted = false
    }

    private func readableDragPath() -> String? {
        guard !filePath.isEmpty else { return nil }
        let abs = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard FileManager.default.isReadableFile(atPath: abs) else { return nil }
        return abs
    }

    private func beginFileDrag(event: NSEvent) {
        guard let path = readableDragPath() else { return }
        fileDragPaths = [path]
        let pbItem = NSPasteboardItem()
        pbItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        pbItem.setString(path, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        let preview = dragPreviewImage() ?? NSImage(size: NSSize(width: 64, height: 64))
        item.setDraggingFrame(NSRect(origin: .zero, size: preview.size), contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func dragPreviewImage() -> NSImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let maxSide: CGFloat = 64
        let scale = min(maxSide / image.size.width, maxSide / image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let preview = NSImage(size: size)
        preview.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        preview.unlockFocus()
        return preview
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

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDragDropOperations.sourceOperationMask(for: context, filePaths: fileDragPaths)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        fileDragPaths = []
        dragStarted = false
        dragStart = nil
    }
}
