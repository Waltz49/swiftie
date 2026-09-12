import AppKit
import SwiftUI

// AppKit requires a reverse-DNS UTI (Qt MIME "application/x-prowser-job-queue-id" is invalid here).
private let jobQueueDragType = NSPasteboard.PasteboardType("com.prowser.job-queue-id")

let jobsPaneDebugEnabled = ProcessInfo.processInfo.environment["PROWSER_JOBS_PANE_DEBUG"] == "1"
func jobsPaneDebug(_ message: @autoclosure () -> String) {
    guard jobsPaneDebugEnabled else { return }
    print("[jobs-pane] \(message())")
}

@MainActor
final class JobQueuePanelNSView: NSView, NSDraggingSource {
    var onReorder: ((String, String?) -> Void)?
    var onEdit: ((String) -> Void)?
    var onCancel: ((String, Bool) -> Void)?
    var onSelect: ((String?) -> Void)?
    var onOpenReferences: (([String]) -> Void)?
    /// Card heights changed after a width reflow; the measured pane geometry must be re-reported.
    var onCardGeometryChanged: (() -> Void)?
    var onAddSeries: ((Int, Bool) -> Void)?
    var onSubtractSeries: ((Int, Bool) -> Void)?
    var onToggleImageRefinement: ((String, Bool) -> Void)?
    var onToggleTextRefinement: ((String, Bool) -> Void)?
    var actionBarStateProvider: ((String) -> JobQueueActionBarState)?
    var onActionBarEmbedded: ((CGFloat) -> Void)?

    var themeColors: ThemeColors = .dark
    var selectedJobID: String?

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let stackView = NSStackView()
    private var cardViews: [JobCardNSView] = []
    private var cardPool: [JobCardNSView] = []
    private var dropLine = NSView()
    private var rows: [QueueRowSnapshot] = []
    private var dragJobID: String?
    private var pendingDropInsertIndex: Int?
    private var reorderApplied = false
    private var autoScrollTimer: Timer?
    private var lastConfiguredScrollWidth: CGFloat = 0
    private var pendingScrollWidth: CGFloat?
    private var scrollWidthReconfigureScheduled = false
    private var actionBarEmbeddedOnCard = false
    private let sharedActionBar = JobQueueActionBarNSView()
    var paneContextMenuKind: SidebarPaneContextMenuKind?
    weak var paneContextMenuAppState: AppState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([jobQueueDragType])
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
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
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(point), hit !== self {
            super.rightMouseDown(with: event)
            return
        }
        guard let paneContextMenuAppState, let paneContextMenuKind else {
            super.rightMouseDown(with: event)
            return
        }
        SidebarPaneContextMenus.show(
            kind: paneContextMenuKind,
            for: event,
            in: self,
            appState: paneContextMenuAppState
        )
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

