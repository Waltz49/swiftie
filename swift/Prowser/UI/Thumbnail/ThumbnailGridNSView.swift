import AppKit
import Foundation
import ImageIO
import SwiftUI

@MainActor
protocol ThumbnailGridDelegate: AnyObject {
    func thumbnailGridDidSelect(index: Int, path: String)
    func thumbnailGridDidClick(
        index: Int,
        path: String,
        shiftPressed: Bool,
        cmdPressed: Bool,
        ctrlPressed: Bool
    )
    func thumbnailGridDidOpenBrowse(path: String)
    /// Single-click browse activation (preview hidden). Fired on mouse up when the press was not a drag.
    func thumbnailGridDidActivateBrowse(path: String)
    func thumbnailGridDidReorder(path: String, insertionIndex: Int)
    func thumbnailGridNeedsThumbnail(
        path: String,
        size: Int,
        priority: ThumbnailLoadPriority,
        queueOrder: Int,
        backgroundLoadSession: UInt64?,
        completion: @escaping (NSImage?) -> Void
    )
    func thumbnailGridShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView)
    func thumbnailGridDidApplyFilter(label: String)
    func thumbnailGridDidUpdateLayout(columns: Int, sectionedRowLayout: ThumbnailSectionedLayout.RowLayout?)
}

/// Custom-painted thumbnail grid. Port of `thumbnails/thumbnail_canvas.py` (phase 1).
@MainActor
final class ThumbnailGridNSView: NSView, NSDraggingSource {
    weak var gridDelegate: ThumbnailGridDelegate?
    weak var configSource: AppConfig?
    weak var appState: AppState?

    var imagePaths: [String] = [] {
        didSet {
            if oldValue != imagePaths {
                invalidateThumbnailLoadingSession()
            }
            let keeping = Set(imagePaths)
            imageDimensionCache = imageDimensionCache.filter { keeping.contains($0.key) }
            basenamesNeedingExtensions = ThumbnailLayout.basenamesWithMultipleExtensions(in: imagePaths)
            reloadLayoutIfNeeded()
        }
    }

    /// When false (browse/list/etc.), visible and background thumbnail requests are not started.
    var thumbnailLoadingActive = true {
        didSet {
            if thumbnailLoadingActive {
                if oldValue == false {
                    scheduleLoadVisibleThumbnails(debounced: false)
                }
            } else {
                invalidateThumbnailLoadingSession()
            }
        }
    }

    var currentIndex: Int = 0 {
        didSet { needsDisplay = true }
    }

    var selectedIndices: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    var multiSelectMode: Bool = false {
        didSet { needsDisplay = true }
    }

    var showFilenames: Bool = false {
        didSet { reloadLayoutIfNeeded() }
    }

    var showImageSize: Bool = false {
        didSet { reloadLayoutIfNeeded() }
    }

    var showExtensions: Bool = true {
        didSet { needsDisplay = true }
    }

