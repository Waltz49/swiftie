import AppKit
import SwiftUI

private let jobQueueDragType = NSPasteboard.PasteboardType("application/x-prowser-job-queue-id")

@MainActor
final class JobQueuePanelNSView: NSView, NSDraggingSource {
    var onReorder: ((String, String?) -> Void)?
    var onEdit: ((String) -> Void)?
    var onCancel: ((String, Bool) -> Void)?
    var onSelect: ((String?) -> Void)?
    var onAddSeries: ((Int, Bool) -> Void)?
    var onSubtractSeries: ((Int, Bool) -> Void)?
    var onToggleImageRefinement: ((String, Bool) -> Void)?
    var onToggleTextRefinement: ((String, Bool) -> Void)?
    var actionBarStateProvider: ((String) -> JobQueueActionBarState)?

    var themeColors: ThemeColors = .dark
    var selectedJobID: String?
    /// Width from SwiftUI layout proposal; used when AppKit bounds are not ready yet.
    var containerWidth: CGFloat = 260

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let stackView = NSStackView()
    private var cardViews: [JobCardNSView] = []
    private var dropLine = NSView()
    private var rows: [QueueRowSnapshot] = []
    private var dragJobID: String?
    private var autoScrollTimer: Timer?
    private var lastConfiguredScrollWidth: CGFloat = 0
    private let sharedActionBar = JobQueueActionBarNSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        registerForDraggedTypes([jobQueueDragType])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = JobQueueLayout.listSpacing
        documentView.addSubview(stackView)

        dropLine.wantsLayer = true
        dropLine.isHidden = true
        documentView.addSubview(dropLine)

        sharedActionBar.isHidden = true
        wireActionBar()

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func wireActionBar() {
        sharedActionBar.onEdit = { [weak self] in
            guard let id = self?.selectedJobID else { return }
            self?.onEdit?(id)
        }
        sharedActionBar.onCancel = { [weak self] cascade in
            guard let id = self?.selectedJobID else { return }
            self?.onCancel?(id, cascade)
        }
        sharedActionBar.onAddSeries = { [weak self] delta, option in
            self?.onAddSeries?(delta, option)
        }
        sharedActionBar.onSubtractSeries = { [weak self] delta, option in
            self?.onSubtractSeries?(delta, option)
        }
        sharedActionBar.onToggleImageRefinement = { [weak self] enabled in
            guard let id = self?.selectedJobID else { return }
            self?.onToggleImageRefinement?(id, enabled)
        }
        sharedActionBar.onToggleTextRefinement = { [weak self] enabled in
            guard let id = self?.selectedJobID else { return }
            self?.onToggleTextRefinement?(id, enabled)
        }
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        sharedActionBar.applyTheme(colors)
        for card in cardViews {
            card.applyTheme(colors)
        }
    }

    func updateRows(_ rows: [QueueRowSnapshot], selectedJobID: String?, scrollWidth: CGFloat) {
        self.rows = rows
        self.selectedJobID = selectedJobID
        if scrollWidth > 0 {
            lastConfiguredScrollWidth = scrollWidth
        }
        recycleCards(count: rows.count)
        var selectedCard: JobCardNSView?
        for (index, row) in rows.enumerated() {
            let card = cardViews[index]
            let isSelected = row.jobID == selectedJobID
            card.configure(
                row: row,
                index: index,
                scrollWidth: scrollWidth,
                selected: isSelected,
                colors: themeColors
            )
            card.onEdit = { [weak self] in self?.onEdit?(row.jobID) }
            card.onCancel = { [weak self] cascade in self?.onCancel?(row.jobID, cascade) }
            card.onSelect = { [weak self] in self?.onSelect?(row.jobID) }
            if isSelected { selectedCard = card }
        }
        attachActionBar(to: selectedCard)
        refreshActionBarState()
        while stackView.arrangedSubviews.count > rows.count {
            stackView.arrangedSubviews.last?.removeFromSuperview()
        }
        for (index, card) in cardViews.prefix(rows.count).enumerated() {
            if index < stackView.arrangedSubviews.count { continue }
            stackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
        updateDocumentHeight()
        if !rows.isEmpty {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        }
        invalidateIntrinsicContentSize()
    }

    var fittingContentHeight: CGFloat {
        stackView.layoutSubtreeIfNeeded()
        return max(stackView.fittingSize.height + 8, 40)
    }

    func measuredCardStackHeight() -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let visibleCount = min(cardViews.count, rows.count)
        guard visibleCount > 0 else { return 0 }
        var height: CGFloat = 8
        for index in 0..<visibleCount {
            height += cardViews[index].layoutHeight
            if index > 0 {
                height += JobQueueLayout.listSpacing
            }
        }
        return height
    }