        preserveScrollPosition {
            if rows.isEmpty {
                parkAllCards()
            } else if cardsAlignWithSnapshot(rows) {
                refreshAlignedRows(rows, selectedJobID: selectedJobID, scrollWidth: scrollWidth)
            } else {
                rebuildRows(rows, selectedJobID: selectedJobID, scrollWidth: scrollWidth)
            }
            updateDocumentHeight()
        }
        invalidateIntrinsicContentSize()
    }

    private func cardsAlignWithSnapshot(_ rows: [QueueRowSnapshot]) -> Bool {
        guard rows.count == cardViews.count else { return false }
        for (card, row) in zip(cardViews, rows) {
            if card.boundJobID != row.jobID { return false }
        }
        return true
    }

    private func refreshAlignedRows(
        _ rows: [QueueRowSnapshot],
        selectedJobID: String?,
        scrollWidth: CGFloat
    ) {
        var selectedCard: JobCardNSView?
        for (index, row) in rows.enumerated() {
            let card = cardViews[index]
            let isSelected = row.jobID == selectedJobID
            wireCardCallbacks(card, row: row)
            card.configure(
                row: row,
                index: index,
                scrollWidth: scrollWidth,
                selected: isSelected,
                colors: themeColors,
                skipUnchanged: !row.isActive
            )
            if isSelected { selectedCard = card }
        }
        attachActionBar(to: selectedCard)
        refreshActionBarState()
    }

    private func rebuildRows(
        _ rows: [QueueRowSnapshot],
        selectedJobID: String?,
        scrollWidth: CGFloat
    ) {
        var lookup: [String: JobCardNSView] = [:]
        for card in cardPool where !card.boundJobID.isEmpty {
            lookup[card.boundJobID] = card
        }
        for card in cardViews where !card.boundJobID.isEmpty {
            lookup[card.boundJobID] = card
        }

        let previousCards = cardViews
        var nextCards: [JobCardNSView] = []
        var selectedCard: JobCardNSView?

        for (index, row) in rows.enumerated() {
            let card = lookup[row.jobID] ?? takePooledCard()
            if let poolIndex = cardPool.firstIndex(where: { $0 === card }) {
                cardPool.remove(at: poolIndex)
            }
            let isSelected = row.jobID == selectedJobID
            wireCardCallbacks(card, row: row)
            card.configure(
                row: row,
                index: index,
                scrollWidth: scrollWidth,
                selected: isSelected,
                colors: themeColors,
                skipUnchanged: false
            )
            nextCards.append(card)
            if isSelected { selectedCard = card }
        }

        cardViews = nextCards
        reorderCardsInStack(nextCards)
        let activeIDs = Set(nextCards.map { ObjectIdentifier($0) })
        for card in previousCards where !activeIDs.contains(ObjectIdentifier(card)) {
            // reorderCardsInStack already detached these; only return to pool.
            poolCard(card)
        }
        attachActionBar(to: selectedCard)
        refreshActionBarState()
    }

    private func wireCardCallbacks(_ card: JobCardNSView, row: QueueRowSnapshot) {
        card.onEdit = { [weak self] in self?.onEdit?(row.jobID) }
        card.onCancel = { [weak self] cascade in self?.onCancel?(row.jobID, cascade) }
        card.onSelect = { [weak self] in self?.onSelect?(row.jobID) }
        card.onOpenReferences = { [weak self] paths in self?.onOpenReferences?(paths) }
    }

    private func takePooledCard() -> JobCardNSView {
        if let card = cardPool.popLast() {
            return card
        }
        let card = makeJobCard()
        return card
    }

    private func makeJobCard() -> JobCardNSView {
        let card = JobCardNSView()
        card.onBeginDrag = { [weak self] jobID, event in
            guard let self else { return }
            let source = self.cardViews.first(where: { $0.boundJobID == jobID }) ?? card
            self.beginDrag(jobID: jobID, event: event, from: source)
        }
        return card
    }

    private func parkCard(_ card: JobCardNSView) {
        if stackView.arrangedSubviews.contains(where: { $0 === card }) {
            stackView.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        poolCard(card)
    }

    private func poolCard(_ card: JobCardNSView) {
        if !cardPool.contains(where: { $0 === card }) {
            cardPool.append(card)
        }
    }

    private func parkAllCards() {
        for card in cardViews {
            parkCard(card)
        }
        cardViews.removeAll()
        attachActionBar(to: nil)
        refreshActionBarState()
    }

    private func reorderCardsInStack(_ cards: [JobCardNSView]) {
        for card in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        for card in cards {
            stackView.addArrangedSubview(card)
            card.attachStackWidthConstraint(stackView.widthAnchor)
        }
    }

    private func preserveScrollPosition(around work: () -> Void) {
        let clipView = scrollView.contentView
        let visibleOrigin = scrollView.documentVisibleRect.origin
        work()
        let clipHeight = clipView.bounds.height
        let maxY = max(0, documentView.frame.height - clipHeight)
        let restoredY = min(max(visibleOrigin.y, 0), maxY)
        clipView.scroll(to: NSPoint(x: visibleOrigin.x, y: restoredY))
        scrollView.reflectScrolledClipView(clipView)
    }

    var fittingContentHeight: CGFloat {
        stackView.layoutSubtreeIfNeeded()
        return max(stackView.fittingSize.height + 8, 40)
    }

    var documentFrameForDebug: NSRect { documentView.frame }
    var lastConfiguredScrollWidthForDebug: CGFloat { lastConfiguredScrollWidth }
    var cardLayoutHeightsForDebug: [CGFloat] {
        cardViews.prefix(rows.count).map { $0.layoutHeight }
    }

    var displayedRowCount: Int { rows.count }

    /// Cards laid out before the panel had real bounds (80px text width): heights are inflated
    /// and must not drive pane sizing; ``layout()`` reflows them once the width is known.
    var isLaidOutAtPlaceholderWidth: Bool {
        !rows.isEmpty && lastConfiguredScrollWidth <= 1
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
        bounds.width > 1 ? bounds.width : max(lastConfiguredScrollWidth, 1)
    }

    /// Coalesces per-frame width changes into one card reconfigure (avoids CoreText relayout storms).
    private func scheduleReconfigureForScrollWidth(_ scrollWidth: CGFloat) {
        guard abs(lastConfiguredScrollWidth - scrollWidth) > 0.5, !rows.isEmpty else { return }
        pendingScrollWidth = scrollWidth
        guard !scrollWidthReconfigureScheduled else { return }
        scrollWidthReconfigureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scrollWidthReconfigureScheduled = false
            guard let width = pendingScrollWidth else { return }
            pendingScrollWidth = nil
            reconfigureRowsForScrollWidth(width)
        }
    }

    private func reconfigureRowsForScrollWidth(_ scrollWidth: CGFloat) {
        guard abs(lastConfiguredScrollWidth - scrollWidth) > 0.5, !rows.isEmpty else { return }
        jobsPaneDebug("reconfigure width \(lastConfiguredScrollWidth) -> \(scrollWidth) cardsBefore=\(cardLayoutHeightsForDebug)")
        preserveScrollPosition {
            for (index, row) in rows.enumerated() {
                let card = cardViews[index]
                let isSelected = row.jobID == selectedJobID
                card.applyScrollWidth(
                    scrollWidth,
                    row: row,
                    index: index,
                    selected: isSelected,
                    colors: themeColors
                )
            }
            refreshActionBarState()
            lastConfiguredScrollWidth = scrollWidth
            updateDocumentHeight()
        }
        onCardGeometryChanged?()
    }

    private func updateDocumentHeight() {
        stackView.layoutSubtreeIfNeeded()
        let measured = measuredCardStackHeight()
        let contentHeight = max(measured > 0 ? measured : fittingContentHeight, 40)
        let width = effectiveScrollWidth()
        guard abs(documentView.frame.width - width) > 0.5
            || abs(documentView.frame.height - contentHeight) > 1 else { return }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        stackView.layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let width = effectiveScrollWidth()
        jobsPaneDebug(
            "layout bounds=\(bounds) inWindow=\(window == nil ? "nil" : "\(convert(bounds, to: nil))") "
            + "visible=\(scrollView.documentVisibleRect) doc=\(documentView.frame) stack=\(stackView.frame) "
            + "firstCard=\(cardViews.first.map { "\($0.frame) hidden=\($0.isHiddenOrHasHiddenAncestor)" } ?? "none") "
            + "windowH=\(window?.frame.height ?? -1)"
        )
        if abs(lastConfiguredScrollWidth - width) > 0.5, !rows.isEmpty {
            scheduleReconfigureForScrollWidth(width)
            return
        }
        guard abs(documentView.frame.width - width) > 0.5 else { return }
        preserveScrollPosition {
            updateDocumentHeight()
        }
    }

    private func attachActionBar(to card: JobCardNSView?) {
        let wasEmbedded = actionBarEmbeddedOnCard
        for existingCard in cardViews {
            existingCard.detachActionBar()
        }
        sharedActionBar.isHidden = card == nil
        guard let card else {
            actionBarEmbeddedOnCard = false
            return
        }
        card.attachActionBar(sharedActionBar)
        sharedActionBar.applyTheme(themeColors)
        refreshActionBarState()
        updateDocumentHeight()
        actionBarEmbeddedOnCard = true
        if !wasEmbedded {
            let growth = card.embeddedActionBarGrowthHeight()
            if growth > 0 {
                onActionBarEmbedded?(growth)
            }
        }
    }

    private func refreshActionBarState() {
        guard let selectedJobID, let actionBarStateProvider else {
            sharedActionBar.configure(state: .empty)
            return
        }
        sharedActionBar.configure(state: actionBarStateProvider(selectedJobID))
    }


    private func beginDrag(jobID: String, event: NSEvent, from card: JobCardNSView) {
        dragJobID = jobID
        reorderApplied = false
        pendingDropInsertIndex = nil
        let item = NSPasteboardItem()
        item.setString(jobID, forType: jobQueueDragType)
        let preview = card.compactDragSnapshot()
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(
            NSRect(origin: .zero, size: preview.size),
            contents: preview
        )
        beginDraggingSession(with: [dragging], event: event, source: self)
        startAutoScroll()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLine.isHidden = true
        pendingDropInsertIndex = nil
        stopAutoScroll()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.string(forType: jobQueueDragType) != nil else { return false }
        applyReorder(at: panelPoint(from: sender))
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        stopAutoScroll()
        dropLine.isHidden = true
        defer {
            dragJobID = nil
            pendingDropInsertIndex = nil
            reorderApplied = false
        }
        guard !reorderApplied, dragJobID != nil, let window else { return }
        let panelPoint = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard scrollView.frame.contains(panelPoint) else { return }
        applyReorder(at: panelPoint)
    }

    private func panelPoint(from draggingInfo: NSDraggingInfo) -> NSPoint {
        convert(draggingInfo.draggingLocation, from: nil)
    }

    /// Display insert index before ``rows[index]`` (or end when index == rows.count).
    private func insertIndex(forPointInPanel point: NSPoint) -> Int {
        stackView.layoutSubtreeIfNeeded()
        let localY = stackView.convert(point, from: self).y
        let visibleCount = min(cardViews.count, rows.count)
        for index in 0..<visibleCount {
            if localY < cardViews[index].frame.midY {
                return index
            }
        }
        return visibleCount
    }

    private func beforeJobID(forInsertIndex insertIndex: Int) -> String? {
        guard insertIndex < rows.count else { return nil }
        return rows[insertIndex].jobID
    }

    private func dropLineFrame(forInsertIndex insertIndex: Int) -> NSRect {
        stackView.layoutSubtreeIfNeeded()
        let spacing = JobQueueLayout.listSpacing
        let marginX: CGFloat = 4
        let width = max(1, documentView.bounds.width - marginX * 2)
        let visibleCount = min(cardViews.count, rows.count)

        let gapY: CGFloat
        if visibleCount == 0 {
            gapY = 4
        } else if insertIndex <= 0 {
            gapY = cardViews[0].frame.minY - max(1, spacing / 2)
        } else if insertIndex >= visibleCount {
            gapY = cardViews[visibleCount - 1].frame.maxY + max(1, spacing / 2)
        } else {
            gapY = cardViews[insertIndex].frame.minY - max(1, spacing / 2)
        }

        let stackOrigin = stackView.convert(NSPoint.zero, to: documentView)
        return NSRect(x: marginX, y: stackOrigin.y + gapY, width: width, height: 2)
    }

    private func updateDropIndicator(for draggingInfo: NSDraggingInfo) {
        let insertIndex = insertIndex(forPointInPanel: panelPoint(from: draggingInfo))
        pendingDropInsertIndex = insertIndex
        dropLine.isHidden = false
        dropLine.layer?.backgroundColor = NSColor(themeColors.jobQueueSelectionBorder).cgColor
        dropLine.frame = dropLineFrame(forInsertIndex: insertIndex)
    }

    private func applyReorder(at panelPoint: NSPoint) {
        guard !reorderApplied, let jobID = dragJobID else { return }
        let insertIndex = pendingDropInsertIndex ?? insertIndex(forPointInPanel: panelPoint)
        let beforeID = beforeJobID(forInsertIndex: insertIndex)
        if beforeID == jobID { return }
        reorderApplied = true
        stopAutoScroll()
        dropLine.isHidden = true
        onReorder?(jobID, beforeID)
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
    var onOpenReferences: (([String]) -> Void)?

    private let backgroundView = NSView()
    private let contentView = NSView()
    private let statusWidget = JobCardStatusNSView()
    private let refsView = JobReferenceThumbsNSView()
    private var refsWidthConstraint: NSLayoutConstraint?
    private var refsHeightConstraint: NSLayoutConstraint?
    private let mainRow = NSStackView()
    private let column = NSStackView()
    private(set) var boundJobID = ""
    private var mouseDownLocation: NSPoint = .zero
    private var clickCount = 0
    private var colors: ThemeColors = .dark
    private var actionBarContainer: NSView?
    private var statusWidthConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?
    private var contentFillsCardBottomConstraint: NSLayoutConstraint?
    private var actionBarTopConstraint: NSLayoutConstraint?
    private var actionBarLeadingConstraint: NSLayoutConstraint?
    private var actionBarTrailingConstraint: NSLayoutConstraint?
    private var actionBarBottomConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?
    private var lastViewFingerprint = ""
    private var lastScrollWidth: CGFloat = 0
    private var lastThumbnailPaths: [String] = []
    private var lastReferencesInvalid = false
    private var lastInlineRefs = false
    private var lastHasBelowRefs = false
    private var lastSelected = false
    private var lastActive = false
    private(set) var layoutHeight: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = JobQueueLayout.cardCornerRadius
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        statusWidget.translatesAutoresizingMaskIntoConstraints = false
        refsView.onOpenPaths = { [weak self] paths in self?.onOpenReferences?(paths) }

        // Python inline layout: HBox margins (0, 0, 2, 0), spacing 4; refs top-right.
        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = JobQueueLayout.inlineTextRefsSpacing
        mainRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: JobQueueLayout.inlineRefsRightPadding)
        mainRow.distribution = .fill
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        mainRow.addArrangedSubview(statusWidget)
        statusWidget.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusWidget.setContentCompressionResistancePriority(.required, for: .horizontal)
        refsView.setContentHuggingPriority(.required, for: .horizontal)
        refsView.setContentCompressionResistancePriority(.required, for: .horizontal)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = JobQueueLayout.cardInnerSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(mainRow)

        contentView.addSubview(column)
        addSubview(backgroundView)
        addSubview(contentView)

        let margin = JobQueueLayout.cardOuterMargin
        contentFillsCardBottomConstraint = contentView.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -margin
        )
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        contentFillsCardBottomConstraint?.isActive = true
        statusWidget.setContentCompressionResistancePriority(.required, for: .vertical)
        column.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        self.colors = colors
        statusWidget.applyTheme(colors)
        refsView.applyTheme(colors)
    }

    func attachStackWidthConstraint(_ stackWidthAnchor: NSLayoutDimension) {
        if stackWidthConstraint == nil {
            stackWidthConstraint = widthAnchor.constraint(equalTo: stackWidthAnchor)
            stackWidthConstraint?.isActive = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: layoutHeight)
    }

    func applyScrollWidth(
        _ scrollWidth: CGFloat,
        row: QueueRowSnapshot,
        index: Int,
        selected: Bool,
        colors: ThemeColors
    ) {
        let contentWidth = max(80, scrollWidth - JobQueueLayout.cardContentMargin)
        let refs = row.thumbnailPaths
        let useInline = Self.useInlineRefs(
            scrollWidth: scrollWidth,
            paths: refs,
            referencesInvalid: row.referencesInvalid
        )
        if useInline != lastInlineRefs
            || refs != lastThumbnailPaths
            || row.referencesInvalid != lastReferencesInvalid {
            configure(
                row: row,
                index: index,
                scrollWidth: scrollWidth,
                selected: selected,
                colors: colors,
                skipUnchanged: false
            )
            return
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
        let fingerprint = "\(textWidth)|\(statusView.fingerprint())"
        let widthChanged = scrollWidth != lastScrollWidth
        lastScrollWidth = scrollWidth
        if fingerprint == lastViewFingerprint {
            if widthChanged, lastHasBelowRefs {
                // Below-status thumbs re-wrap to the new width (Python ``_reflow_visible_refs``).
                layoutRefs(contentWidth: contentWidth, inline: useInline)
                syncCardHeight(inlineRefs: useInline, hasBelowRefs: lastHasBelowRefs)
            }
            updateChrome(selected: selected, running: row.isActive)
            return
        }

        statusWidthConstraint?.isActive = false
        statusWidthConstraint = statusWidget.widthAnchor.constraint(equalToConstant: textWidth)
        statusWidthConstraint?.priority = .required
        statusWidthConstraint?.isActive = true
        statusWidget.setStatusView(statusView, contentWidth: textWidth)
        lastViewFingerprint = fingerprint
        layoutRefs(contentWidth: contentWidth, inline: useInline)
        syncCardHeight(inlineRefs: useInline, hasBelowRefs: lastHasBelowRefs)
        updateChrome(selected: selected, running: row.isActive)
        invalidateIntrinsicContentSize()
    }

    /// Python ``JobCard._use_inline_refs_layout``: wide pane and 1–2 (valid) references.
    private static func useInlineRefs(scrollWidth: CGFloat, paths: [String], referencesInvalid: Bool) -> Bool {
        let count = JobReferenceThumbsNSView.cellCount(paths: paths, referencesInvalid: referencesInvalid)
        return scrollWidth > JobQueueLayout.inlineRefsMinScrollWidth && count >= 1 && count <= 2
    }

    /// Place the reference thumbs beside (single column) or below (wrapping rows) the status.
    private func layoutRefs(contentWidth: CGFloat, inline: Bool) {
        refsWidthConstraint?.isActive = false
        refsHeightConstraint?.isActive = false
        guard refsView.cellCount > 0 else {
            refsView.removeFromSuperview()
            refsView.isHidden = true
            return
        }
        refsView.isHidden = false
        let width: CGFloat
        if inline {
            refsView.setForcedColumns(1)
            width = JobQueueLayout.thumbSize
            if refsView.superview !== mainRow {
                refsView.removeFromSuperview()
                mainRow.addArrangedSubview(refsView)
            }
        } else {
            refsView.setForcedColumns(nil)
            width = max(JobQueueLayout.thumbSize, contentWidth)
            if refsView.superview !== column {
                refsView.removeFromSuperview()
                column.addArrangedSubview(refsView)
            }
        }
        refsWidthConstraint = refsView.widthAnchor.constraint(equalToConstant: width)
        refsHeightConstraint = refsView.heightAnchor.constraint(
            equalToConstant: refsView.contentHeight(forWidth: width)
        )
        refsWidthConstraint?.isActive = true
        refsHeightConstraint?.isActive = true
        refsView.needsLayout = true
    }

    func configure(
        row: QueueRowSnapshot,
        index: Int,
        scrollWidth: CGFloat,
        selected: Bool,
        colors: ThemeColors,
        skipUnchanged: Bool = false
    ) {
        boundJobID = row.jobID
        self.colors = colors

        if skipUnchanged, rowContentUnchanged(row: row, scrollWidth: scrollWidth, selected: selected) {
            updateChrome(selected: selected, running: row.isActive)
            return
        }

        applyTheme(colors)

        let contentWidth = max(80, scrollWidth - JobQueueLayout.cardContentMargin)
        let refs = row.thumbnailPaths
        refsView.configure(paths: refs, referencesInvalid: row.referencesInvalid, colors: colors)
        let useInline = Self.useInlineRefs(
            scrollWidth: scrollWidth,
            paths: refs,
            referencesInvalid: row.referencesInvalid
        )
        layoutRefs(contentWidth: contentWidth, inline: useInline)
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
        lastHasBelowRefs = !useInline && refsView.cellCount > 0
        syncCardHeight(inlineRefs: useInline, hasBelowRefs: lastHasBelowRefs)

        lastViewFingerprint = "\(textWidth)|\(statusView.fingerprint())"
        lastScrollWidth = scrollWidth
        lastThumbnailPaths = refs
        lastReferencesInvalid = row.referencesInvalid
        lastInlineRefs = useInline
        lastSelected = selected
        lastActive = row.isActive
        updateChrome(selected: selected, running: row.isActive)
        invalidateIntrinsicContentSize()
    }

    private func rowContentUnchanged(
        row: QueueRowSnapshot,
        scrollWidth: CGFloat,
        selected: Bool
    ) -> Bool {
        guard boundJobID == row.jobID else { return false }
        let contentWidth = max(80, scrollWidth - JobQueueLayout.cardContentMargin)
        let refs = row.thumbnailPaths
        let useInline = Self.useInlineRefs(
            scrollWidth: scrollWidth,
            paths: refs,
            referencesInvalid: row.referencesInvalid
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
        let textWidth = Self.statusTextWidth(
            contentWidth: contentWidth,
            scrollWidth: scrollWidth,
            inlineRefs: useInline
        )
        let fingerprint = "\(textWidth)|\(statusView.fingerprint())"
        if fingerprint != lastViewFingerprint { return false }
        if scrollWidth != lastScrollWidth { return false }
        if refs != lastThumbnailPaths { return false }
        if row.referencesInvalid != lastReferencesInvalid { return false }
        if useInline != lastInlineRefs { return false }
        if selected != lastSelected { return false }
        if row.isActive != lastActive { return false }
        return true
    }

    private func updateChrome(selected: Bool, running: Bool) {
        let bg = running ? colors.jobQueueRunningCellBackground : colors.jobQueueCellBackground
        backgroundView.layer?.backgroundColor = NSColor(bg).cgColor
        if selected {
            backgroundView.layer?.borderWidth = CGFloat(colors.currentImageBorderWidth)
            backgroundView.layer?.borderColor = NSColor(colors.jobQueueSelectionBorder).cgColor
        } else {
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
        }
        lastSelected = selected
        lastActive = running
    }

    func attachActionBar(_ bar: NSView) {
        if actionBarContainer === bar, bar.superview === self {
            bar.isHidden = false
            updateActionBarLayoutConstraints()
            resyncHeightAfterActionBarChange()
            return
        }
        detachActionBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = false
        addSubview(bar, positioned: .above, relativeTo: contentView)
        actionBarContainer = bar
        updateActionBarLayoutConstraints()
        resyncHeightAfterActionBarChange()
    }

    func detachActionBar() {
        guard let bar = actionBarContainer else { return }
        actionBarTopConstraint?.isActive = false
        actionBarLeadingConstraint?.isActive = false
        actionBarTrailingConstraint?.isActive = false
        actionBarBottomConstraint?.isActive = false
        bar.removeFromSuperview()
        actionBarContainer = nil
        updateActionBarLayoutConstraints()
        resyncHeightAfterActionBarChange()
    }

    private func updateActionBarLayoutConstraints() {
        let margin = JobQueueLayout.cardOuterMargin
        let spacing = JobQueueLayout.cardInnerSpacing
        if let bar = actionBarContainer, !bar.isHidden {
            contentFillsCardBottomConstraint?.isActive = false
            if actionBarTopConstraint == nil {
                actionBarLeadingConstraint = bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin)
                actionBarTrailingConstraint = bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin)
                actionBarTopConstraint = bar.topAnchor.constraint(equalTo: contentView.bottomAnchor, constant: spacing)
                actionBarBottomConstraint = bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin)
            }
            actionBarLeadingConstraint?.isActive = true
            actionBarTrailingConstraint?.isActive = true
            actionBarTopConstraint?.isActive = true
            actionBarBottomConstraint?.isActive = true
        } else {
            actionBarTopConstraint?.isActive = false
            actionBarLeadingConstraint?.isActive = false
            actionBarTrailingConstraint?.isActive = false
            actionBarBottomConstraint?.isActive = false
            contentFillsCardBottomConstraint?.isActive = true
        }
    }

    private func resyncHeightAfterActionBarChange() {
        syncCardHeight(inlineRefs: lastInlineRefs, hasBelowRefs: lastHasBelowRefs)
    }

    func embeddedActionBarGrowthHeight() -> CGFloat {
        actionBarBlockHeight()
    }

    private func actionBarBlockHeight() -> CGFloat {
        guard let bar = actionBarContainer, !bar.isHidden else { return 0 }
        bar.layoutSubtreeIfNeeded()
        let measured = bar.fittingSize.height
        let barHeight = measured > 0 ? measured : JobQueueLayout.actionBarHeight
        return JobQueueLayout.cardInnerSpacing + barHeight
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
        column.layoutSubtreeIfNeeded()
        let statusH = statusWidget.intrinsicContentSize.height
        let refsH: CGFloat
        if refsView.cellCount > 0, inlineRefs || hasBelowRefs {
            refsH = refsHeightConstraint?.constant ?? JobQueueLayout.thumbSize
        } else {
            refsH = 0
        }
        // Python ``_sync_card_height``: inline → max(status, refs) + 2; below → status + refs + 2.
        let estimatedContentH = inlineRefs ? max(statusH, refsH) + 2 : statusH + refsH + 2
        let contentH = max(ceil(column.fittingSize.height), estimatedContentH, 1)

        contentHeightConstraint?.isActive = false
        contentHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: contentH)
        contentHeightConstraint?.priority = .required
        contentHeightConstraint?.isActive = true

        let frameH = JobQueueLayout.cardOuterMargin * 2 + contentH + actionBarBlockHeight()
        layoutHeight = max(frameH, 40)
        cardHeightConstraint?.isActive = false
        cardHeightConstraint = heightAnchor.constraint(equalToConstant: layoutHeight)
        cardHeightConstraint?.priority = .required
        cardHeightConstraint?.isActive = true
        updateActionBarLayoutConstraints()
        invalidateIntrinsicContentSize()
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
            onBeginDrag?(boundJobID, event)
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

    /// Compact status-row preview for internal queue reorder drags.
    func compactDragSnapshot() -> NSImage {
        statusWidget.layoutSubtreeIfNeeded()
        let statusBounds = statusWidget.bounds
        guard statusBounds.width > 1, statusBounds.height > 1 else {
            return snapshotImage()
        }

        let maxWidth: CGFloat = 200
        let maxHeight: CGFloat = 30
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let contentW = min(statusBounds.width, maxWidth - padX * 2)
        let contentH = min(statusBounds.height, maxHeight - padY * 2)
        let size = NSSize(width: contentW + padX * 2, height: contentH + padY * 2)

        let rep = statusWidget.bitmapImageRepForCachingDisplay(in: statusBounds)!
        statusWidget.cacheDisplay(in: statusBounds, to: rep)
        let statusImage = NSImage(size: statusBounds.size)
        statusImage.addRepresentation(rep)

        let preview = NSImage(size: size)
        preview.lockFocus()
        NSColor(colors.jobQueueCellBackground).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        let drawRect = NSRect(
            x: padX,
            y: padY + max(0, (contentH - statusBounds.height) / 2),
            width: contentW,
            height: min(statusBounds.height, contentH)
        )
        statusImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        preview.unlockFocus()
        return preview
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool { false }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct JobQueuePanelNSViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    var compactForFloating: Bool = false
    var fillsAvailableHeight: Bool = false

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: JobQueuePanelNSView, context: Context) -> CGSize? {
        let width = resolvedLayoutWidth(proposal: proposal, panel: nsView)
        let height: CGFloat
        if fillsAvailableHeight {
            height = max(proposal.height ?? nsView.bounds.height, 40)
        } else if nsView.isLaidOutAtPlaceholderWidth {
            // Inflated placeholder-width layout; use the last real measurement until the reflow lands.
            height = max(appState.measuredJobsCardStackHeight, 40)
        } else {
            height = max(measuredQueueHeight(panel: nsView, mode: appState.jobsQueueSizeMode), 40)
        }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> JobQueuePanelNSView {
        let panel = JobQueuePanelNSView()
        configurePanel(panel, context: context)
        context.coordinator.panel = panel
        return panel
    }

    func updateNSView(_ panel: JobQueuePanelNSView, context: Context) {
        let uiRevision = appState.imageGenUIRevision
        let dataChanged = context.coordinator.revision != uiRevision
        context.coordinator.revision = uiRevision
        panel.paneContextMenuKind = compactForFloating ? .jobs(floating: true) : .jobs(floating: false)
        panel.paneContextMenuAppState = appState
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
        panel.applyTheme(appState.theme.colors)
        if dataChanged {
            let scrollWidth = resolvedLayoutWidth(proposal: nil, panel: panel)
            panel.updateRows(rows, selectedJobID: controller.selectedJobID, scrollWidth: scrollWidth)
        }
        scheduleMeasuredGeometryReport(panel: panel, appState: appState, mode: mode)
    }

    @MainActor
    private func configurePanel(_ panel: JobQueuePanelNSView, context: Context) {
        panel.paneContextMenuKind = compactForFloating ? .jobs(floating: true) : .jobs(floating: false)
        panel.paneContextMenuAppState = appState
        panel.applyTheme(appState.theme.colors)
        panel.onReorder = { jobID, beforeID in
            appState.imageGen.moveJob(before: beforeID, jobID: jobID)
        }
        panel.onEdit = { jobID in
            appState.openImageGenDialog(replaceJobID: jobID)
        }
        panel.onCancel = { jobID, cascade in
            appState.confirmCancelJob(id: jobID, cascade: cascade)
        }
        panel.onSelect = { jobID in
            appState.imageGen.selectJob(id: jobID)
        }
        panel.onOpenReferences = { paths in
            // Python ``open_reference_thumbnail_paths``: one image → browse; several → custom-sort level.
            if paths.count == 1 {
                appState.openImageInBrowse(path: paths[0])
            } else {
                appState.openReferencePaths(paths, focusPath: nil)
            }
        }
        panel.onCardGeometryChanged = { [weak panel] in
            guard let panel else { return }
            scheduleMeasuredGeometryReport(panel: panel, appState: appState, mode: appState.jobsQueueSizeMode)
        }
        panel.onAddSeries = { delta, option in
            appState.imageGen.addActiveSeriesCycle(delta: option ? 50 : delta)
        }
        panel.onSubtractSeries = { delta, option in
            appState.imageGen.subtractActiveSeriesRemaining(delta: delta, removeAll: option)
        }
        panel.actionBarStateProvider = { jobID in
            appState.imageGen.actionBarState(for: jobID)
        }
        panel.onActionBarEmbedded = { extra in
            appState.growJobsPaneForActionBar(extra: extra)
        }
        panel.onToggleImageRefinement = { jobID, enabled in
            appState.imageGen.setSeriesRefinement(for: jobID, image: enabled, text: nil)
        }
        panel.onToggleTextRefinement = { jobID, enabled in
            appState.imageGen.setSeriesRefinement(for: jobID, image: nil, text: enabled)
        }
    }

    private func scheduleMeasuredGeometryReport(
        panel: JobQueuePanelNSView,
        appState: AppState,
        mode: JobsQueueSizeMode
    ) {
        DispatchQueue.main.async {
            reportMeasuredGeometry(panel: panel, appState: appState, mode: mode)
        }
    }

    @MainActor
    private func reportMeasuredGeometry(
        panel: JobQueuePanelNSView,
        appState: AppState,
        mode: JobsQueueSizeMode
    ) {
        // Python measures after ``card.reflow_layout(info_w, width)`` at the live viewport width;
        // skip snapshots taken before the panel has real bounds (``layout()`` reflows and re-reports).
        if mode != .strip, panel.isLaidOutAtPlaceholderWidth {
            jobsPaneDebug("report skipped (placeholder width) mode=\(mode) cards=\(panel.cardLayoutHeightsForDebug)")
            return
        }
        // A panel that still shows the previous mode's rows (e.g. ONE → ALL before the new
        // hierarchy is built) would report the wrong stack.
        let snapshotCount = appState.imageGen.queueSnapshot().count
        let expectedRows = mode == .one ? min(1, snapshotCount) : snapshotCount
        if mode != .strip, panel.displayedRowCount != expectedRows {
            jobsPaneDebug("report skipped (rows \(panel.displayedRowCount) != \(expectedRows)) mode=\(mode)")
            return
        }
        let cardHeight: CGFloat
        switch mode {
        case .strip:
            cardHeight = 0
        case .one:
            cardHeight = panel.measuredFirstCardHeight()
        case .all:
            cardHeight = panel.measuredCardStackHeight()
        }
        jobsPaneDebug(
            "report mode=\(mode) cardHeight=\(cardHeight) panelBounds=\(panel.bounds.size) "
            + "doc=\(panel.documentFrameForDebug) cards=\(panel.cardLayoutHeightsForDebug) "
            + "configuredWidth=\(panel.lastConfiguredScrollWidthForDebug)"
        )
        appState.updateMeasuredJobsQueueGeometry(cardStackHeight: cardHeight)
    }

    @MainActor
    private func resolvedLayoutWidth(
        proposal: ProposedViewSize?,
        panel: JobQueuePanelNSView
    ) -> CGFloat {
        if let proposalWidth = proposal?.width, proposalWidth > 1 { return proposalWidth }
        return max(panel.bounds.width, 1)
    }

    @MainActor
    private func measuredQueueHeight(panel: JobQueuePanelNSView, mode: JobsQueueSizeMode) -> CGFloat {
        switch mode {
        case .strip:
            return 0
        case .one:
            return panel.measuredFirstCardHeight()
        case .all:
            return panel.measuredCardStackHeight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var panel: JobQueuePanelNSView?
        var revision = 0
    }
}