    var overlayBoxColor: NSColor = NSColor.black.withAlphaComponent(0.94)
    var emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: ThemeColors.dark)
    private var themeColors = ThemeColors.dark
    var currentDirectory: String?
    var filterPattern: String = "*"
    var imageExtensions: [String] = []
    var directoryListingDenied = false
    /// Reference-graph presentation (Python `reference_graph_data`).
    var referenceGraph: ReferenceGraph? {
        didSet { reloadLayoutIfNeeded() }
    }
    /// Duplicate-group section layout (Python `duplicate_sections` + `is_section_mode`).
    var duplicateSections: [DuplicateGroupPresentation.DuplicateSection] = [] {
        didSet { reloadLayoutIfNeeded() }
    }
    var isDuplicateSectionMode: Bool = false {
        didSet { reloadLayoutIfNeeded() }
    }
    private var sectionedLayoutResult: ThumbnailSectionedLayout.Result?
    var deletedPlaceholderPaths: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var onInlineRenameCommitted: ((String, String) -> Void)?

    private var renameEditor: NSTextField?
    private var renameEditingPath: String?
    private var suggestedFilters: [String] = []
    private var hasImagesInFolder = false
    private var filterButtons: [ThumbnailEmptyFilterButton] = []
    private var hoveredFilterButtonIndex = -1
    private var trackingArea: NSTrackingArea?

    private var metrics = ThumbnailLayout.metrics(for: 800, itemCount: 0, showFilename: false, showImageSize: false)
    private var referenceLayout: ReferenceGraphLayoutResult?
    private var referenceNodeFrames: [Int: NSRect] = [:]

    var gridColumnCount: Int {
        if let sectionedLayoutResult {
            return max(1, sectionedLayoutResult.columns)
        }
        return max(1, isReferenceGraphMode ? 1 : metrics.columns)
    }
    private var isReferenceGraphMode: Bool {
        referenceGraph != nil && !imagePaths.isEmpty
    }
    private var imageDimensionCache: [String: String] = [:]
    private var basenamesNeedingExtensions: Set<String> = []
    private var thumbnails: [String: NSImage] = [:]
    private var loadingPaths: Set<String> = []
    private var thumbnailPixelSize: Int = 256
    private var isUpdatingDocumentSize = false
    private var lastLayoutViewportWidth: CGFloat = 0
    private var lastLayoutSnapshot: LayoutSnapshot?
    private var visibleLoadDebounceWorkItem: DispatchWorkItem?
    private var visibleLoadRetryWorkItem: DispatchWorkItem?
    private var backgroundLoadWorkItem: DispatchWorkItem?
    private var backgroundLoadFollowUpWorkItem: DispatchWorkItem?
    private var backgroundLoadSession: UInt64 = 0
    /// True while the user is scrolling; off-screen batch loads are paused.
    private var backgroundLoadingSuspended = false
    var wrapAround = true

    private struct LayoutSnapshot: Equatable {
        let viewportWidth: CGFloat
        let viewportHeight: CGFloat
        let itemCount: Int
        let showFilename: Bool
        let showImageSize: Bool
        let cellSize: CGFloat
        let referenceGraphNodeCount: Int
        let manualReferenceThumbSize: Bool
        let manualThumbnailSize: Bool
        let duplicateSectionCount: Int
        let duplicateSectionStarts: [Int]
        let isDuplicateSectionMode: Bool
    }

    /// File path under the first mouse-down of a press–drag–click gesture (cleared on mouse up).
    private var dragSourcePath: String?
    private var dragStartPoint: NSPoint?
    private var dropInsertionIndex: Int?
    private var dropIndicatorRect: NSRect?
    private var externalDragStarted = false
    /// Set when the pointer moves past the drag threshold (Python ``_dragging``); survives ``resetDragState`` until mouse up.
    private var suppressBrowseActivation = false
    private var draggingPaths: [String] = []
    private let dragThreshold: CGFloat = 6

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: colors)
        overlayBoxColor = colors.thumbnailFilenameOverlay.nsColor
        needsDisplay = true
    }

    func reloadLayoutIfNeeded() {
        let snapshot = currentLayoutSnapshot()
        if snapshot == lastLayoutSnapshot { return }
        reloadLayout()
    }

    func reloadLayout() {
        let viewportWidth = viewportWidthForLayout()
        lastLayoutViewportWidth = viewportWidth
        lastLayoutSnapshot = currentLayoutSnapshot(viewportWidth: viewportWidth)
        if imagePaths.isEmpty {
            referenceLayout = nil
            referenceNodeFrames = [:]
            sectionedLayoutResult = nil
            let viewport = emptyStateViewportSize()
            applyDocumentSize(
                NSSize(
                    width: max(viewportWidth, viewport.width),
                    height: max(viewport.height, 300)
                )
            )
            needsDisplay = true
            gridDelegate?.thumbnailGridDidUpdateLayout(columns: 1, sectionedRowLayout: nil)
            return
        }
        if let graph = referenceGraph {
            reloadReferenceGraphLayout(graph: graph, viewportWidth: viewportWidth)
            sectionedLayoutResult = nil
            return
        }
        referenceLayout = nil
        referenceNodeFrames = [:]
        let viewport = viewportSizeForLayout()
        let sectionedDuplicate = isDuplicateSectionMode && !duplicateSections.isEmpty
        let cellSize = resolvedLayoutCellSize(
            viewportWidth: viewportWidth,
            viewportHeight: viewport.height,
            sectionedDuplicateFilenames: sectionedDuplicate && showFilenames
        )
        if sectionedDuplicate {
            let layout = ThumbnailSectionedLayout.computeDuplicateLayout(
                paths: imagePaths,
                sections: duplicateSections,
                viewportWidth: viewportWidth,
                thumbnailSize: cellSize,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                currentImagePath: appState?.fileData.currentImagePath
            )
            sectionedLayoutResult = layout
            metrics = ThumbnailLayout.metrics(
                for: viewportWidth,
                itemCount: imagePaths.count,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                cellSize: cellSize,
                scrollbarWidth: verticalScrollbarReservedWidth()
            )
            let docHeight = max(layout.contentSize.height, viewport.height)
            applyDocumentSize(
                NSSize(
                    width: max(layout.contentSize.width, viewport.width),
                    height: docHeight
                )
            )
            needsDisplay = true
            scheduleLoadVisibleThumbnails(debounced: false)
            gridDelegate?.thumbnailGridDidUpdateLayout(
                columns: layout.columns,
                sectionedRowLayout: layout.rowLayout
            )
            return
        }
        sectionedLayoutResult = nil
        metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: imagePaths.count,
            showFilename: showFilenames,
            showImageSize: showImageSize,
            cellSize: cellSize,
            scrollbarWidth: verticalScrollbarReservedWidth()
        )
        applyDocumentSize(
            NSSize(
                width: max(metrics.contentSize.width, viewport.width),
                height: max(metrics.contentSize.height, viewport.height)
            )
        )
        needsDisplay = true
        scheduleLoadVisibleThumbnails(debounced: false)
        gridDelegate?.thumbnailGridDidUpdateLayout(columns: gridColumnCount, sectionedRowLayout: nil)
    }

    private func reloadReferenceGraphLayout(graph: ReferenceGraph, viewportWidth: CGFloat) {
        let viewport = viewportSizeForLayout()
        let overlayHeight = ThumbnailLayout.overlayLabelHeight(
            showFilename: showFilenames,
            showImageSize: showImageSize
        )
        let manualSize = configSource?.bool(forKey: "manual_thumbnail_size", default: false) ?? false
        let thumbSize: Int
        if manualSize {
            thumbSize = Int(
                configSource?.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
                    ?? ThumbnailLayout.defaultCellSize
            )
        } else {
            thumbSize = ReferenceGraphLayout.computeDynamicThumbnailSize(
                graph: graph,
                viewportWidth: Int(viewportWidth),
                viewportHeight: Int(max(viewport.height, 300)),
                overlayHeight: Int(overlayHeight)
            )
        }
        // Python `reference_graph_edge_color_theme`: light palette only for the resolved light theme.
        let isLight = themeColors.themeID.lowercased() == "light"
        let layout = ReferenceGraphLayout.computeLayout(
            graph: graph,
            viewportWidth: Int(viewportWidth),
            thumbnailSize: thumbSize,
            overlayHeight: Int(overlayHeight),
            fitToViewportWidth: !manualSize,
            edgeColorTheme: ReferenceGraphLayout.edgeColorTheme(isLight: isLight)
        )
        referenceLayout = layout
        referenceNodeFrames = [:]
        for (index, path) in imagePaths.enumerated() {
            if let rect = layout.nodeRects[path] {
                referenceNodeFrames[index] = rect
                continue
            }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if let rect = layout.nodeRects.first(where: {
                URL(fileURLWithPath: $0.key).standardizedFileURL.path == normalized
            })?.value {
                referenceNodeFrames[index] = rect
            }
        }
        applyDocumentSize(
            NSSize(
                width: CGFloat(layout.canvasWidth),
                height: CGFloat(layout.canvasHeight)
            )
        )
        metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: imagePaths.count,
            showFilename: showFilenames,
            showImageSize: showImageSize,
            cellSize: CGFloat(thumbSize)
        )
        needsDisplay = true
        scheduleLoadVisibleThumbnails(debounced: false)
        gridDelegate?.thumbnailGridDidUpdateLayout(columns: 1, sectionedRowLayout: nil)
    }

    /// Called when the user scrolls; prioritize viewport thumbnails over off-screen batches.
    func noteVisibleRectChanged() {
        suspendBackgroundThumbnailLoading()
        loadVisibleThumbnails(scheduleBackground: false)
        scheduleBackgroundThumbnailLoadingAfterScrollSettles()
    }

    private func scheduleBackgroundThumbnailLoadingAfterScrollSettles() {
        visibleLoadDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleScrollSettledThumbnailLoad()
        }
        visibleLoadDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(TimingConstants.thumbnailScrollLoadDebounceMs) / 1000.0,
            execute: work
        )
    }

    /// Reload grid columns when the scroll view size changes (sidebar hide/show, window resize).
    func noteContainerSizeChanged() {
        reloadLayoutIfNeeded()
    }

    /// Pushes column count and sectioned row map to `AppState` (keyboard ↑/↓ uses the row map).
    func publishNavigationLayoutToAppState() {
        if let layout = sectionedLayoutResult {
            gridDelegate?.thumbnailGridDidUpdateLayout(
                columns: layout.columns,
                sectionedRowLayout: layout.rowLayout
            )
        } else {
            gridDelegate?.thumbnailGridDidUpdateLayout(
                columns: max(1, gridColumnCount),
                sectionedRowLayout: nil
            )
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
        scheduleLoadVisibleThumbnails(debounced: false)
    }

    /// Drop view-layer pixmaps for paths no longer in the list (Python `reorder_thumbnails` reuse).
    func pruneThumbnails(keeping paths: Set<String>) {
        guard !paths.isEmpty || !thumbnails.isEmpty || !loadingPaths.isEmpty else { return }
        thumbnails = thumbnails.filter { paths.contains($0.key) }
        loadingPaths = loadingPaths.filter { paths.contains($0) }
        imageDimensionCache = imageDimensionCache.filter { paths.contains($0.key) }
        needsDisplay = true
    }

    func clearThumbnails() {
        invalidateThumbnailLoadingSession()
        thumbnails.removeAll()
        loadingPaths.removeAll()
        needsDisplay = true
    }

    /// Port of Python `start_background_thumbnail_loading_if_needed`.
    func startBackgroundThumbnailLoadingIfNeeded() {
        guard thumbnailLoadingActive, !imagePaths.isEmpty else { return }
        let needsLoading = imagePaths.contains { path in
            thumbnails[path] == nil && !loadingPaths.contains(path)
        }
        if needsLoading {
            scheduleLoadVisibleThumbnails(debounced: false)
        }
    }

    private func invalidateThumbnailLoadingSession() {
        backgroundLoadSession += 1
        backgroundLoadingSuspended = false
        cancelPendingBackgroundBatches()
        visibleLoadDebounceWorkItem?.cancel()
        visibleLoadDebounceWorkItem = nil
        visibleLoadRetryWorkItem?.cancel()
        visibleLoadRetryWorkItem = nil
    }

    private func suspendBackgroundThumbnailLoading() {
        backgroundLoadingSuspended = true
        backgroundLoadSession += 1
        cancelPendingBackgroundBatches()
        if let appState {
            let cache = appState.thumbnailCache
            Task {
                await cache.clearQueuedThumbnailRequests(maxPriority: .nearVisible)
            }
        }
    }

    /// Top-to-bottom, then left-to-right (flipped document coordinates).
    private func thumbnailIndicesInVisualOrder(_ indices: [Int]) -> [Int] {
        indices.sorted { lhs, rhs in
            let left = cellFrame(for: lhs)
            let right = cellFrame(for: rhs)
            if abs(left.minY - right.minY) > 0.5 {
                return left.minY < right.minY
            }
            return left.minX < right.minX
        }
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

        if isReferenceGraphMode, let layout = referenceLayout {
            ReferenceGraphEdgeRenderer.paint(
                routes: layout.edgeRoutes,
                in: dirtyRect,
                context: context,
                pathsOnly: true,
                arrowheadsOnly: false
            )
        }

        let indicesToPaint = indicesIntersectingDocumentRect(dirtyRect)
        if let sectionedLayoutResult {
            for separator in sectionedLayoutResult.separators where separator.rect.intersects(dirtyRect) {
                drawSectionSeparator(separator)
            }
        }

        for index in indicesToPaint {
            let cell = cellFrame(for: index)

            let imageFrame = imageFrame(in: cell, at: index)
            let borderRect = ThumbnailLayout.thumbnailBorderRect(in: imageFrame)
            let contentRect = ThumbnailLayout.imageContentRect(in: imageFrame)
            let path = imagePaths[index]
            let isCurrent = path == appState?.fileData.currentImagePath
            let isSelected = selectedIndices.contains(index)

            drawThumbnailBackground(
                in: borderRect,
                isCurrent: isCurrent,
                isSelected: isSelected
            )
            if let image = thumbnails[path] {
                drawThumbnail(image, in: contentRect)
            } else {
                NSColor.quaternaryLabelColor.setFill()
                contentRect.fill()
                drawPlaceholder(for: path, in: contentRect)
            }

            drawThumbnailBorder(
                in: borderRect,
                isCurrent: isCurrent,
                isSelected: isSelected
            )

            if isDeletedPlaceholder(path) {
                drawDeletedOverlay(in: contentRect)
            }

            if showFilenames || showImageSize {
                drawOverlay(
                    for: path,
                    at: index,
                    in: cell,
                    showFilename: showFilenames,
                    showImageSize: showImageSize
                )
            }
        }

        if isReferenceGraphMode, let layout = referenceLayout {
            ReferenceGraphEdgeRenderer.paint(
                routes: layout.edgeRoutes,
                in: dirtyRect,
                context: context,
                pathsOnly: false,
                arrowheadsOnly: true
            )
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
        // Keep first-click drag/selection state; second down must not retarget selection.
        if event.clickCount >= 2 {
            return
        }
        let path = imagePaths[index]
        dragSourcePath = path
        dragStartPoint = point
        externalDragStarted = false
        suppressBrowseActivation = false
        draggingPaths = []
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        let shiftPressed = flags.contains(.shift)
        let cmdPressed = flags.contains(.command)
        let ctrlPressed = flags.contains(.control)
        gridDelegate?.thumbnailGridDidClick(
            index: index,
            path: path,
            shiftPressed: shiftPressed,
            cmdPressed: cmdPressed,
            ctrlPressed: ctrlPressed
        )
    }

    override func mouseUp(with event: NSEvent) {
        if imagePaths.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            handleEmptyStateClick(at: point)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftPressed = flags.contains(.shift)
        let cmdPressed = flags.contains(.command)
        let ctrlPressed = flags.contains(.control)
        if !suppressBrowseActivation, !shiftPressed, !cmdPressed, !ctrlPressed {
            if event.clickCount >= 2 {
                guard let path = browseActivationPath(at: point) else {
                    resetDragState()
                    return
                }
                gridDelegate?.thumbnailGridDidOpenBrowse(path: path)
            } else if let path = browseActivationPath(at: point) {
                gridDelegate?.thumbnailGridDidActivateBrowse(path: path)
            }
        }
        resetDragState()
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
        guard let start = dragStartPoint, let sourcePath = dragSourcePath else { return }
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance >= dragThreshold else { return }
        suppressBrowseActivation = true
        guard !externalDragStarted else { return }
        beginExternalDrag(from: sourcePath, event: event)
    }

    // MARK: - External drag (Python ``_start_internal_drag`` file URL export)

    private func beginExternalDrag(from sourcePath: String, event: NSEvent) {
        let paths = dragPathsForPath(sourcePath)
        guard !paths.isEmpty else { return }
        draggingPaths = paths
        externalDragStarted = true

        var items: [NSDraggingItem] = []
        for (offset, path) in paths.enumerated() {
            let pbItem = NSPasteboardItem()
            pbItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            let item = NSDraggingItem(pasteboardWriter: pbItem)
            if let image = thumbnails[path] {
                let preview = scaledDragPreview(image)
                let origin = NSPoint(x: CGFloat(offset) * 4, y: CGFloat(offset) * 4)
                item.setDraggingFrame(NSRect(origin: origin, size: preview.size), contents: preview)
            } else {
                item.setDraggingFrame(NSRect(x: 0, y: 0, width: 64, height: 64), contents: nil)
            }
            items.append(item)
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, ignoreModifierKeysFor context: NSDraggingContext) -> Bool {
        // AppKit's file-drag Option handling rewrites the session mask on mouse-up
        // and cancels copy. We choose copy vs move in the destination instead.
        true
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Re-query `sourceOperationMaskFor` when ⌥/⌘ changes mid-drag (copy badge on destinations).
        _ = FileDragDropOperations.sourceOperationMask(for: .withinApplication, filePaths: draggingPaths)
    }

    private func dragPathsForPath(_ sourcePath: String) -> [String] {
        guard imagePaths.contains(sourcePath) else { return [] }
        if multiSelectMode,
           let sourceIndex = imagePaths.firstIndex(of: sourcePath),
           selectedIndices.contains(sourceIndex) {
            return imagePaths.enumerated().compactMap { idx, path in
                selectedIndices.contains(idx) ? path : nil
            }
        }
        return [sourcePath]
    }

    private func scaledDragPreview(_ image: NSImage) -> NSImage {
        let maxSide: CGFloat = 64
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return NSImage(size: NSSize(width: maxSide, height: maxSide))
        }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        let preview = NSImage(size: drawSize)
        preview.lockFocus()
        ImageDisplayLoader.draw(image, in: NSRect(origin: .zero, size: drawSize))
        preview.unlockFocus()
        return preview
    }

    private func resetDragState() {
        dragSourcePath = nil
        dragStartPoint = nil
        externalDragStarted = false
        draggingPaths = []
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        needsDisplay = true
    }

    private func localFilePaths(from draggingInfo: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.map(\.path) ?? []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FileDragDropOperations.sourceOperationMask(for: context, filePaths: draggingPaths)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        configSource?.debugLog(
            "Thumbnail drag ended operation=\(operation.rawValue) copy=\(operation == .copy) move=\(operation == .move)"
        )
        resetDragState()
    }

    // MARK: - Internal reorder via drop (Python ``dropEvent``)

    private func internalReorderDropOperation(for paths: [String]) -> NSDragOperation {
        let known = Set(imagePaths)
        guard paths.allSatisfy({ known.contains($0) }) else { return [] }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isReferenceGraphMode else { return [] }
        let paths = localFilePaths(from: sender)
        guard !paths.isEmpty else { return [] }
        return internalReorderDropOperation(for: paths)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isReferenceGraphMode else { return [] }
        let paths = localFilePaths(from: sender)
        guard !paths.isEmpty else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let insertion = ThumbnailReorderService.insertionIndex(
            at: CGPoint(x: point.x, y: point.y),
            metrics: metrics,
            itemCount: imagePaths.count
        )
        dropInsertionIndex = insertion
        dropIndicatorRect = dropIndicatorRect(for: insertion)
        needsDisplay = true
        return internalReorderDropOperation(for: paths)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = localFilePaths(from: sender)
        guard let insertion = dropInsertionIndex else { return false }
        let known = Set(imagePaths)
        guard paths.allSatisfy({ known.contains($0) }) else { return false }
        defer { resetDragState() }
        guard let path = paths.first else { return false }
        if paths.count == 1 {
            gridDelegate?.thumbnailGridDidReorder(path: path, insertionIndex: insertion)
            return true
        }
        for draggedPath in paths {
            gridDelegate?.thumbnailGridDidReorder(path: draggedPath, insertionIndex: insertion)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        logKey("ThumbnailGridNSView.keyDown keyCode=\(event.keyCode) index=\(currentIndex)")
        if event.keyCode == 48, !event.modifierFlags.contains(.command), let appState {
            MainWindowKeyViewLoop.moveFromMainCanvas(appState: appState)
            return
        }
        if !BrowserWindowIdentity.browserWindowOwnsShortcuts(event: event) {
            super.keyDown(with: event)
            return
        }
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
            guard let path = appState?.fileData.currentImagePath,
                  imagePaths.contains(path) else { return }
            gridDelegate?.thumbnailGridDidOpenBrowse(path: path)
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
            guard window.isKeyWindow else {
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
        let base = highlightedListIndex() ?? currentIndex
        switch direction {
        case .left:
            applySelectionDelta(-1, wrap: wrapAround)
        case .right:
            applySelectionDelta(1, wrap: wrapAround)
        case .up, .down:
            if let rowLayout = sectionedLayoutResult?.rowLayout {
                let step = direction == .up ? -1 : 1
                let next = rowLayout.verticalTarget(currentIndex: base, stepSign: step)
                guard next != base else { return }
                selectIndex(next, scroll: true)
            } else {
                let columns = gridColumnCount
                let delta = direction == .up ? -columns : columns
                applySelectionDelta(delta, wrap: false)
            }
        }
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
        let base = highlightedListIndex() ?? currentIndex
        let next = nextIndex(base, delta: delta, wrap: wrap)
        guard next != base else { return }
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
        guard let index = highlightedListIndex() else { return }
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let cell = cellFrame(for: index)
        scrollView.contentView.scrollToVisible(cell.insetBy(dx: -20, dy: -20))
    }

    private func showContextMenu(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexAt(point: point) else { return }
        gridDelegate?.thumbnailGridShowContextMenu(for: event, clickedIndex: index, in: self)
    }

    private func indexAt(point: NSPoint) -> Int? {
        for index in 0..<imagePaths.count {
            if cellFrame(for: index).contains(point) {
                return index
            }
        }
        return nil
    }

    /// Resolve list index from ``FileDataModel/currentImagePath`` (not cached grid index).
    private func highlightedListIndex() -> Int? {
        guard let path = appState?.fileData.currentImagePath else { return nil }
        return imagePaths.firstIndex(of: path)
    }

    /// Path for browse on double-click: release hit-test, else first mouse-down of the pair.
    private func browseActivationPath(at point: NSPoint) -> String? {
        if let index = indexAt(point: point), imagePaths.indices.contains(index) {
            return imagePaths[index]
        }
        if let dragSourcePath, imagePaths.contains(dragSourcePath) {
            return dragSourcePath
        }
        return nil
    }

    private func cellFrame(for index: Int) -> NSRect {
        if let rect = sectionedLayoutResult?.itemFrames[index] {
            return rect
        }
        if let rect = referenceNodeFrames[index] {
            return rect
        }
        return ThumbnailLayout.frame(for: index, metrics: metrics)
    }

    private func imageFrame(in cell: NSRect, at index: Int) -> NSRect {
        let overlay: CGFloat
        if let sectionedLayoutResult, let custom = sectionedLayoutResult.overlayHeights[index] {
            overlay = custom
        } else {
            overlay = ThumbnailLayout.overlayLabelHeight(
                showFilename: showFilenames,
                showImageSize: showImageSize
            )
        }
        return NSRect(
            x: cell.minX,
            y: cell.minY,
            width: cell.width,
            height: max(0, cell.height - overlay)
        )
    }

    private func drawSectionSeparator(_ separator: ThumbnailSectionedLayout.SeparatorItem) {
        let rect = separator.rect
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        let lineY = rect.midY
        path.move(to: NSPoint(x: rect.minX + 10, y: lineY))
        path.line(to: NSPoint(x: rect.maxX - 10, y: lineY))
        path.lineWidth = separator.isBold ? 2 : 1
        path.stroke()
    }

    private func viewportWidthForLayout() -> CGFloat {
        if let scrollView = enclosingScrollView {
            return max(1, scrollView.contentView.bounds.width)
        }
        return max(1, bounds.width)
    }

    /// Port of Python `get_viewport_width` scrollbar fudge when content scrolls vertically.
    private func verticalScrollbarReservedWidth() -> CGFloat {
        guard let scrollView = enclosingScrollView, scrollView.hasVerticalScroller else { return 0 }
        let needsScroller = frame.height > scrollView.contentView.bounds.height + 1
        guard needsScroller else { return 0 }
        let controlSize = scrollView.verticalScroller?.controlSize ?? .regular
        let style = scrollView.verticalScroller?.scrollerStyle ?? .legacy
        return NSScroller.scrollerWidth(for: controlSize, scrollerStyle: style)
    }

    private func viewportSizeForLayout() -> NSSize {
        if let scrollView = enclosingScrollView {
            return scrollView.contentSize
        }
        return bounds.size
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

    private func scheduleLoadVisibleThumbnails(debounced: Bool) {
        if debounced {
            visibleLoadDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.handleScrollSettledThumbnailLoad()
            }
            visibleLoadDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(TimingConstants.thumbnailScrollLoadDebounceMs) / 1000.0,
                execute: work
            )
        } else {
            visibleLoadDebounceWorkItem?.cancel()
            backgroundLoadingSuspended = false
            loadVisibleThumbnails(scheduleBackground: true)
        }
    }

    /// After scroll quiesces: load viewport thumbs, then resume off-screen batches.
    private func handleScrollSettledThumbnailLoad() {
        loadVisibleThumbnails(scheduleBackground: false)
        backgroundLoadingSuspended = false
        resumeBackgroundThumbnailLoadingForCurrentViewport()
    }

    private func resumeBackgroundThumbnailLoadingForCurrentViewport() {
        guard thumbnailLoadingActive else { return }
        guard appState?.fileData.currentViewMode == .thumbnail else { return }
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.documentVisibleRect
        let visibleIndices = visibleThumbnailIndices(in: visible)
        if visibleIndices.isEmpty {
            if !imagePaths.isEmpty {
                scheduleVisibleLoadRetry()
            }
            return
        }
        let visibleSet = Set(visibleIndices)
        let nearVisible = nearVisibleThumbnailIndices(visibleRect: visible, visible: visibleSet)
        let excluded = visibleSet.union(nearVisible)
        scheduleBackgroundThumbnailLoading(excluded: excluded, session: backgroundLoadSession)
    }

    private func thumbnailGenerationPixelSize() -> Int {
        max(thumbnailPixelSize, Int(metrics.cellWidth * 2))
    }

    /// Python `current_thumbnail_size` when auto; config `thumbnail_cell_size` when manual.
    private func resolvedLayoutCellSize(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        sectionedDuplicateFilenames: Bool = false
    ) -> CGFloat {
        let manual = configSource?.bool(forKey: "manual_thumbnail_size", default: false) ?? false
        if manual {
            return CGFloat(
                configSource?.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
                    ?? ThumbnailLayout.defaultCellSize
            )
        }
        var overlay = ThumbnailLayout.overlayLabelHeight(
            showFilename: showFilenames,
            showImageSize: showImageSize
        )
        if sectionedDuplicateFilenames {
            overlay = max(
                overlay,
                ThumbnailSectionedLayout.maxOverlayHeightEstimate(
                    paths: imagePaths,
                    showFilename: showFilenames,
                    showImageSize: showImageSize,
                    thumbnailSize: ThumbnailLayout.defaultCellSize
                )
            )
        }
        let optimal = ThumbnailGridLayoutService.calculateOptimalThumbnailSize(
            numImages: imagePaths.count,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            scrollbarWidth: verticalScrollbarReservedWidth(),
            overlayHeight: overlay
        )
        return CGFloat(optimal)
    }

    private func currentLayoutSnapshot(viewportWidth: CGFloat? = nil) -> LayoutSnapshot {
        let width = viewportWidth ?? viewportWidthForLayout()
        let height = viewportSizeForLayout().height
        let manual = configSource?.bool(forKey: "manual_thumbnail_size", default: false) ?? false
        let manualRef = configSource?.bool(forKey: "manual_thumbnail_size", default: false) ?? false
        let cellSize = resolvedLayoutCellSize(viewportWidth: width, viewportHeight: height)
        return LayoutSnapshot(
            viewportWidth: width,
            viewportHeight: height,
            itemCount: imagePaths.count,
            showFilename: showFilenames,
            showImageSize: showImageSize,
            cellSize: cellSize,
            referenceGraphNodeCount: referenceGraph?.nodes.count ?? 0,
            manualReferenceThumbSize: manualRef,
            manualThumbnailSize: manual,
            duplicateSectionCount: duplicateSections.count,
            duplicateSectionStarts: isDuplicateSectionMode
                ? duplicateSections.map(\.startIndex)
                : [],
            isDuplicateSectionMode: isDuplicateSectionMode
        )
    }

    private func cancelPendingBackgroundBatches() {
        backgroundLoadWorkItem?.cancel()
        backgroundLoadFollowUpWorkItem?.cancel()
        backgroundLoadWorkItem = nil
        backgroundLoadFollowUpWorkItem = nil
    }

    private func indicesIntersectingDocumentRect(_ rect: NSRect, expandBy: CGFloat? = nil) -> [Int] {
        let pad = expandBy ?? 0
        let query = pad > 0 ? rect.insetBy(dx: -pad, dy: -pad) : rect
        if let sectionedLayoutResult {
            return (0..<imagePaths.count).filter { index in
                guard let frame = sectionedLayoutResult.itemFrames[index] else { return false }
                return frame.intersects(query)
            }
        }
        if isReferenceGraphMode {
            return ThumbnailLayout.indicesIntersecting(
                query,
                metrics: metrics,
                itemCount: imagePaths.count,
                referenceNodeFrames: referenceNodeFrames
            )
        }
        return ThumbnailLayout.indicesIntersecting(
            query,
            metrics: metrics,
            itemCount: imagePaths.count,
            referenceNodeFrames: nil
        )
    }

    private func visibleThumbnailIndices(in visibleRect: NSRect) -> [Int] {
        let pad = max(metrics.cellWidth, metrics.cellHeight)
        return indicesIntersectingDocumentRect(visibleRect, expandBy: pad)
    }

    /// Adjacent row/column cells around the viewport (Python `_get_canvas_near_visible_indices`).
    private func nearVisibleThumbnailIndices(
        visibleRect: NSRect,
        visible: Set<Int>
    ) -> [Int] {
        if sectionedLayoutResult != nil {
            let pad = max(metrics.cellWidth, metrics.cellHeight) * 2
            return indicesIntersectingDocumentRect(visibleRect, expandBy: pad)
                .filter { !visible.contains($0) }
        }
        if isReferenceGraphMode {
            let expanded = visibleRect.insetBy(
                dx: -metrics.cellWidth * 2,
                dy: -metrics.cellHeight * 2
            )
            return ThumbnailLayout.indicesIntersecting(
                expanded,
                metrics: metrics,
                itemCount: imagePaths.count,
                referenceNodeFrames: referenceNodeFrames
            )
            .filter { !visible.contains($0) }
        }
        let columns = max(1, metrics.columns)
        var nearVisible = Set<Int>()
        for idx in visible {
            let row = idx / columns
            let col = idx % columns
            for rowOffset in [-1, 1] {
                let targetRow = row + rowOffset
                guard targetRow >= 0 else { continue }
                let maxRow = (imagePaths.count - 1) / columns
                guard targetRow <= maxRow else { continue }
                let start = targetRow * columns
                let end = min(start + columns, imagePaths.count)
                for i in start..<end where !visible.contains(i) {
                    nearVisible.insert(i)
                }
            }
            for colOffset in [-1, 1] {
                let targetCol = col + colOffset
                guard targetCol >= 0, targetCol < columns else { continue }
                let targetIdx = row * columns + targetCol
                guard targetIdx < imagePaths.count, !visible.contains(targetIdx) else { continue }
                nearVisible.insert(targetIdx)
            }
        }
        return nearVisible.sorted()
    }

    private func requestThumbnailLoad(
        for path: String,
        priority: ThumbnailLoadPriority,
        queueOrder: Int = ThumbnailQueueOrdering.background,
        backgroundLoadSession: UInt64? = nil,
        isBackground: Bool = false
    ) {
        guard thumbnailLoadingActive else { return }
        guard appState?.fileData.currentViewMode == .thumbnail else { return }
        if isBackground, backgroundLoadingSuspended { return }
        if thumbnails[path] != nil { return }
        if isBackground {
            if loadingPaths.contains(path) { return }
        }
        loadingPaths.insert(path)
        let pixelSize = thumbnailGenerationPixelSize()
        gridDelegate?.thumbnailGridNeedsThumbnail(
            path: path,
            size: pixelSize,
            priority: priority,
            queueOrder: queueOrder,
            backgroundLoadSession: backgroundLoadSession
        ) { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                self.loadingPaths.remove(path)
                guard let image else { return }
                self.thumbnails[path] = image
                if let paintIndex = self.imagePaths.firstIndex(of: path) {
                    self.setNeedsDisplay(self.thumbnailRect(for: paintIndex))
                } else {
                    self.needsDisplay = true
                }
            }
        }
    }

    private func scheduleBackgroundThumbnailLoading(excluded: Set<Int>, session: UInt64) {
        guard thumbnailLoadingActive else { return }
        guard !backgroundLoadingSuspended else { return }
        guard appState?.fileData.currentViewMode == .thumbnail else { return }
        guard !imagePaths.isEmpty else { return }

        let backgroundIndices = (0..<imagePaths.count).filter { !excluded.contains($0) }
        guard !backgroundIndices.isEmpty else { return }

        cancelPendingBackgroundBatches()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let appState = self.appState else { return }
            Task { @MainActor in
                await appState.thumbnailCache.noteBackgroundLoadSession(session)
                self.queueBackgroundThumbnailBatch(
                    indices: backgroundIndices,
                    session: session,
                    submitOffset: 0
                )
            }
        }
        backgroundLoadWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(TimingConstants.thumbnailBackgroundLoadInitialDelayMs) / 1000.0,
            execute: work
        )
    }

    private func queueBackgroundThumbnailBatch(indices: [Int], session: UInt64, submitOffset: Int = 0) {
        guard session == backgroundLoadSession else { return }
        guard thumbnailLoadingActive else { return }
        guard !backgroundLoadingSuspended else { return }
        guard appState?.fileData.currentViewMode == .thumbnail else { return }

        let batchSize = TimingConstants.thumbnailBackgroundLoadBatchSize
        let batchEnd = min(indices.count, batchSize)
        guard submitOffset < batchEnd else {
            let remaining = Array(indices.dropFirst(batchSize))
            guard !remaining.isEmpty, !backgroundLoadingSuspended else { return }
            let followUp = DispatchWorkItem { [weak self] in
                self?.queueBackgroundThumbnailBatch(indices: remaining, session: session)
            }
            backgroundLoadFollowUpWorkItem = followUp
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(TimingConstants.thumbnailBackgroundLoadBatchDelayMs) / 1000.0,
                execute: followUp
            )
            return
        }

        let index = indices[submitOffset]
        requestThumbnailLoad(
            for: imagePaths[index],
            priority: .background,
            backgroundLoadSession: session,
            isBackground: true
        )

        let nextOffset = submitOffset + 1
        let stagger = DispatchWorkItem { [weak self] in
            self?.queueBackgroundThumbnailBatch(indices: indices, session: session, submitOffset: nextOffset)
        }
        backgroundLoadWorkItem = stagger
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(TimingConstants.thumbnailBackgroundLoadChunkDelayMs) / 1000.0,
            execute: stagger
        )
    }

    private func scheduleVisibleLoadRetry() {
        guard thumbnailLoadingActive else { return }
        guard !imagePaths.isEmpty else { return }
        visibleLoadRetryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadVisibleThumbnails(scheduleBackground: !self.backgroundLoadingSuspended)
        }
        visibleLoadRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(TimingConstants.thumbnailVisibleLoadRetryMs) / 1000.0,
            execute: work
        )
    }

    private func loadVisibleThumbnails(scheduleBackground: Bool = true) {
        guard thumbnailLoadingActive else { return }
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.documentVisibleRect
        let visibleIndices = visibleThumbnailIndices(in: visible)
        if visibleIndices.isEmpty, !imagePaths.isEmpty {
            scheduleVisibleLoadRetry()
            return
        }
        visibleLoadRetryWorkItem?.cancel()
        visibleLoadRetryWorkItem = nil
        let visibleSet = Set(visibleIndices)
        let nearVisible = nearVisibleThumbnailIndices(visibleRect: visible, visible: visibleSet)
        let orderedVisible = thumbnailIndicesInVisualOrder(visibleIndices)
        let orderedNear = thumbnailIndicesInVisualOrder(nearVisible)
        let pixelSize = thumbnailGenerationPixelSize()

        guard let appState else { return }
        let visiblePaths = orderedVisible.map { imagePaths[$0] }
        let nearPaths = orderedNear.map { imagePaths[$0] }
        let scheduleBackgroundAfterLoad = scheduleBackground
        Task { @MainActor in
            await appState.thumbnailCache.reprioritizeForViewport(
                size: pixelSize,
                orderedVisiblePaths: visiblePaths,
                orderedNearPaths: nearPaths
            )
            for (order, index) in orderedVisible.enumerated() {
                self.requestThumbnailLoad(
                    for: self.imagePaths[index],
                    priority: .visible,
                    queueOrder: order
                )
            }
            for (order, index) in orderedNear.enumerated() {
                self.requestThumbnailLoad(
                    for: self.imagePaths[index],
                    priority: .nearVisible,
                    queueOrder: order
                )
            }
            guard scheduleBackgroundAfterLoad, !self.backgroundLoadingSuspended else { return }
            let excluded = visibleSet.union(nearVisible)
            self.scheduleBackgroundThumbnailLoading(excluded: excluded, session: self.backgroundLoadSession)
        }
    }

    private func thumbnailRect(for index: Int) -> NSRect {
        cellFrame(for: index)
    }

    private func drawThumbnailBackground(
        in rect: NSRect,
        isCurrent: Bool,
        isSelected: Bool
    ) {
        let fillColor: NSColor
        if isSelected && multiSelectMode {
            fillColor = themeColors.multiselectBackground.nsColor
        } else if isCurrent {
            fillColor = themeColors.currentImageBackground.nsColor
        } else if isSelected {
            fillColor = themeColors.multiselectBackground.nsColor
        } else {
            fillColor = themeColors.defaultImageBackground.nsColor
        }
        fillRoundedThumbnailRect(rect, fill: fillColor, stroke: nil, lineWidth: 0)
    }

    private func drawThumbnailBorder(
        in rect: NSRect,
        isCurrent: Bool,
        isSelected: Bool
    ) {
        let strokeColor: NSColor
        let width: CGFloat
        if isCurrent {
            strokeColor = themeColors.currentImageBorder.nsColor
            width = CGFloat(themeColors.currentImageBorderWidth)
        } else if isSelected {
            strokeColor = themeColors.multiselectBorder.nsColor
            width = CGFloat(themeColors.multiselectBorderWidth)
        } else {
            strokeColor = themeColors.defaultImageBorder.nsColor
            width = CGFloat(themeColors.defaultImageBorderWidth)
        }
        guard width > 0 else { return }
        fillRoundedThumbnailRect(rect, fill: nil, stroke: strokeColor, lineWidth: width)
    }

    private func fillRoundedThumbnailRect(
        _ rect: NSRect,
        fill: NSColor?,
        stroke: NSColor?,
        lineWidth: CGFloat
    ) {
        let radius = ThumbnailLayout.cornerRadius
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke, lineWidth > 0 {
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    private func drawThumbnail(_ image: NSImage, in rect: NSRect) {
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

        NSGraphicsContext.current?.imageInterpolation = .high
        ImageDisplayLoader.draw(image, in: drawRect)
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
        at index: Int,
        in cell: NSRect,
        showFilename: Bool,
        showImageSize: Bool
    ) {
        let font = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let overlayBandHeight: CGFloat
        if isDuplicateSectionMode, let custom = sectionedLayoutResult?.overlayHeights[index] {
            overlayBandHeight = custom
        } else {
            overlayBandHeight = ThumbnailLayout.overlayLabelHeight(
                showFilename: showFilename,
                showImageSize: showImageSize
            )
        }
        guard overlayBandHeight > 0 else { return }

        let labelRect = NSRect(
            x: cell.minX + 4,
            y: cell.minY + cell.height - overlayBandHeight,
            width: max(0, cell.width - 8),
            height: overlayBandHeight
        )

        var wrappedLines: [String] = []
        let innerTextWidth = max(1, labelRect.width - 8)
        if showFilename {
            if isDuplicateSectionMode {
                wrappedLines = ThumbnailSectionedLayout.duplicateOverlayWrappedLines(
                    for: path,
                    font: font,
                    lineWrapWidth: innerTextWidth
                )
            } else {
                wrappedLines = [
                    ThumbnailLayout.overlayDisplayFilename(
                        for: path,
                        showExtensions: showExtensions,
                        basenamesNeedingExtensions: basenamesNeedingExtensions
                    ),
                ]
            }
        }
        if showImageSize, let sizeText = dimensionText(for: path) {
            wrappedLines.append(sizeText)
        }
        guard !wrappedLines.isEmpty else { return }

        let lineHeight = ThumbnailLayout.labelHeight
        let totalTextHeight = CGFloat(wrappedLines.count) * lineHeight
        let pillRect = NSRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: labelRect.width,
            height: min(labelRect.height, totalTextHeight + 4)
        )
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        overlayBoxColor.setFill()
        pillPath.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        var y = pillRect.minY + 2
        for line in wrappedLines {
            if isDuplicateSectionMode {
                let lineWidth = (line as NSString).size(withAttributes: attrs).width
                let drawX = pillRect.midX - lineWidth / 2
                let drawY = y + (lineHeight - font.boundingRectForFont.height) / 2
                (line as NSString).draw(at: NSPoint(x: drawX, y: drawY), withAttributes: attrs)
            } else {
                let lineRect = NSRect(
                    x: pillRect.minX + 4,
                    y: y,
                    width: pillRect.width - 8,
                    height: lineHeight
                )
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingTail
                (line as NSString).draw(
                    with: lineRect,
                    options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                    attributes: attrs
                )
            }
            y += lineHeight
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
        themeColors.currentImageBorder.nsColor.withAlphaComponent(0.85).setFill()
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

    private func isDeletedPlaceholder(_ path: String) -> Bool {
        deletedPlaceholderPaths.contains(path) && !FileManager.default.fileExists(atPath: path)
    }

    private func drawDeletedOverlay(in rect: NSRect) {
        let color = NSColor(red: 220 / 255, green: 50 / 255, blue: 50 / 255, alpha: 1)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        let margin: CGFloat = 7
        path.move(to: NSPoint(x: rect.minX + margin, y: rect.minY + margin))
        path.line(to: NSPoint(x: rect.maxX - margin, y: rect.maxY - margin))
        path.move(to: NSPoint(x: rect.maxX - margin, y: rect.minY + margin))
        path.line(to: NSPoint(x: rect.minX + margin, y: rect.maxY - margin))
        path.stroke()
    }

    func beginInlineRename(path: String) {
        guard let index = imagePaths.firstIndex(of: path) else {
            onInlineRenameCommitted?(path, path)
            return
        }
        if !showFilenames {
            showFilenames = true
            reloadLayout()
        }
        cancelInlineRename(restoreFocus: false)
        selectIndex(index, scroll: true, notifyDelegate: false)
        let cell = cellFrame(for: index)
        let overlayRect = filenameOverlayRect(in: cell)
        let basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let editor = NSTextField(frame: overlayRect)
        editor.stringValue = basename
        editor.isBordered = true
        editor.isBezeled = true
        editor.focusRingType = .exterior
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.delegate = self
        addSubview(editor)
        renameEditor = editor
        renameEditingPath = path
        editor.selectText(nil)
        window?.makeFirstResponder(editor)
    }

    func cancelInlineRename(restoreFocus: Bool = true) {
        renameEditor?.removeFromSuperview()
        renameEditor = nil
        renameEditingPath = nil
        if restoreFocus {
            claimKeyboardFocus()
        }
    }

    private func commitInlineRename() {
        guard let editor = renameEditor, let originalPath = renameEditingPath else { return }
        let newBase = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (originalPath as NSString).pathExtension
        let newName = ext.isEmpty ? newBase : "\(newBase).\(ext)"
        let oldName = (originalPath as NSString).lastPathComponent
        cancelInlineRename()
        guard !newBase.isEmpty, newName != oldName else { return }
        onInlineRenameCommitted?(originalPath, newName)
    }

    private func filenameOverlayRect(in cell: NSRect) -> NSRect {
        if showFilenames || showImageSize {
            let overlayHeight = min(28, cell.height * 0.22)
            return NSRect(
                x: cell.minX + 4,
                y: cell.maxY - overlayHeight - 2,
                width: max(40, cell.width - 8),
                height: overlayHeight
            )
        }
        return NSRect(
            x: cell.minX + 4,
            y: cell.minY + 4,
            width: max(40, cell.width - 8),
            height: 22
        )
    }
}

extension ThumbnailGridNSView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineRename()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if renameEditor != nil {
            commitInlineRename()
        }
    }
}
