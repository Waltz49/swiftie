import AppKit
import SwiftUI

// AppKit requires a reverse-DNS UTI (Qt MIME "application/x-prowser-job-queue-id" is invalid here).
private let jobQueueDragType = NSPasteboard.PasteboardType("com.prowser.job-queue-id")

let jobsPaneDebugEnabled = ProcessInfo.processInfo.environment["PROWSER_JOBS_PANE_DEBUG"] == "1"
func jobsPaneDebug(_ message: @autoclosure () -> String) {
    guard jobsPaneDebugEnabled else { return }
    print("[jobs-pane] \(message())")
}

private final class JobsPaneNonFocusScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
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
    var onAddSeries: ((String, Int, Bool) -> Void)?
    var onSubtractSeries: ((String, Int, Bool) -> Void)?
    var onToggleImageRefinement: ((String, Bool) -> Void)?
    var onToggleTextRefinement: ((String, Bool) -> Void)?
    var onJobNumberClick: ((String) -> Void)?
    var actionBarStateProvider: ((String) -> JobQueueActionBarState)?
    var onActionBarEmbedded: ((CGFloat) -> Void)?

    var themeColors: ThemeColors = .dark
    var selectedJobID: String?

    private let scrollView = JobsPaneNonFocusScrollView()
    private let documentView = FlippedView()
    private let stackView = NSStackView()
    private var cardViews: [JobCardNSView] = []
    private var cardPool: [JobCardNSView] = []
    private var dropLine = NSView()
    private var rows: [QueueRowSnapshot] = []
    /// When the running job id changes, force a card rebuild (pool reuse can leave stale running chrome).
    private var lastDisplayedActiveJobID: String?
    private var lastSyncedImageGenUIRevision = -1
    private var dragJobID: String?
    private var pendingDropInsertIndex: Int?
    private var reorderApplied = false
    private var autoScrollTimer: Timer?
    private var lastConfiguredScrollWidth: CGFloat = 0
    private var documentWidthConstraint: NSLayoutConstraint?
    private var documentHeightConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var scrollViewBottomConstraint: NSLayoutConstraint?
    private var scrollViewHeightConstraint: NSLayoutConstraint?
    private var lastStackScrollbarReserve: CGFloat = 0
    private var pendingScrollWidth: CGFloat?
    private var scrollWidthReconfigureScheduled = false
    private var actionBarVisible = false
    /// Job id for the card that currently hosts ``sharedActionBar`` (toolbar actions target this, not a stale selection).
    private var actionBarHostJobID = ""
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
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentWidthConstraint = documentView.widthAnchor.constraint(equalToConstant: 260)
        documentHeightConstraint = documentView.heightAnchor.constraint(equalToConstant: 40)
        documentWidthConstraint?.isActive = true
        documentHeightConstraint?.isActive = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = JobQueueLayout.listSpacing
        documentView.addSubview(stackView)

        dropLine.wantsLayer = true
        dropLine.isHidden = true
        documentView.addSubview(dropLine)

        sharedActionBar.isHidden = true
        sharedActionBar.translatesAutoresizingMaskIntoConstraints = false
        wireActionBar()

        addSubview(scrollView)
        let stackTrailing = stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -4)
        stackTrailingConstraint = stackTrailing
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollViewBottomConstraint = scrollBottom
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollBottom,
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            stackTrailing,
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
        ])
    }

    override var isOpaque: Bool { false }

    override var acceptsFirstResponder: Bool { false }

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

    private func actionBarTargetJobID() -> String? {
        if !actionBarHostJobID.isEmpty { return actionBarHostJobID }
        return selectedJobID
    }

    private func wireActionBar() {
        sharedActionBar.onEdit = { [weak self] in
            guard let id = self?.actionBarTargetJobID() else { return }
            self?.onEdit?(id)
        }
        sharedActionBar.onCancel = { [weak self] cascade in
            guard let id = self?.actionBarTargetJobID() else { return }
            self?.onCancel?(id, cascade)
        }
        sharedActionBar.onAddSeries = { [weak self] delta, option in
            guard let self else { return }
            guard let jobID = actionBarTargetJobID() else { return }
            self.onAddSeries?(jobID, delta, option)
        }
        sharedActionBar.onSubtractSeries = { [weak self] delta, option in
            guard let self, let jobID = actionBarTargetJobID() else { return }
            self.onSubtractSeries?(jobID, delta, option)
        }
        sharedActionBar.onToggleImageRefinement = { [weak self] enabled in
            guard let id = self?.actionBarTargetJobID() else { return }
            self?.onToggleImageRefinement?(id, enabled)
        }
        sharedActionBar.onToggleTextRefinement = { [weak self] enabled in
            guard let id = self?.actionBarTargetJobID() else { return }
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

    func updateRows(
        _ rows: [QueueRowSnapshot],
        selectedJobID: String?,
        scrollWidth: CGFloat,
        imageGenUIRevision: Int
    ) {
        self.rows = rows
        self.selectedJobID = selectedJobID
        let cardScrollWidth = scrollWidthForRowLayout(proposed: scrollWidth)
        if cardScrollWidth > 0 {
            lastConfiguredScrollWidth = cardScrollWidth
        }

        let forceCardContentRefresh = imageGenUIRevision != lastSyncedImageGenUIRevision
        lastSyncedImageGenUIRevision = imageGenUIRevision

        let activeJobID = rows.first(where: { $0.isActive })?.jobID
        let activeJobChanged = activeJobID != lastDisplayedActiveJobID
        lastDisplayedActiveJobID = activeJobID

        preserveScrollPosition {
            if rows.isEmpty {
                parkAllCards()
            } else if activeJobChanged || !cardsAlignWithSnapshot(rows) {
                rebuildRows(
                    rows,
                    selectedJobID: selectedJobID,
                    scrollWidth: cardScrollWidth,
                    forceContentRefresh: true
                )
            } else {
                refreshAlignedRows(
                    rows,
                    selectedJobID: selectedJobID,
                    scrollWidth: cardScrollWidth,
                    forceContentRefresh: forceCardContentRefresh
                )
            }
            syncStackTrailingInsetForScrollbar()
            updateDocumentHeight()
        }
        refreshActionBarState()
        syncQueueScrollGeometry()
        invalidateIntrinsicContentSize()
    }

    private func cardsAlignWithSnapshot(_ rows: [QueueRowSnapshot]) -> Bool {
        guard rows.count == cardViews.count else { return false }
        for (card, row) in zip(cardViews, rows) {
            if !card.matchesSnapshotRow(row) { return false }
        }
        return true
    }

    private func refreshAlignedRows(
        _ rows: [QueueRowSnapshot],
        selectedJobID: String?,
        scrollWidth: CGFloat,
        forceContentRefresh: Bool
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
                // Python skips unchanged inactive rows only. The active card must
                // repaint when a newly submitted job becomes current.
                skipUnchanged: !forceContentRefresh && !row.isActive
            )
            if isSelected { selectedCard = card }
        }
        attachActionBar(to: selectedCard)
        refreshActionBarState()
        notifyCardGeometryChangedIfNeeded()
    }

    private func rebuildRows(
        _ rows: [QueueRowSnapshot],
        selectedJobID: String?,
        scrollWidth: CGFloat,
        forceContentRefresh: Bool
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
                skipUnchanged: !forceContentRefresh && !row.isActive
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
        notifyCardGeometryChangedIfNeeded()
    }

    private func wireCardCallbacks(_ card: JobCardNSView, row: QueueRowSnapshot) {
        card.onEdit = { [weak self] in self?.onEdit?(row.jobID) }
        card.onCancel = { [weak self] cascade in self?.onCancel?(row.jobID, cascade) }
        card.onSelect = { [weak self] in self?.onSelect?(row.jobID) }
        card.onOpenReferences = { [weak self] paths in self?.onOpenReferences?(paths) }
        card.onJobNumberClick = { [weak self] in self?.onJobNumberClick?(row.jobID) }
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
        if card.hasEmbeddedActionBar {
            card.detachActionBar()
        }
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

    func measuredQueueContentHeight() -> CGFloat {
        measuredCardStackHeight()
    }

    /// Height for pane auto-resize after layout at ``layoutWidth`` (reflows cards when width is known).
    func intrinsicPanelBlockHeight(mode: JobsQueueSizeMode, layoutWidth: CGFloat) -> CGFloat {
        let cardScrollWidth = scrollWidthForRowLayout(proposed: layoutWidth)
        if cardScrollWidth > 1, abs(lastConfiguredScrollWidth - cardScrollWidth) > 0.5, !rows.isEmpty {
            reconfigureRowsForScrollWidth(cardScrollWidth)
        }
        layoutSubtreeIfNeeded()
        switch mode {
        case .strip:
            return 0
        case .one:
            guard !rows.isEmpty else { return 0 }
            return max(measuredFirstCardHeight(), 40)
        case .all:
            guard !rows.isEmpty else { return 0 }
            return max(measuredQueueContentHeight(), 40)
        }
    }

    /// Width used to wrap card text. The document view itself stays at the clip width.
    func layoutViewportWidth() -> CGFloat {
        let clipW = rawClipViewportWidth()
        let reserve = verticalScrollbarReservedWidth()
        return max(clipW - reserve, 80)
    }

    private func rawClipViewportWidth() -> CGFloat {
        let clipW = scrollView.contentView.bounds.width
        if clipW > 20 {
            return clipW
        }
        if bounds.width > 20 {
            return bounds.width
        }
        return max(lastConfiguredScrollWidth, 260)
    }

    /// Port of Python ``ScrollBarAlwaysOff`` / ``_scroll_fits_all_job_rows`` for viewport width.
    private func shouldTreatVerticalScrollerAsOff() -> Bool {
        guard let appState = paneContextMenuAppState else { return false }
        let mode = appState.jobsQueueSizeMode
        switch mode {
        case .one:
            return true
        case .strip:
            return true
        case .all:
            if appState.imageGen.queue.jobs.count <= 1 {
                return true
            }
            return scrollFitsAllJobRowsInViewport()
        }
    }

    private func usesAutoFitQueueScrollHeight() -> Bool {
        guard let appState = paneContextMenuAppState else { return false }
        let mode = appState.jobsQueueSizeMode
        if mode == .one { return !rows.isEmpty }
        if mode == .all, appState.imageGen.queue.jobs.count <= 1 { return !rows.isEmpty }
        return false
    }

    /// Port of ``JobQueuePanelWidget._scroll_fits_all_job_rows``.
    private func scrollFitsAllJobRowsInViewport() -> Bool {
        guard !rows.isEmpty else { return false }
        let stackH = measuredCardStackHeight()
        guard stackH > 0 else { return false }
        let clipH = scrollView.contentView.bounds.height
        guard clipH > 1 else { return true }
        let slack = JobQueueLayout.paneFitBottomSlack
        return stackH <= clipH - slack + 1
    }

    func syncVerticalScrollBarPolicy() {
        let scrollerOff = shouldTreatVerticalScrollerAsOff()
        scrollView.hasVerticalScroller = !scrollerOff
        if scrollerOff {
            scrollView.verticalScrollElasticity = .none
        } else {
            scrollView.verticalScrollElasticity = .automatic
        }
        syncStackTrailingInsetForScrollbar()
    }

    /// Port of ``_apply_one_job_scroll_height`` for sidebar ONE / single-row auto-fit.
    private func applyAutoFitScrollHeightIfNeeded() {
        guard usesAutoFitQueueScrollHeight() else {
            scrollViewHeightConstraint?.isActive = false
            scrollViewBottomConstraint?.isActive = true
            return
        }
        let target = max(measuredCardStackHeight(), 40)
        if scrollViewHeightConstraint == nil {
            scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: target)
            scrollViewHeightConstraint?.priority = .required
        }
        scrollViewBottomConstraint?.isActive = false
        scrollViewHeightConstraint?.constant = target
        scrollViewHeightConstraint?.isActive = true
    }

    func syncQueueScrollGeometry() {
        syncVerticalScrollBarPolicy()
        applyAutoFitScrollHeightIfNeeded()
    }

    /// Port of Python ``get_viewport_width`` scrollbar fudge when content scrolls vertically.
    private func verticalScrollbarReservedWidth() -> CGFloat {
        guard !shouldTreatVerticalScrollerAsOff() else { return 0 }
        guard scrollView.hasVerticalScroller, contentNeedsVerticalScroller() else { return 0 }
        let controlSize = scrollView.verticalScroller?.controlSize ?? .regular
        let style = scrollView.verticalScroller?.scrollerStyle ?? .legacy
        return NSScroller.scrollerWidth(for: controlSize, scrollerStyle: style)
    }

    private func contentNeedsVerticalScroller() -> Bool {
        if shouldTreatVerticalScrollerAsOff() { return false }
        let clipH = scrollView.contentView.bounds.height
        guard clipH > 1 else { return false }
        let docH = documentHeightConstraint?.constant ?? documentView.frame.height
        let contentH = max(measuredCardStackHeight(), docH, fittingContentHeight)
        return contentH > clipH + 1
    }

    /// Live card layout width (scrollbar-aware). Ignores stale wider values from SwiftUI proposals.
    private func scrollWidthForRowLayout(proposed: CGFloat) -> CGFloat {
        if scrollView.contentView.bounds.width > 20 || bounds.width > 20 {
            return layoutViewportWidth()
        }
        if proposed > 1 { return proposed }
        return max(proposed, 260)
    }

    private func syncStackTrailingInsetForScrollbar() {
        let reserve = verticalScrollbarReservedWidth()
        guard abs(reserve - lastStackScrollbarReserve) > 0.5 else { return }
        lastStackScrollbarReserve = reserve
        stackTrailingConstraint?.constant = -(4 + reserve)
    }

    private func effectiveScrollWidth() -> CGFloat {
        layoutViewportWidth()
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
            guard cardViews.count == rows.count,
                  zip(cardViews, rows).allSatisfy({ $0.matchesSnapshotRow($1) }) else {
                rebuildRows(
                    rows,
                    selectedJobID: selectedJobID,
                    scrollWidth: scrollWidth,
                    forceContentRefresh: true
                )
                updateDocumentHeight()
                return
            }
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
        let docW = max(scrollView.contentView.bounds.width, bounds.width, 1)
        let widthDelta = abs((documentWidthConstraint?.constant ?? 0) - docW)
        let heightDelta = abs((documentHeightConstraint?.constant ?? 0) - contentHeight)
        guard widthDelta > 0.5 || heightDelta > 1 else { return }
        documentWidthConstraint?.constant = docW
        documentHeightConstraint?.constant = contentHeight
        documentView.frame = NSRect(x: 0, y: 0, width: docW, height: contentHeight)
        syncQueueScrollGeometry()
        stackView.layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        syncQueueScrollGeometry()
        let width = effectiveScrollWidth()
        jobsPaneDebug(
            "layout bounds=\(bounds) inWindow=\(window == nil ? "nil" : "\(convert(bounds, to: nil))") "
            + "visible=\(scrollView.documentVisibleRect) doc=\(documentView.frame) stack=\(stackView.frame) "
            + "firstCard=\(cardViews.first.map { "\($0.frame) hidden=\($0.isHiddenOrHasHiddenAncestor)" } ?? "none") "
            + "windowH=\(window?.frame.height ?? -1)"
        )
        if abs(lastConfiguredScrollWidth - width) > 0.5, !rows.isEmpty {
            scheduleReconfigureForScrollWidth(width)
        }
        let docW = max(scrollView.contentView.bounds.width, bounds.width, 1)
        guard abs(documentView.frame.width - docW) > 0.5
            || abs(documentView.frame.height - max(measuredCardStackHeight(), 40)) > 1 else { return }
        preserveScrollPosition {
            updateDocumentHeight()
        }
    }

    private func detachActionBarFromAllCards() {
        for card in cardViews where card.hasEmbeddedActionBar {
            card.detachActionBar()
        }
    }

    private func attachActionBar(to card: JobCardNSView?) {
        let wasVisible = actionBarVisible
        detachActionBarFromAllCards()
        if let card {
            actionBarHostJobID = card.boundJobID
            actionBarVisible = true
            card.attachActionBar(sharedActionBar)
            sharedActionBar.applyTheme(themeColors)
        } else {
            actionBarHostJobID = ""
            actionBarVisible = false
            sharedActionBar.isHidden = true
            sharedActionBar.removeFromSuperview()
        }
        refreshActionBarState()
        updateDocumentHeight()
        if actionBarVisible, !wasVisible {
            onActionBarEmbedded?(JobQueueLayout.actionBarHeight)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        notifyCardGeometryChangedIfNeeded()
    }

    private func notifyCardGeometryChangedIfNeeded() {
        onCardGeometryChanged?()
    }

    private func refreshActionBarState() {
        guard let jobID = actionBarTargetJobID(), let actionBarStateProvider else {
            sharedActionBar.configure(state: .empty)
            return
        }
        sharedActionBar.configure(state: actionBarStateProvider(jobID))
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
        // Keep auto-scroll running until the drag session ends (pointer may be in pane titlebar).
        // Keep pendingDropInsertIndex. AppKit sends exited immediately before the drop.
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

    /// Pointer in the flipped document (y grows downward, matching the card list).
    private func documentPoint(from draggingInfo: NSDraggingInfo) -> NSPoint {
        documentView.convert(draggingInfo.draggingLocation, from: nil)
    }

    private func cardFrameInDocument(_ card: NSView) -> NSRect {
        card.convert(card.bounds, to: documentView)
    }

    /// Display insert index before ``rows[index]`` (or end when index == rows.count).
    private func insertIndex(forPointInDocument point: NSPoint) -> Int {
        stackView.layoutSubtreeIfNeeded()
        let visibleCount = min(cardViews.count, rows.count)
        for index in 0..<visibleCount {
            let frame = cardFrameInDocument(cardViews[index])
            if point.y < frame.midY {
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
        let lineHeight = JobQueueLayout.dropIndicatorHeight
        let marginX: CGFloat = 4
        let width = max(1, documentView.bounds.width - marginX * 2)
        let visibleCount = min(cardViews.count, rows.count)

        let centerY: CGFloat
        if visibleCount == 0 {
            centerY = 4
        } else if insertIndex <= 0 {
            centerY = cardFrameInDocument(cardViews[0]).minY - max(1, spacing / 2)
        } else if insertIndex >= visibleCount {
            centerY = cardFrameInDocument(cardViews[visibleCount - 1]).maxY + max(1, spacing / 2)
        } else {
            centerY = cardFrameInDocument(cardViews[insertIndex]).minY - max(1, spacing / 2)
        }

        let y = centerY - lineHeight / 2
        return NSRect(x: marginX, y: y, width: width, height: lineHeight)
    }

    private func applyDropIndicator(insertIndex: Int) {
        pendingDropInsertIndex = insertIndex
        dropLine.isHidden = false
        dropLine.layer?.backgroundColor = NSColor(themeColors.jobQueueSelectionBorder).cgColor
        dropLine.frame = dropLineFrame(forInsertIndex: insertIndex)
        documentView.addSubview(dropLine, positioned: .above, relativeTo: nil)
        jobsPaneDebug("drop indicator index=\(insertIndex) frame=\(dropLine.frame)")
    }

    private func updateDropIndicator(for draggingInfo: NSDraggingInfo) {
        applyDropIndicator(insertIndex: insertIndex(forPointInDocument: documentPoint(from: draggingInfo)))
    }

    private func applyReorder(at panelPoint: NSPoint) {
        guard !reorderApplied, let jobID = dragJobID else { return }
        let insertIndex = pendingDropInsertIndex ?? insertIndex(
            forPointInDocument: documentView.convert(panelPoint, from: self)
        )
        let beforeID = beforeJobID(forInsertIndex: insertIndex)
        jobsPaneDebug("drop apply job=\(jobID) index=\(insertIndex) before=\(beforeID ?? "end")")
        if beforeID == jobID { return }
        reorderApplied = true
        stopAutoScroll()
        dropLine.isHidden = true
        onReorder?(jobID, beforeID)
    }

    private func startAutoScroll() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: ThumbnailDragAutoScroll.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoScrollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// Qt-style viewport Y (0 at top), including titlebar above the scroll view (Python global hover).
    private func dragAutoScrollYInViewport(mouse: NSPoint) -> CGFloat {
        let inScroll = scrollView.convert(mouse, from: nil)
        let inPanel = convert(mouse, from: nil)
        let viewportHeight = scrollView.bounds.height
        let scrollFrame = scrollView.frame
        if inPanel.y > scrollFrame.maxY {
            return 0
        }
        if inPanel.y < scrollFrame.minY {
            return viewportHeight
        }
        if scrollView.isFlipped {
            return inScroll.y
        }
        return viewportHeight - inScroll.y
    }

    /// Python job queue + thumbnail grid: 16 ms timer on ``RunLoop.Mode.common`` (fires during drag).
    private func autoScrollTick() {
        guard let window, dragJobID != nil else {
            stopAutoScroll()
            return
        }
        let clip = scrollView.contentView
        let mouse = window.mouseLocationOutsideOfEventStream
        let inScroll = scrollView.convert(mouse, from: nil)
        let viewportHeight = clip.bounds.height
        let viewportWidth = clip.bounds.width
        let yInViewport = dragAutoScrollYInViewport(mouse: mouse)
        guard viewportWidth > 0, viewportHeight > 0 else { return }
        guard inScroll.x >= 0, inScroll.x <= scrollView.bounds.width else { return }

        let docPoint = documentView.convert(mouse, from: nil)
        applyDropIndicator(insertIndex: insertIndex(forPointInDocument: docPoint))

        let delta = ThumbnailDragAutoScroll.scrollStep(
            xInViewport: inScroll.x,
            yInViewport: yInViewport,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        guard delta != 0 else { return }

        let visible = scrollView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let maxOriginY = max(0, documentHeight - visible.height)
        if delta < 0, visible.origin.y <= 0 { return }
        if delta > 0, visible.origin.y >= maxOriginY - 0.5 { return }
        let newY = min(max(0, visible.origin.y + delta), maxOriginY)
        clip.scroll(to: NSPoint(x: visible.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
    }
}

private enum JobNumberBadgeColors {
    static let queuedUnheld = NSColor(red: 0.8, green: 0.67, blue: 0.13, alpha: 1)
    static let activeRunning = NSColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1)
    static let heldRunning = NSColor(red: 0.6, green: 0.4, blue: 0.8, alpha: 1)
    static let errorBackground = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
}

@MainActor
private final class JobNumberBadgeLabel: NSView {
    override var isFlipped: Bool { true }

    var onClick: (() -> Void)?
    private let textField = NSTextField(labelWithString: "")

    override var intrinsicContentSize: NSSize {
        let text = textField.intrinsicContentSize
        return NSSize(width: max(44, text.width + 8), height: text.height + 4)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.alignment = .right
        textField.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(
        jobNumber: Int?,
        isActive: Bool,
        held: Bool,
        inError: Bool,
        clickable: Bool,
        cellBackground: NSColor
    ) {
        guard let jobNumber else {
            isHidden = true
            return
        }
        isHidden = false
        textField.stringValue = ImageGenJobNumber.format(jobNumber)
        let showError = inError && !isActive
        wantsLayer = true
        layer?.cornerRadius = 4
        if showError {
            textField.textColor = .white
            layer?.backgroundColor = JobNumberBadgeColors.errorBackground.cgColor
        } else {
            layer?.backgroundColor = cellBackground.cgColor
            if isActive {
                textField.textColor = held ? JobNumberBadgeColors.heldRunning : JobNumberBadgeColors.activeRunning
            } else if held {
                textField.textColor = JobNumberBadgeColors.errorBackground
            } else {
                textField.textColor = JobNumberBadgeColors.queuedUnheld
            }
        }
        toolTip = showError
            ? "Click to clear error and allow this job to run"
            : (clickable ? "Click to hold or release this job" : nil)
        invalidateIntrinsicContentSize()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onClick?()
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: onClick != nil ? .pointingHand : .arrow)
    }
}

/// Transparent layer above status text; receives row clicks (Python ``JobCard.eventFilter``).
@MainActor
private final class JobCardClickOverlay: NSView {
    weak var card: JobCardNSView?
    private var receivedMouseDown = false
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        card?.showPromptTooltipIfNeeded(from: self)
    }

    override func mouseExited(with event: NSEvent) {
        card?.hidePromptTooltip(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        card?.hidePromptTooltip(from: self)
        receivedMouseDown = true
        card?.handleSelectionMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard receivedMouseDown else { return }
        receivedMouseDown = false
        card?.handleSelectionMouseUp(event)
    }

    override func mouseDragged(with event: NSEvent) {
        card?.handleSelectionMouseDragged(event)
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
    var onJobNumberClick: (() -> Void)?

    private let backgroundView = NSView()
    private let contentView = NSView()
    private let clickOverlay = JobCardClickOverlay()
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
    private var statusWidthConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?
    private var contentFillsCardBottomConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?
    private var lastViewFingerprint = ""
    private var lastScrollWidth: CGFloat = 0
    private var lastThumbnailPaths: [String] = []
    private var lastReferencesInvalid = false
    private var lastInlineRefs = false
    private var lastHasBelowRefs = false
    private var lastSelected = false
    private var lastActive = false
    private var lastJobNumber: Int?
    private var lastJobNumberHeld = false
    private var lastJobNumberInError = false
    private var lastCopiesTotal: Int?
    private var lastPluginID = ""
    private var lastFunction = ""
    private var storedFullPrompt = ""
    private let jobNumberBadge = JobNumberBadgeLabel()
    private var jobNumberBadgeTopConstraint: NSLayoutConstraint?
    private var jobNumberBadgeTrailingConstraint: NSLayoutConstraint?
    private(set) var layoutHeight: CGFloat = 40
    private weak var embeddedActionBar: JobQueueActionBarNSView?
    private var actionBarLayoutConstraints: [NSLayoutConstraint] = []

    var hasEmbeddedActionBar: Bool { embeddedActionBar != nil }

    func attachActionBar(_ bar: JobQueueActionBarNSView) {
        if embeddedActionBar === bar {
            bar.isHidden = false
            resyncHeightAfterActionBarChange()
            return
        }
        detachActionBar()
        embeddedActionBar = bar
        bar.removeFromSuperview()
        addSubview(bar)
        bar.isHidden = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentFillsCardBottomConstraint?.isActive = false
        let margin = JobQueueLayout.cardOuterMargin
        let contentBottom = contentView.bottomAnchor.constraint(
            equalTo: bar.topAnchor,
            constant: -JobQueueLayout.cardInnerSpacing
        )
        // Card height is required. This edge can yield so a 1pt mismatch cannot collapse the card.
        contentBottom.priority = NSLayoutConstraint.Priority(999)
        let constraints = [
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
            bar.heightAnchor.constraint(equalToConstant: JobQueueLayout.actionBarHeight),
            contentBottom,
        ]
        actionBarLayoutConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        resyncHeightAfterActionBarChange()
    }

    func detachActionBar() {
        guard embeddedActionBar != nil else { return }
        NSLayoutConstraint.deactivate(actionBarLayoutConstraints)
        actionBarLayoutConstraints = []
        embeddedActionBar?.removeFromSuperview()
        embeddedActionBar?.isHidden = true
        embeddedActionBar = nil
        contentFillsCardBottomConstraint?.isActive = true
        resyncHeightAfterActionBarChange()
    }

    private func resyncHeightAfterActionBarChange() {
        syncCardHeight(inlineRefs: lastInlineRefs, hasBelowRefs: lastHasBelowRefs)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = JobQueueLayout.cardCornerRadius
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        clickOverlay.translatesAutoresizingMaskIntoConstraints = false
        clickOverlay.card = self
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
        // Overlay lives on the status widget only (Python dbl-click filter on status), so it
        // cannot sit above reference thumbs in the z-order.
        statusWidget.addSubview(clickOverlay)
        addSubview(backgroundView)
        addSubview(contentView)
        jobNumberBadge.translatesAutoresizingMaskIntoConstraints = false
        jobNumberBadge.onClick = { [weak self] in self?.onJobNumberClick?() }
        addSubview(jobNumberBadge, positioned: .above, relativeTo: contentView)
        let badgeTop = jobNumberBadge.topAnchor.constraint(equalTo: topAnchor)
        let badgeTrailing = jobNumberBadge.trailingAnchor.constraint(equalTo: trailingAnchor)
        jobNumberBadgeTopConstraint = badgeTop
        jobNumberBadgeTrailingConstraint = badgeTrailing
        NSLayoutConstraint.activate([badgeTop, badgeTrailing])

        let margin = JobQueueLayout.cardOuterMargin
        jobNumberBadgeTopConstraint?.constant = margin
        jobNumberBadgeTrailingConstraint?.constant = -margin
        contentFillsCardBottomConstraint = contentView.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -margin
        )
        contentFillsCardBottomConstraint?.priority = NSLayoutConstraint.Priority(999)
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
            clickOverlay.leadingAnchor.constraint(equalTo: statusWidget.leadingAnchor),
            clickOverlay.trailingAnchor.constraint(equalTo: statusWidget.trailingAnchor),
            clickOverlay.topAnchor.constraint(equalTo: statusWidget.topAnchor),
            clickOverlay.bottomAnchor.constraint(equalTo: statusWidget.bottomAnchor),
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
        syncStoredFullPrompt(row.fullPrompt)
        let contentWidth = Self.infoContentWidth(viewportWidth: scrollWidth)
        let refs = row.thumbnailPaths
        let useInline = resolveInlineRefs(
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
        let fingerprint = statusFingerprint(
            textWidth: textWidth,
            copiesTotal: row.copiesTotal,
            statusView: statusView
        )
        let widthChanged = scrollWidth != lastScrollWidth
        lastScrollWidth = scrollWidth
        if fingerprint == lastViewFingerprint {
            if widthChanged, lastHasBelowRefs {
                // Below-status thumbs re-wrap to the new width (Python ``_reflow_visible_refs``).
                layoutRefs(contentWidth: contentWidth, inline: useInline)
                syncCardHeight(inlineRefs: useInline, hasBelowRefs: lastHasBelowRefs)
            }
            updateJobNumberDisplay(row: row)
            updateChrome(selected: selected, running: row.isActive)
            return
        }

        lastJobNumber = row.jobNumber
        lastJobNumberHeld = row.held
        lastJobNumberInError = row.inError
        updateJobNumberDisplay(row: row)

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
        dismissPromptTooltipIfContentChanged()
    }

    /// Python ``JobCard._use_inline_refs_layout`` with hysteresis so scroller width cannot flip layout.
    private func resolveInlineRefs(scrollWidth: CGFloat, paths: [String], referencesInvalid: Bool) -> Bool {
        let count = JobReferenceThumbsNSView.cellCount(paths: paths, referencesInvalid: referencesInvalid)
        guard count >= 1, count <= 2 else { return false }
        let enter = JobQueueLayout.inlineRefsMinScrollWidth + 8
        let exit = JobQueueLayout.inlineRefsMinScrollWidth - 8
        if scrollWidth > enter { return true }
        if scrollWidth < exit { return false }
        return lastInlineRefs
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

    func matchesSnapshotRow(_ row: QueueRowSnapshot) -> Bool {
        boundJobID == row.jobID && lastActive == row.isActive
    }

    func configure(
        row: QueueRowSnapshot,
        index: Int,
        scrollWidth: CGFloat,
        selected: Bool,
        colors: ThemeColors,
        skipUnchanged: Bool = false
    ) {
        let priorFullPrompt = storedFullPrompt
        syncStoredFullPrompt(row.fullPrompt)
        let identityChanged = !boundJobID.isEmpty && boundJobID != row.jobID
        let contentIdentityChanged = !identityChanged
            && boundJobID == row.jobID
            && (row.pluginID != lastPluginID || row.function != lastFunction || row.fullPrompt != priorFullPrompt)
        boundJobID = row.jobID
        self.colors = colors
        if identityChanged || contentIdentityChanged {
            // Reused cards keep the previous job's rendered status and thumbs.
            statusWidget.discardRenderedFingerprint()
            if identityChanged {
                refsView.discardRenderedPaths()
            }
        }
        lastPluginID = row.pluginID
        lastFunction = row.function

        if skipUnchanged, !identityChanged, rowContentUnchanged(row: row, scrollWidth: scrollWidth, selected: selected) {
            updateJobNumberDisplay(row: row)
            updateChrome(selected: selected, running: row.isActive)
            return
        }

        applyTheme(colors)

        let contentWidth = Self.infoContentWidth(viewportWidth: scrollWidth)
        let refs = row.thumbnailPaths
        refsView.configure(paths: refs, referencesInvalid: row.referencesInvalid, colors: colors)
        let useInline = resolveInlineRefs(
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
        lastJobNumber = row.jobNumber
        lastJobNumberHeld = row.held
        lastJobNumberInError = row.inError
        updateJobNumberDisplay(row: row)

        statusWidthConstraint?.isActive = false
        statusWidthConstraint = statusWidget.widthAnchor.constraint(equalToConstant: textWidth)
        statusWidthConstraint?.priority = .required
        statusWidthConstraint?.isActive = true
        statusWidget.setStatusView(statusView, contentWidth: textWidth)
        lastHasBelowRefs = !useInline && refsView.cellCount > 0
        syncCardHeight(inlineRefs: useInline, hasBelowRefs: lastHasBelowRefs)
        dismissPromptTooltipIfContentChanged()

        lastViewFingerprint = statusFingerprint(
            textWidth: textWidth,
            copiesTotal: row.copiesTotal,
            statusView: statusView
        )
        lastScrollWidth = scrollWidth
        lastThumbnailPaths = refs
        lastReferencesInvalid = row.referencesInvalid
        lastInlineRefs = useInline
        lastCopiesTotal = row.copiesTotal
        updateChrome(selected: selected, running: row.isActive)
        invalidateIntrinsicContentSize()
    }

    private func statusFingerprint(
        textWidth: CGFloat,
        copiesTotal: Int,
        statusView: QueueJobStatusView
    ) -> String {
        "\(textWidth)|c:\(copiesTotal)|\(statusView.fingerprint())"
    }

    private func updateJobNumberDisplay(row: QueueRowSnapshot) {
        lastJobNumber = row.jobNumber
        lastJobNumberHeld = row.held
        lastJobNumberInError = row.inError
        let cellBg = NSColor(
            row.isActive ? colors.jobQueueRunningCellBackground : colors.jobQueueCellBackground
        )
        jobNumberBadge.apply(
            jobNumber: row.jobNumber,
            isActive: row.isActive,
            held: row.held,
            inError: row.inError,
            clickable: true,
            cellBackground: cellBg
        )
        applyJobNumberBadgeLayout()
    }

    private func applyJobNumberBadgeLayout() {
        let margin = JobQueueLayout.cardOuterMargin
        let borderInset = CGFloat(lastSelected ? colors.currentImageBorderWidth : 1)
        jobNumberBadgeTopConstraint?.constant = margin + borderInset
        jobNumberBadgeTrailingConstraint?.constant = -(margin + borderInset)
    }

    private func rowContentUnchanged(
        row: QueueRowSnapshot,
        scrollWidth: CGFloat,
        selected: Bool
    ) -> Bool {
        guard boundJobID == row.jobID else { return false }
        if !statusWidget.hasRenderedView() { return false }
        let contentWidth = Self.infoContentWidth(viewportWidth: scrollWidth)
        let refs = row.thumbnailPaths
        let useInline = resolveInlineRefs(
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
        let fingerprint = statusFingerprint(
            textWidth: textWidth,
            copiesTotal: row.copiesTotal,
            statusView: statusView
        )
        if fingerprint != lastViewFingerprint { return false }
        if row.copiesTotal != lastCopiesTotal { return false }
        if scrollWidth != lastScrollWidth { return false }
        if refs != lastThumbnailPaths { return false }
        if row.referencesInvalid != lastReferencesInvalid { return false }
        if useInline != lastInlineRefs { return false }
        if selected != lastSelected { return false }
        if row.isActive != lastActive { return false }
        if row.jobNumber != lastJobNumber { return false }
        if row.held != lastJobNumberHeld { return false }
        if row.inError != lastJobNumberInError { return false }
        if row.pluginID != lastPluginID { return false }
        if row.function != lastFunction { return false }
        return true
    }

    private func updateChrome(selected: Bool, running: Bool) {
        let bg = running ? colors.jobQueueRunningCellBackground : colors.jobQueueCellBackground
        let cellNS = NSColor(bg)
        backgroundView.layer?.backgroundColor = cellNS.cgColor
        let showErrorBadge = lastJobNumberInError && !running
        if !jobNumberBadge.isHidden, !showErrorBadge {
            jobNumberBadge.layer?.backgroundColor = cellNS.cgColor
        }
        if selected {
            backgroundView.layer?.borderWidth = CGFloat(colors.currentImageBorderWidth)
            backgroundView.layer?.borderColor = NSColor(colors.jobQueueSelectionBorder).cgColor
        } else {
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
        }
        lastSelected = selected
        lastActive = running
        applyJobNumberBadgeLayout()
    }

    private static func infoContentWidth(viewportWidth: CGFloat) -> CGFloat {
        JobQueueLayout.infoContentWidth(viewportWidth: viewportWidth)
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

        let actionBarBlock: CGFloat
        if embeddedActionBar != nil, embeddedActionBar?.isHidden == false {
            actionBarBlock = JobQueueLayout.cardInnerSpacing + JobQueueLayout.actionBarHeight
        } else {
            actionBarBlock = 0
        }
        // Must match content top/bottom + optional action bar. Extra border height
        // conflicts with those constraints and collapses the card.
        let frameH = JobQueueLayout.cardOuterMargin * 2 + contentH + actionBarBlock
        let newHeight = max(frameH, 40)
        if abs(newHeight - layoutHeight) < 0.5,
           abs((contentHeightConstraint?.constant ?? 0) - contentH) < 0.5,
           cardHeightConstraint?.isActive == true {
            return
        }

        contentHeightConstraint?.isActive = false
        contentHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: contentH)
        contentHeightConstraint?.priority = .defaultHigh
        contentHeightConstraint?.isActive = true

        layoutHeight = newHeight
        cardHeightConstraint?.isActive = false
        cardHeightConstraint = heightAnchor.constraint(equalToConstant: layoutHeight)
        cardHeightConstraint?.priority = .required
        cardHeightConstraint?.isActive = true
        invalidateIntrinsicContentSize()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showPromptTooltipIfNeeded(from host: NSView) {
        let tip = promptTooltipText
        guard !tip.isEmpty else { return }
        ListPromptTooltip.shared.scheduleShow(
            text: tip,
            colors: colors,
            anchorView: host,
            delayMs: 3001
        )
    }

    func hidePromptTooltip(from host: NSView) {
        ListPromptTooltip.shared.hide(for: host)
    }

    private var promptTooltipText: String {
        JobPromptTooltipText.make(
            fullPrompt: storedFullPrompt,
            displayedPrompt: statusWidget.displayedPromptText()
        )
    }

    private func syncStoredFullPrompt(_ fullPrompt: String) {
        guard fullPrompt != storedFullPrompt else { return }
        storedFullPrompt = fullPrompt
        ListPromptTooltip.shared.hide(for: clickOverlay)
    }

    /// Python ``notify_job_prompt_tooltip_content_updating`` — hide while status HTML refreshes.
    private func dismissPromptTooltipIfContentChanged() {
        ListPromptTooltip.shared.hide(for: clickOverlay)
    }

    func handleSelectionMouseDown(_ event: NSEvent) {
        hidePromptTooltip(from: clickOverlay)
        mouseDownLocation = event.locationInWindow
        clickCount = event.clickCount
    }

    func handleSelectionMouseUp(_ event: NSEvent) {
        if event.clickCount >= 2 || clickCount >= 2 {
            jobsPaneDebug("card dbl-click edit job=\(boundJobID)")
            onEdit?()
            return
        }
        let current = event.locationInWindow
        let dx = current.x - mouseDownLocation.x
        let dy = current.y - mouseDownLocation.y
        if (dx * dx + dy * dy) <= 16 {
            jobsPaneDebug("card select job=\(boundJobID)")
            onSelect?()
        }
    }

    func handleSelectionMouseDragged(_ event: NSEvent) {
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

/// Pins the queue panel to the SwiftUI representable bounds (host frame is the hit target).
@MainActor
final class JobQueuePanelHostView: NSView {
    let panel = JobQueuePanelNSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        panel.syncQueueScrollGeometry()
        guard let appState = panel.paneContextMenuAppState else { return }
        let width = panel.layoutViewportWidth()
        let mode = appState.jobsQueueSizeMode
        let panelH = panel.intrinsicPanelBlockHeight(mode: mode, layoutWidth: width)
        appState.noteJobsQueuePanelMeasurement(panelHeight: panelH)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: JobQueuePanelHostView, context: Context) -> CGSize? {
        let panel = nsView.panel
        let width = resolvedLayoutWidth(proposal: proposal, panel: panel)
        let height: CGFloat
        if fillsAvailableHeight {
            height = max(proposal.height ?? panel.bounds.height, 40)
        } else if panel.isLaidOutAtPlaceholderWidth {
            // Inflated placeholder-width layout; use the last real measurement until the reflow lands.
            height = max(appState.measuredJobsCardStackHeight, 40)
        } else {
            height = max(measuredQueueHeight(panel: panel, mode: appState.jobsQueueSizeMode), 40)
        }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> JobQueuePanelHostView {
        let host = JobQueuePanelHostView()
        if compactForFloating {
            if appState.showFloatingJobsPanel {
                appState.jobsQueuePanelMeasureHost = host
            }
        } else if appState.jobsDisplayMode == .pane {
            appState.jobsQueuePanelMeasureHost = host
        }
        configurePanel(host.panel, context: context)
        context.coordinator.panel = host.panel
        return host
    }

    func updateNSView(_ host: JobQueuePanelHostView, context: Context) {
        let panel = host.panel
        context.coordinator.panel = panel
        panel.paneContextMenuKind = compactForFloating ? .jobs(floating: true) : .jobs(floating: false)
        panel.paneContextMenuAppState = appState
        if compactForFloating {
            if appState.showFloatingJobsPanel {
                appState.jobsQueuePanelMeasureHost = host
            }
        } else if appState.jobsDisplayMode == .pane {
            appState.jobsQueuePanelMeasureHost = host
        }
        syncPanelToController(panel)
        scheduleMeasuredGeometryReport(panel: panel, appState: appState, mode: appState.jobsQueueSizeMode)
    }

    @MainActor
    private func syncPanelToController(_ panel: JobQueuePanelNSView) {
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
        // Python ``_ensure_single_job_auto_selection``: a sole visible card is always selected
        // (one-job mode or single queue row), so its action bar shows without a click.
        var selectedJobID = controller.selectedJobID
        if let sole = rows.first, mode == .one || rows.count == 1, selectedJobID != sole.jobID {
            selectedJobID = sole.jobID
            // Deferred: this runs inside SwiftUI's update pass; selectJob bumps observed state.
            DispatchQueue.main.async { controller.selectJob(id: sole.jobID) }
        }
        panel.applyTheme(appState.theme.colors)
        let scrollWidth = resolvedLayoutWidth(proposal: nil, panel: panel)
        panel.updateRows(
            rows,
            selectedJobID: selectedJobID,
            scrollWidth: scrollWidth,
            imageGenUIRevision: appState.imageGenUIRevision
        )
        panel.syncQueueScrollGeometry()
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
            appState.openImageGenDialogFromQueueJob(jobID: jobID)
        }
        panel.onCancel = { jobID, cascade in
            appState.confirmCancelJob(id: jobID, cascade: cascade)
        }
        panel.onSelect = { jobID in
            let gen = appState.imageGen
            guard let jobID else {
                gen.selectJob(id: nil)
                syncPanelToController(panel)
                return
            }
            let mode = appState.jobsQueueSizeMode
            let rowCount = gen.queueSnapshot().count
            let soleVisible = mode != .strip && (mode == .one || rowCount == 1)
            if soleVisible {
                gen.selectJob(id: jobID)
            } else if gen.selectedJobID == jobID {
                gen.selectJob(id: nil)
            } else {
                gen.selectJob(id: jobID)
            }
            syncPanelToController(panel)
        }
        panel.onOpenReferences = { paths in
            appState.openReferenceThumbnailPaths(paths)
        }
        panel.onCardGeometryChanged = { [weak panel] in
            guard let panel else { return }
            scheduleMeasuredGeometryReport(panel: panel, appState: appState, mode: appState.jobsQueueSizeMode)
        }
        panel.onAddSeries = { jobID, delta, option in
            if option {
                appState.imageGen.setSeriesContinuous(forJobID: jobID)
            } else {
                appState.imageGen.addSeriesCycle(forJobID: jobID, delta: delta)
            }
        }
        panel.onSubtractSeries = { jobID, _, option in
            appState.imageGen.subtractSeriesRemaining(forJobID: jobID, removeAll: option)
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
        panel.onJobNumberClick = { jobID in
            let gen = appState.imageGen
            if gen.jobInError(jobID: jobID) {
                gen.releaseJobFromError(jobID: jobID)
            } else {
                gen.toggleJobHeld(jobID: jobID)
            }
        }
        context.coordinator.appState = appState
        appState.jobsQueuePanelSync = { [weak panel] in
            guard let panel else { return }
            syncPanelToController(panel)
        }
    }

    static func dismantleNSView(_ host: JobQueuePanelHostView, coordinator: Coordinator) {
        if coordinator.appState?.jobsQueuePanelMeasureHost === host {
            coordinator.appState?.jobsQueuePanelMeasureHost = nil
            // Only the currently registered host owns this callback. A stale host
            // can dismantle after its replacement has already installed a new one.
            coordinator.appState?.jobsQueuePanelSync = nil
        }
        coordinator.panel = nil
        coordinator.appState = nil
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
            cardHeight = panel.measuredQueueContentHeight()
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
        // Match pre-992af3d layout: avoid 1px placeholder width (breaks card metrics / hit targets).
        return max(panel.layoutViewportWidth(), 260)
    }

    @MainActor
    private func measuredQueueHeight(panel: JobQueuePanelNSView, mode: JobsQueueSizeMode) -> CGFloat {
        switch mode {
        case .strip:
            return 0
        case .one:
            return panel.measuredFirstCardHeight()
        case .all:
            return panel.measuredQueueContentHeight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var panel: JobQueuePanelNSView?
        weak var appState: AppState?
    }
}