    func measuredFirstCardHeight() -> CGFloat {
        guard !rows.isEmpty, let card = cardViews.first else { return 0 }
        return card.layoutHeight + 8
    }

    private func effectiveScrollWidth() -> CGFloat {
        max(bounds.width, containerWidth, scrollView.contentSize.width, lastConfiguredScrollWidth, 260)
    }

    private func updateDocumentHeight() {
        stackView.layoutSubtreeIfNeeded()
        let contentHeight = fittingContentHeight
        let width = effectiveScrollWidth()
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        stackView.layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        updateDocumentHeight()
    }

    private func attachActionBar(to card: JobCardNSView?) {
        sharedActionBar.removeFromSuperview()
        sharedActionBar.isHidden = card == nil
        guard let card else { return }
        card.attachActionBar(sharedActionBar)
        sharedActionBar.applyTheme(themeColors)
        refreshActionBarState()
    }

    private func refreshActionBarState() {
        guard let selectedJobID, let actionBarStateProvider else {
            sharedActionBar.configure(state: .empty)
            return
        }
        sharedActionBar.configure(state: actionBarStateProvider(selectedJobID))
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
        dropLine.layer?.backgroundColor = NSColor(themeColors.jobQueueSelectionBorder).cgColor
        dropLine.frame = NSRect(x: 4, y: max(0, local.y), width: bounds.width - 8, height: 2)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
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
    override var isFlipped: Bool { true }

    var onBeginDrag: ((String, NSEvent) -> Void)?
    var onEdit: (() -> Void)?
    var onCancel: ((Bool) -> Void)?
    var onSelect: (() -> Void)?

    private let backgroundView = NSView()
    private let contentView = NSView()
    private let statusWidget = JobCardStatusNSView()
    private let thumbStack = NSStackView()
    private let mainRow = NSStackView()
    private let column = NSStackView()
    private var jobID = ""
    private var mouseDownLocation: NSPoint = .zero
    private var clickCount = 0
    private var colors: ThemeColors = .dark
    private var actionBarContainer: NSView?
    private var statusWidthConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private(set) var layoutHeight: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = JobQueueLayout.cardCornerRadius
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        statusWidget.translatesAutoresizingMaskIntoConstraints = false
        thumbStack.orientation = .horizontal
        thumbStack.spacing = JobQueueLayout.thumbGap
        thumbStack.translatesAutoresizingMaskIntoConstraints = false

        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = JobQueueLayout.cardInnerSpacing
        mainRow.distribution = .fill
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        mainRow.addArrangedSubview(statusWidget)
        mainRow.addArrangedSubview(thumbStack)
        statusWidget.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusWidget.setContentCompressionResistancePriority(.required, for: .horizontal)
        thumbStack.setContentHuggingPriority(.required, for: .horizontal)
        thumbStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = JobQueueLayout.cardInnerSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(mainRow)

        contentView.addSubview(column)
        addSubview(backgroundView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: JobQueueLayout.cardOuterMargin),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -JobQueueLayout.cardOuterMargin),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: JobQueueLayout.cardOuterMargin),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -JobQueueLayout.cardOuterMargin),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        self.colors = colors
        statusWidget.applyTheme(colors)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: layoutHeight)
    }

    func configure(
        row: QueueRowSnapshot,
        index: Int,
        scrollWidth: CGFloat,
        selected: Bool,
        colors: ThemeColors
    ) {
        jobID = row.jobID
        self.colors = colors
        applyTheme(colors)

        while column.arrangedSubviews.count > 1 {
            column.arrangedSubviews.last?.removeFromSuperview()
        }
        let contentWidth = max(80, scrollWidth - JobQueueLayout.cardContentMargin)
        thumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let refs = row.thumbnailPaths
        let useInline = scrollWidth > JobQueueLayout.inlineRefsMinScrollWidth && refs.count >= 1 && refs.count <= 2
        if useInline {
            if thumbStack.superview == nil {
                mainRow.addArrangedSubview(thumbStack)
            }
            thumbStack.isHidden = false
            for path in refs.prefix(2) {
                thumbStack.addArrangedSubview(makeThumb(path: path, invalid: row.referencesInvalid))
            }
        } else {
            thumbStack.removeFromSuperview()
            if !refs.isEmpty {
                let wrap = NSStackView()
                wrap.orientation = .horizontal
                wrap.alignment = .trailing
                wrap.spacing = JobQueueLayout.thumbGap
                for path in refs.prefix(3) {
                    wrap.addArrangedSubview(makeThumb(path: path, invalid: row.referencesInvalid))
                }
                column.addArrangedSubview(wrap)
            }
        }
        let textWidth = Self.statusTextWidth(
            contentWidth: contentWidth,
            scrollWidth: scrollWidth,
            inlineRefs: useInline
        )
        let statusView: QueueJobStatusView
        if let view = row.statusView, !view.isEmpty {
            statusView = view
        } else {
            statusView = QueueJobStatusView.degradedFallback(
                prompt: row.fullPrompt,
                copiesTotal: row.copiesTotal
            )
        }
        statusWidthConstraint?.isActive = false
        statusWidthConstraint = statusWidget.widthAnchor.constraint(equalToConstant: textWidth)
        statusWidthConstraint?.priority = .required
        statusWidthConstraint?.isActive = true
        statusWidget.setStatusView(statusView, contentWidth: textWidth)
        syncCardHeight(inlineRefs: useInline, hasBelowRefs: !useInline && !refs.isEmpty)

        let running = row.isActive
        let bg = running ? colors.jobQueueRunningCellBackground : colors.jobQueueCellBackground
        backgroundView.layer?.backgroundColor = NSColor(bg).cgColor
        if selected {
            backgroundView.layer?.borderWidth = CGFloat(colors.currentImageBorderWidth)
            backgroundView.layer?.borderColor = NSColor(colors.jobQueueSelectionBorder).cgColor
        } else {
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
        }
        invalidateIntrinsicContentSize()
    }

    func attachActionBar(_ bar: NSView) {
        actionBarContainer?.removeFromSuperview()
        bar.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(bar)
        actionBarContainer = bar
        invalidateIntrinsicContentSize()
    }

    private static func statusTextWidth(
        contentWidth: CGFloat,
        scrollWidth: CGFloat,
        inlineRefs: Bool
    ) -> CGFloat {
        if inlineRefs {
            let reserved = JobQueueLayout.thumbSize
                + JobQueueLayout.inlineRefsRightPadding
                + JobQueueLayout.inlineTextRefsSpacing
            return max(80, contentWidth - reserved)
        }
        return max(80, contentWidth)
    }

    private func syncCardHeight(inlineRefs: Bool, hasBelowRefs: Bool) {
        statusWidget.layoutSubtreeIfNeeded()
        let statusH = statusWidget.intrinsicContentSize.height
        let refsH: CGFloat = (inlineRefs && !thumbStack.arrangedSubviews.isEmpty) || hasBelowRefs
            ? JobQueueLayout.thumbSize
            : 0
        let contentH = inlineRefs ? max(statusH, refsH) + 2 : statusH + refsH + 2
        let frameH = JobQueueLayout.cardOuterMargin * 2 + contentH
            + ((actionBarContainer?.isHidden == false) ? JobQueueLayout.actionBarHeight + JobQueueLayout.cardInnerSpacing : 0)
        layoutHeight = max(frameH, 40)
        cardHeightConstraint?.isActive = false
        cardHeightConstraint = heightAnchor.constraint(equalToConstant: layoutHeight)
        cardHeightConstraint?.priority = .defaultHigh
        cardHeightConstraint?.isActive = true
        invalidateIntrinsicContentSize()
    }

    private func makeThumb(path: String, invalid: Bool) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOfFile: path)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 2
        imageView.layer?.borderWidth = invalid ? 2 : 1
        imageView.layer?.borderColor = (invalid ? NSColor.systemRed : NSColor(colors.defaultBorder)).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: JobQueueLayout.thumbSize).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: JobQueueLayout.thumbSize).isActive = true
        return imageView
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        clickCount = event.clickCount
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 || clickCount >= 2 {
            onEdit?()
            return
        }
        let current = event.locationInWindow
        let dx = current.x - mouseDownLocation.x
        let dy = current.y - mouseDownLocation.y
        if (dx * dx + dy * dy) <= 16 {
            onSelect?()
        }
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
    var containerWidth: CGFloat = 260

    func makeNSView(context: Context) -> JobQueuePanelNSView {
        let view = JobQueuePanelNSView()
        view.applyTheme(appState.theme.colors)
        view.onReorder = { jobID, beforeID in
            appState.imageGen.moveJob(before: beforeID, jobID: jobID)
        }
        view.onEdit = { jobID in
            appState.openImageGenDialog(replaceJobID: jobID)
        }
        view.onCancel = { jobID, cascade in
            appState.confirmCancelJob(id: jobID, cascade: cascade)
        }
        view.onSelect = { jobID in
            appState.imageGen.selectJob(id: jobID)
        }
        view.onAddSeries = { delta, option in
            appState.imageGen.addActiveSeriesCycle(delta: option ? 50 : delta)
        }
        view.onSubtractSeries = { delta, option in
            appState.imageGen.subtractActiveSeriesRemaining(delta: delta, removeAll: option)
        }
        view.actionBarStateProvider = { jobID in
            appState.imageGen.actionBarState(for: jobID)
        }
        view.onToggleImageRefinement = { jobID, enabled in
            appState.imageGen.setSeriesRefinement(for: jobID, image: enabled, text: nil)
        }
        view.onToggleTextRefinement = { jobID, enabled in
            appState.imageGen.setSeriesRefinement(for: jobID, image: nil, text: enabled)
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: JobQueuePanelNSView, context: Context) {
        context.coordinator.revision = appState.imageGen.queueRevision
        let controller = appState.imageGen
        let mode = appState.jobsQueueSizeMode
        let rows: [QueueRowSnapshot]
        switch mode {
        case .all:
            rows = controller.queueSnapshot()
        case .one:
            rows = controller.queueSnapshot().prefix(1).map { $0 }
        case .strip:
            rows = []
        }
        nsView.applyTheme(appState.theme.colors)
        let scrollWidth = max(containerWidth, nsView.bounds.width, 260)
        nsView.containerWidth = scrollWidth
        nsView.updateRows(rows, selectedJobID: controller.selectedJobID, scrollWidth: scrollWidth)
        scheduleMeasuredGeometryReport(nsView: nsView, appState: appState, mode: mode)
    }

    private func scheduleMeasuredGeometryReport(
        nsView: JobQueuePanelNSView,
        appState: AppState,
        mode: JobsQueueSizeMode
    ) {
        DispatchQueue.main.async {
            reportMeasuredGeometry(nsView: nsView, appState: appState, mode: mode)
        }
    }

    @MainActor
    private func reportMeasuredGeometry(
        nsView: JobQueuePanelNSView,
        appState: AppState,
        mode: JobsQueueSizeMode
    ) {
        let cardHeight: CGFloat
        switch mode {
        case .strip:
            cardHeight = 0
        case .one:
            cardHeight = nsView.measuredFirstCardHeight()
        case .all:
            cardHeight = nsView.measuredCardStackHeight()
        }
        appState.updateMeasuredJobsQueueGeometry(cardStackHeight: cardHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: JobQueuePanelNSView?
        var revision = 0
    }
}
