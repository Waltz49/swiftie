import AppKit
import SwiftUI

private let jobQueueDragType = NSPasteboard.PasteboardType("application/x-prowser-job-queue-id")

@MainActor
final class JobQueuePanelNSView: NSView, NSDraggingSource {
    var onReorder: ((String, String?) -> Void)?
    var onEdit: ((String) -> Void)?
    var onCancel: ((String, Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let stackView = NSStackView()
    private var cardViews: [JobCardNSView] = []
    private var dropLine = NSBox()
    private var rows: [QueueRowSnapshot] = []
    private var dragJobID: String?
    private var autoScrollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([jobQueueDragType])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        documentView.addSubview(stackView)

        dropLine.boxType = .separator
        dropLine.isHidden = true
        documentView.addSubview(dropLine)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateRows(_ rows: [QueueRowSnapshot]) {
        self.rows = rows
        recycleCards(count: rows.count)
        for (index, row) in rows.enumerated() {
            let card = cardViews[index]
            card.configure(row: row, index: index)
            card.onEdit = { [weak self] in self?.onEdit?(row.jobID) }
            card.onCancel = { [weak self] cascade in self?.onCancel?(row.jobID, cascade) }
        }
        while stackView.arrangedSubviews.count > rows.count {
            stackView.arrangedSubviews.last?.removeFromSuperview()
        }
        for (index, card) in cardViews.prefix(rows.count).enumerated() {
            if index < stackView.arrangedSubviews.count {
                continue
            }
            stackView.addArrangedSubview(card)
        }
        invalidateIntrinsicContentSize()
    }

    private func recycleCards(count: Int) {
        while cardViews.count < count {
            let card = JobCardNSView()
            card.onBeginDrag = { [weak self] jobID, event in
                self?.beginDrag(jobID: jobID, event: event, from: card)
            }
            cardViews.append(card)
        }
    }

    private func beginDrag(jobID: String, event: NSEvent, from card: JobCardNSView) {
        dragJobID = jobID
        let item = NSPasteboardItem()
        item.setString(jobID, forType: jobQueueDragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(card.bounds, contents: card.snapshotImage())
        beginDraggingSession(with: [dragging], event: event, source: self)
        startAutoScroll()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        showDropLine(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        showDropLine(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLine.isHidden = true
        stopAutoScroll()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        stopAutoScroll()
        dropLine.isHidden = true
        guard let jobID = sender.draggingPasteboard.string(forType: jobQueueDragType) else { return false }
        let beforeID = dropTargetJobID(for: sender)
        if beforeID == jobID { return false }
        onReorder?(jobID, beforeID)
        dragJobID = nil
        return true
    }

    private func dropTargetJobID(for sender: NSDraggingInfo) -> String? {
        let point = convert(sender.draggingLocation, from: nil)
        let local = documentView.convert(point, from: self)
        for (index, card) in cardViews.prefix(rows.count).enumerated() {
            if local.y >= card.frame.minY {
                return rows[index].jobID
            }
        }
        return nil
    }

    private func showDropLine(for sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let local = documentView.convert(point, from: self)
        dropLine.isHidden = false
        dropLine.frame = NSRect(x: 4, y: max(0, local.y), width: bounds.width - 8, height: 2)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    private func startAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.autoScrollTick() }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func autoScrollTick() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        let local = scrollView.convert(mouse, from: nil)
        if local.y < 20 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y + 8))
        } else if local.y > scrollView.bounds.height - 20 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollView.contentView.bounds.origin.y - 8)))
        }
    }
}

@MainActor
final class JobCardNSView: NSView {
    var onBeginDrag: ((String, NSEvent) -> Void)?
    var onEdit: (() -> Void)?
    var onCancel: ((Bool) -> Void)?

    private let promptLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let thumbStack = NSStackView()
    private var jobID = ""
    private var mouseDownLocation: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 2
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        thumbStack.orientation = .horizontal
        thumbStack.spacing = 4

        let column = NSStackView(views: [promptLabel, statusLabel, thumbStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: QueueRowSnapshot, index: Int) {
        jobID = row.jobID
        promptLabel.stringValue = row.fullPrompt
        statusLabel.stringValue = row.statusLabel
        thumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for path in row.thumbnailPaths.prefix(3) {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(contentsOfFile: path)
            imageView.frame.size = NSSize(width: 44, height: 44)
            thumbStack.addArrangedSubview(imageView)
        }
        layer?.backgroundColor = row.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.windowBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let dx = current.x - mouseDownLocation.x
        let dy = current.y - mouseDownLocation.y
        if (dx * dx + dy * dy) > 16 {
            onBeginDrag?(jobID, event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit", action: #selector(editAction), keyEquivalent: "")
        menu.addItem(withTitle: "Cancel", action: #selector(cancelAction), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func editAction() { onEdit?() }
    @objc private func cancelAction() { onCancel?(NSEvent.modifierFlags.contains(.option)) }

    func snapshotImage() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

struct JobQueuePanelNSViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    var compactForFloating: Bool = false

    func makeNSView(context: Context) -> JobQueuePanelNSView {
        let view = JobQueuePanelNSView()
        view.onReorder = { jobID, beforeID in
            appState.imageGen.moveJob(before: beforeID, jobID: jobID)
        }
        view.onEdit = { jobID in
            appState.openImageGenDialog(replaceJobID: jobID)
        }
        view.onCancel = { jobID, cascade in
            appState.imageGen.cancelJob(id: jobID, cascade: cascade)
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: JobQueuePanelNSView, context: Context) {
        _ = compactForFloating
        context.coordinator.revision = appState.imageGen.queueRevision
        let controller = appState.imageGen
        let mode = appState.jobsQueueSizeMode
        let rows: [QueueRowSnapshot]
        switch mode {
        case .all:
            rows = controller.queueSnapshot()
        case .one:
            rows = controller.queueSnapshot().filter(\.isActive).prefix(1).map { $0 }
        case .strip:
            rows = []
        }
        nsView.updateRows(rows)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: JobQueuePanelNSView?
        var revision = 0
    }
}
