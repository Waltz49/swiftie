import AppKit
import Foundation
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
    func thumbnailGridDidReorder(paths: [String], insertionIndex: Int)
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

/// How `displayedImages` changed relative to the previous grid list (Python `reorder_thumbnails` deltas).
enum ThumbnailDisplayedPathsUpdateKind {
    case fullReplace
    case reorderOnly
    case membershipChanged(removed: Set<String>)
}

/// Custom-painted thumbnail grid. Port of `thumbnails/thumbnail_canvas.py` (phase 1).
@MainActor
final class ThumbnailGridNSView: NSView, NSDraggingSource {
    weak var gridDelegate: ThumbnailGridDelegate?
    weak var configSource: AppConfig?
    weak var appState: AppState?

    private(set) var imagePaths: [String] = []

    /// Port of Python `reorder_thumbnails` — preserve view pixmaps and avoid full cache nukes when possible.
    func applyDisplayedPaths(_ paths: [String], updateKind: ThumbnailDisplayedPathsUpdateKind) {
        guard imagePaths != paths else { return }
        let previous = imagePaths
        imagePaths = paths
        let keeping = Set(paths)
        imageDimensionCache = imageDimensionCache.filter { keeping.contains($0.key) }

        switch updateKind {
        case .fullReplace:
            invalidateThumbnailLoadingSession()
            basenamesNeedingExtensions = ThumbnailLayout.basenamesWithMultipleExtensions(in: paths)
            pathsOrderFingerprint = ThumbnailLayout.pathsOrderFingerprint(paths)
            ThumbnailFilenameOverlayCache.shared.clear()
            ThumbnailFontMetricsCache.clear()
        case .reorderOnly:
            pathsOrderFingerprint = ThumbnailLayout.pathsOrderFingerprint(paths)
            layoutDefersBackgroundLoads = true
            if Set(previous) != keeping {
                basenamesNeedingExtensions = ThumbnailLayout.basenamesWithMultipleExtensions(in: paths)
            }
        case .membershipChanged(let removed):
            pathsOrderFingerprint = ThumbnailLayout.pathsOrderFingerprint(paths)
            if !removed.isEmpty {
                ThumbnailFilenameOverlayCache.shared.removeEntries(forPaths: removed)
            }
            basenamesNeedingExtensions = ThumbnailLayout.basenamesWithMultipleExtensions(in: paths)
            invalidateThumbnailLoadingSession()
        }

        let forceRelayout: Bool
        if case .reorderOnly = updateKind {
            forceRelayout = true
        } else {
            forceRelayout = false
        }
        reloadLayoutIfNeeded(force: forceRelayout)
    }

    private var pathsOrderFingerprint: UInt64 = 0
    private var cachedLockedFilenames: Set<String> = []
    private var cachedLockedFilenamesDirectory: String?
    private var lastVisiblePathsForReprioritize: [String] = []
    private var layoutDefersBackgroundLoads = false

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
        didSet { reloadLayoutIfNeeded() }
    }

    var overlayBoxColor: NSColor = NSColor.black.withAlphaComponent(0.94)
    var emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: ThemeColors.dark)
    private var themeColors = ThemeColors.dark
    var currentDirectory: String?
    var filterPattern: String = "*"
    var imageExtensions: [String] = []
    var directoryListingDenied = false
    var isLoadingDirectory = false {
        didSet {
            if oldValue != isLoadingDirectory {
                needsDisplay = true
            }
        }
    }
    /// Python `specific_files_active` — recalculate grid size for the partial page (`generate_thumbnails`).
    var specificFilesActive = false
    /// Reference-graph presentation (Python `reference_graph_data`).
    var referenceGraph: ReferenceGraph? {
        didSet { reloadLayoutIfNeeded() }
    }
    /// Duplicate-group section layout (Python `duplicate_sections` + `is_section_mode`).
    var duplicateSections: [DuplicateGroupPresentation.DuplicateSection] = [] {
        didSet { reloadLayoutIfNeeded() }
    }
    var exifDateSections: [ExifSectionPresentation.Section] = [] {
        didSet { reloadLayoutIfNeeded() }
    }
    var isExifSectionMode: Bool = false {
        didSet { reloadLayoutIfNeeded() }
    }
    var isDuplicateSectionMode: Bool = false {
        didSet { reloadLayoutIfNeeded() }
    }
    private var canvasLayoutResult: ThumbnailSectionedLayout.Result?
    private var referenceOverlayHeightsByIndex: [Int: CGFloat] = [:]
    private var referenceWrappedLinesByIndex: [Int: [String]] = [:]
    var deletedPlaceholderPaths: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var onInlineRenameCommitted: ((String, String) -> Void)?

    private var renameEditor: NSTextField?
    private var renameEditingPath: String?
    private var renameCanceled = false
    private var suggestedFilters: [String] = []
    private var hasImagesInFolder = false
    private var filterButtons: [ThumbnailEmptyFilterButton] = []
    private var hoveredFilterButtonIndex = -1
    private var trackingArea: NSTrackingArea?

    private var metrics = ThumbnailLayout.metrics(for: 800, itemCount: 0, showFilename: false, showImageSize: false)
    private var referenceLayout: ReferenceGraphLayoutResult?
    private var referenceNodeFrames: [Int: NSRect] = [:]

    var gridColumnCount: Int {
        if let canvasLayoutResult {
            return max(1, canvasLayoutResult.columns)
        }
        return max(1, isReferenceGraphMode ? 1 : metrics.columns)
    }

    /// One Page Up/Down step in thumbnail indices (Python `rows_per_page * columns`).
    func keyboardPageScrollDelta() -> Int {
        let columns = max(1, gridColumnCount)
        let viewportHeight = viewportSizeForLayout().height
        let rowStride: CGFloat
        if let layout = canvasLayoutResult, layout.rowLayout.totalRows > 0 {
            rowStride = max(1, layout.contentSize.height / CGFloat(layout.rowLayout.totalRows))
        } else {
            rowStride = metrics.cellHeight + ThumbnailLayout.verticalSpacing
        }
        guard rowStride > 0 else { return columns }
        let effectiveHeight = max(1, viewportHeight - ThumbnailLayout.topCoverBandHeight)
        let rowsPerPage = max(1, Int(effectiveHeight / rowStride))
        return max(1, columns * rowsPerPage)
    }
    private var isReferenceGraphMode: Bool {
        referenceGraph != nil && !imagePaths.isEmpty
    }
    private var imageDimensionCache: [String: String] = [:]
    private var basenamesNeedingExtensions: Set<String> = []
    private var thumbnails: [String: NSImage] = [:]
    private var loadingPaths: Set<String> = []
    private var isUpdatingDocumentSize = false
    private var lastLayoutViewportWidth: CGFloat = 0
    private var lastLayoutSnapshot: LayoutSnapshot?
    private var visibleLoadDebounceWorkItem: DispatchWorkItem?
    private var visibleLoadRetryWorkItem: DispatchWorkItem?
    private var backgroundLoadWorkItem: DispatchWorkItem?
    private var backgroundLoadFollowUpWorkItem: DispatchWorkItem?
    private var backgroundLoadSession: UInt64 = 0
    /// Supersedes overlapping `loadVisibleThumbnails` tasks so reprioritize is not bumped repeatedly.
    private var visibleThumbnailLoadGeneration: UInt64 = 0
    /// True while the user is scrolling; off-screen batch loads are paused.
    private var backgroundLoadingSuspended = false
    var wrapAround = true

    private struct LayoutSnapshot: Equatable {
        let viewportWidth: CGFloat
        let viewportHeight: CGFloat
        let itemCount: Int
        let pathsOrderFingerprint: UInt64
        let showFilename: Bool
        let showImageSize: Bool
        let cellSize: CGFloat
        let referenceGraphNodeCount: Int
        let manualReferenceThumbSize: Bool
        let manualThumbnailSize: Bool
        let duplicateSectionCount: Int
        let duplicateSectionStarts: [Int]
        let isDuplicateSectionMode: Bool
        let exifSectionStarts: [Int]
        let isExifSectionMode: Bool
        let showExtensions: Bool
    }

    /// File path under the first mouse-down of a press–drag–click gesture (cleared on mouse up).
    private var dragSourcePath: String?
    private var dragStartPoint: NSPoint?
    private var dropInsertionIndex: Int?
    private var dropIndicatorRect: NSRect?
    private var externalDragStarted = false
    /// Plain click on an already-selected thumb in multiselect is deferred to mouse up (Python delayed single-click) so drag keeps the batch.
    private var deferredThumbnailClick: (
        index: Int,
        path: String,
        shiftPressed: Bool,
        cmdPressed: Bool,
        ctrlPressed: Bool
    )?
    /// Set when the pointer moves past the drag threshold (Python ``_dragging``); survives ``resetDragState`` until mouse up.
    private var suppressBrowseActivation = false
    private var draggingPaths: [String] = []
    private let dragThreshold: CGFloat = 6
    private var dragAutoScrollTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        ThumbnailDragAutoScrollAppKit.suppressBuiltInDragAutoScroll(on: ThumbnailGridNSView.self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        ThumbnailDragAutoScrollAppKit.suppressBuiltInDragAutoScroll(on: ThumbnailGridNSView.self)
    }

    override func autoscroll(with event: NSEvent) -> Bool { false }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: colors)
        overlayBoxColor = colors.thumbnailFilenameOverlay.nsColor
        needsDisplay = true
    }

    func noteLockedFilenamesCacheInvalidated() {
        cachedLockedFilenamesDirectory = nil
        cachedLockedFilenames = []
    }

    private var showsEmptyCanvas: Bool {
        isLoadingDirectory || imagePaths.isEmpty
    }

    func beginDirectoryLoad() {
        isLoadingDirectory = true
        imagePaths = []
        pathsOrderFingerprint = 0
        clearThumbnails()
        invalidateThumbnailLoadingSession()
        canvasLayoutResult = nil
        referenceLayout = nil
        reloadLayout()
        needsDisplay = true
    }

    func endDirectoryLoad() {
        isLoadingDirectory = false
        reloadLayoutIfNeeded()
        needsDisplay = true
    }

    func reloadLayoutIfNeeded(force: Bool = false) {
        let snapshot = currentLayoutSnapshot()
        if !force, snapshot == lastLayoutSnapshot { return }
        reloadLayout(scheduleBackgroundLoads: !layoutDefersBackgroundLoads)
        layoutDefersBackgroundLoads = false
    }

    /// Waits until visible viewport cells finish loading (used to dismiss CNN/CLIP search progress).
    func waitForViewportThumbnailsDisplayed(timeout: TimeInterval = 120) async {
        let pollIntervalNs: UInt64 = 33_000_000
        let deadline = Date().addingTimeInterval(timeout)
        var scheduledVisibleLoadPass = false

        while Date() < deadline {
            if Task.isCancelled { return }
            if imagePaths.isEmpty || !thumbnailLoadingActive { return }
            guard appState?.fileData.currentViewMode == .thumbnail else { return }

            layoutSubtreeIfNeeded()
            enclosingScrollView?.layoutSubtreeIfNeeded()

            guard let scrollView = enclosingScrollView else {
                scheduledVisibleLoadPass = false
                scheduleLoadVisibleThumbnails(debounced: false)
                await Task.yield()
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }

            let visibleIndices = visibleThumbnailIndices(in: scrollView.documentVisibleRect)
            if visibleIndices.isEmpty {
                scheduledVisibleLoadPass = false
                scheduleLoadVisibleThumbnails(debounced: false)
                await Task.yield()
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }

            let missingIndices = visibleIndices.filter { thumbnails[imagePaths[$0]] == nil }
            if missingIndices.isEmpty {
                return
            }

            let anyInFlight = missingIndices.contains { loadingPaths.contains(imagePaths[$0]) }
            if anyInFlight {
                scheduledVisibleLoadPass = false
                await Task.yield()
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }

            if !scheduledVisibleLoadPass {
                scheduleLoadVisibleThumbnails(debounced: false)
                scheduledVisibleLoadPass = true
                await Task.yield()
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }

            // Loads were requested but visible cells still have no image (failed or placeholder).
            return
        }
    }

    func reloadLayout(scheduleBackgroundLoads: Bool = true) {
        let layoutStart = CFAbsoluteTimeGetCurrent()
        ThumbnailGridPerfDiagnostics.resetMeasureAdvanceCalls()
        let viewportWidth = viewportWidthForLayout()
        lastLayoutViewportWidth = viewportWidth
        lastLayoutSnapshot = currentLayoutSnapshot(viewportWidth: viewportWidth)
        if showsEmptyCanvas {
            referenceLayout = nil
            referenceNodeFrames = [:]
            referenceOverlayHeightsByIndex = [:]
            referenceWrappedLinesByIndex = [:]
            canvasLayoutResult = nil
            let viewport = emptyStateViewportSize()
            applyDocumentSize(
                NSSize(
                    width: max(viewportWidth, viewport.width),
                    height: max(viewport.height, 300)
                )
            )
            needsDisplay = true
            gridDelegate?.thumbnailGridDidUpdateLayout(columns: 1, sectionedRowLayout: nil)
            syncTopCoverScrollbarReserveIfNeeded()
            return
        }
        if let graph = referenceGraph {
            reloadReferenceGraphLayout(graph: graph, viewportWidth: viewportWidth)
            canvasLayoutResult = nil
            return
        }
        referenceLayout = nil
        referenceNodeFrames = [:]
        referenceOverlayHeightsByIndex = [:]
        referenceWrappedLinesByIndex = [:]
        let viewport = viewportSizeForLayout()
        let sectionedDuplicate = isDuplicateSectionMode && !duplicateSections.isEmpty
        let sectionedExif = isExifSectionMode && !exifDateSections.isEmpty
        let sectionedFilenames = (sectionedDuplicate || sectionedExif) && showFilenames
        let cellSize = resolvedLayoutCellSize(
            viewportWidth: viewportWidth,
            viewportHeight: viewport.height,
            sectionedDuplicateFilenames: sectionedFilenames
        )
        let layout: ThumbnailSectionedLayout.Result
        if sectionedDuplicate {
            layout = ThumbnailSectionedLayout.computeDuplicateLayout(
                paths: imagePaths,
                sections: duplicateSections,
                viewportWidth: viewportWidth,
                viewportHeight: viewport.height,
                thumbnailSize: cellSize,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                currentImagePath: appState?.fileData.currentImagePath
            )
        } else if sectionedExif {
            layout = ThumbnailSectionedLayout.computeExifSectionLayout(
                paths: imagePaths,
                sections: exifDateSections,
                viewportWidth: viewportWidth,
                viewportHeight: viewport.height,
                thumbnailSize: cellSize,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                currentImagePath: appState?.fileData.currentImagePath
            )
        } else {
            let standard = ThumbnailStandardGridLayout.compute(
                paths: imagePaths,
                viewportWidth: viewportWidth,
                viewportHeight: viewport.height,
                thumbnailSize: cellSize,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                scrollbarWidth: verticalScrollbarReservedWidth()
            )
            layout = ThumbnailSectionedLayout.Result(
                itemFrames: standard.itemFrames,
                separators: [],
                columns: standard.columns,
                contentSize: standard.contentSize,
                overlayHeights: standard.overlayHeights,
                wrappedLines: standard.wrappedLines,
                rowLayout: standard.rowLayout,
                rowVerticalBounds: standard.rowVerticalBounds,
                usesUniformRowHeights: standard.usesUniformRowHeights,
                gridXOffset: standard.gridXOffset
            )
        }
        canvasLayoutResult = layout
        metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: imagePaths.count,
            showFilename: showFilenames,
            showImageSize: showImageSize,
            cellSize: cellSize,
            scrollbarWidth: verticalScrollbarReservedWidth(),
            xOffsetOverride: layout.gridXOffset
        )
        let docHeight = max(layout.contentSize.height, viewport.height)
        applyDocumentSize(
            NSSize(
                width: max(layout.contentSize.width, viewport.width),
                height: docHeight
            )
        )
        needsDisplay = true
        hydrateVisibleThumbnailsFromCacheIfNeeded()
        if scheduleBackgroundLoads {
            scheduleLoadVisibleThumbnails(debounced: false, allowBackgroundSweep: true)
        } else {
            scheduleLoadVisibleThumbnails(debounced: false, allowBackgroundSweep: false)
        }
        gridDelegate?.thumbnailGridDidUpdateLayout(
            columns: layout.columns,
            sectionedRowLayout: layout.rowLayout
        )
        let layoutMs = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000
        ThumbnailGridPerfDiagnostics.recordLayout(durationMs: layoutMs)
        syncTopCoverScrollbarReserveIfNeeded()
    }

    private func reloadReferenceGraphLayout(graph: ReferenceGraph, viewportWidth: CGFloat) {
        let viewport = viewportSizeForLayout()
        let conservativeOverlay = ThumbnailFilenameOverlayService.conservativeOverlayHeight(
            showFilename: showFilenames,
            showImageSize: showImageSize
        )
        let overlayContext = ReferenceGraphOverlayLayoutContext(
            showFilename: showFilenames,
            showImageSize: showImageSize,
            showExtensions: showExtensions,
            basenamesNeedingExtensions: basenamesNeedingExtensions
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
                overlayHeight: Int(conservativeOverlay)
            )
        }
        let isLight = themeColors.themeID.lowercased() == "light"
        let layout = ReferenceGraphLayout.computeLayout(
            graph: graph,
            viewportWidth: Int(viewportWidth),
            thumbnailSize: thumbSize,
            overlayHeight: Int(conservativeOverlay),
            overlayContext: overlayContext,
            fitToViewportWidth: !manualSize,
            edgeColorTheme: ReferenceGraphLayout.edgeColorTheme(isLight: isLight)
        )
        referenceLayout = layout
        referenceNodeFrames = [:]
        referenceOverlayHeightsByIndex = [:]
        referenceWrappedLinesByIndex = [:]
        for (index, path) in imagePaths.enumerated() {
            let resolvedPath: String?
            if layout.nodeRects[path] != nil {
                resolvedPath = path
            } else {
                let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                resolvedPath = layout.nodeRects.keys.first {
                    URL(fileURLWithPath: $0).standardizedFileURL.path == normalized
                }
            }
            guard let resolvedPath, let rect = layout.nodeRects[resolvedPath] else { continue }
            referenceNodeFrames[index] = rect
            referenceOverlayHeightsByIndex[index] = layout.overlayHeightsByPath[resolvedPath] ?? 0
            referenceWrappedLinesByIndex[index] = layout.wrappedLinesByPath[resolvedPath] ?? []
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
        syncTopCoverScrollbarReserveIfNeeded()
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
        if let layout = canvasLayoutResult {
            gridDelegate?.thumbnailGridDidUpdateLayout(
                columns: layout.columns,
                sectionedRowLayout: layout.rowLayout
            )
        } else {
            gridDelegate?.thumbnailGridDidUpdateLayout(
                columns: max(1, gridColumnCount),
                sectionedRowLayout: canvasLayoutResult?.rowLayout
            )
        }
    }

    func invalidateThumbnail(path: String) {
        thumbnails.removeValue(forKey: path)
        loadingPaths.remove(path)
    }

    func invalidateThumbnails(for paths: [String]) {
        guard !paths.isEmpty else { return }
        invalidateThumbnailLoadingSession()
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
        loadingPaths.removeAll()
        lastVisiblePathsForReprioritize = []
        cancelPendingBackgroundBatches()
        visibleLoadDebounceWorkItem?.cancel()
        visibleLoadDebounceWorkItem = nil
        visibleLoadRetryWorkItem?.cancel()
        visibleLoadRetryWorkItem = nil
        if let appState {
            let session = backgroundLoadSession
            Task { await appState.thumbnailCache.noteBackgroundLoadSession(session) }
        }
    }

    private func suspendBackgroundThumbnailLoading() {
        backgroundLoadingSuspended = true
        backgroundLoadSession += 1
        loadingPaths.removeAll()
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
        guard showsEmptyCanvas else {
            suggestedFilters = []
            hasImagesInFolder = false
            filterButtons = []
            hoveredFilterButtonIndex = -1
            return
        }
        if isLoadingDirectory {
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
        let drawStart = CFAbsoluteTimeGetCurrent()
        if showsEmptyCanvas {
            emptyStateStyle.background.setFill()
            dirtyRect.fill()
            let area = NSRect(origin: .zero, size: emptyStateViewportSize())
            if let message = ThumbnailEmptyStateRenderer.message(
                directory: currentDirectory,
                filterPattern: filterPattern,
                directoryListingDenied: directoryListingDenied,
                isLoadingDirectory: isLoadingDirectory
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
        context.saveGState()
        context.clip(to: dirtyRect)
        emptyStateStyle.background.setFill()
        dirtyRect.fill()

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
        let thumbnailLockingEnabled = appState?.config.bool(forKey: "allow_thumbnail_locking", default: false) ?? false
        let lockedFilenames: Set<String> = {
            guard thumbnailLockingEnabled, let directory = currentDirectory else { return [] }
            if cachedLockedFilenamesDirectory == directory {
                return cachedLockedFilenames
            }
            let locked = PrsortIO.lockedFilenames(in: directory)
            cachedLockedFilenamesDirectory = directory
            cachedLockedFilenames = locked
            return locked
        }()
        if let canvasLayoutResult {
            for separator in canvasLayoutResult.separators where separator.rect.intersects(dirtyRect) {
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

            if thumbnailLockingEnabled,
               thumbnails[path] != nil,
               lockedFilenames.contains((path as NSString).lastPathComponent) {
                PadlockOverlayRenderer.draw(in: borderRect, style: .thumbnail)
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
        context.restoreGState()
        let drawMs = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000
        ThumbnailGridPerfDiagnostics.recordDraw(durationMs: drawMs)
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
        if renameEditor != nil {
            let point = convert(event.locationInWindow, from: nil)
            if let editor = renameEditor, !editor.frame.contains(point) {
                commitInlineRename()
            }
            return
        }

        if flags.contains(.control), !flags.contains(.command) {
            showContextMenu(for: event)
            return
        }

        if showsEmptyCanvas {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1,
           !flags.contains(.shift), !flags.contains(.command), !flags.contains(.control),
           let index = indexAt(point: point),
           index < imagePaths.count,
           let pillRect = filenamePillRect(for: index),
           pillRect.contains(point),
           showFilenames || showImageSize {
            beginInlineRename(path: imagePaths[index])
            return
        }
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
        let preserveMultiSelectForDrag =
            !shiftPressed && !cmdPressed && !ctrlPressed
            && (appState?.selection.selectedFiles.count ?? 0) > 1
            && (appState?.selection.selectedFiles.contains(path) ?? false)
        if preserveMultiSelectForDrag {
            deferredThumbnailClick = (
                index, path, shiftPressed, cmdPressed, ctrlPressed
            )
        } else {
            deferredThumbnailClick = nil
            gridDelegate?.thumbnailGridDidClick(
                index: index,
                path: path,
                shiftPressed: shiftPressed,
                cmdPressed: cmdPressed,
                ctrlPressed: ctrlPressed
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        if showsEmptyCanvas {
            let point = convert(event.locationInWindow, from: nil)
            handleEmptyStateClick(at: point)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftPressed = flags.contains(.shift)
        let cmdPressed = flags.contains(.command)
        let ctrlPressed = flags.contains(.control)
        if let deferred = deferredThumbnailClick, !externalDragStarted {
            gridDelegate?.thumbnailGridDidClick(
                index: deferred.index,
                path: deferred.path,
                shiftPressed: deferred.shiftPressed,
                cmdPressed: deferred.cmdPressed,
                ctrlPressed: deferred.ctrlPressed
            )
        }
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
        if renameEditor != nil { return }
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
        appState?.thumbnailDragSourcePaths = paths

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
        startDragAutoScroll()
    }

    func draggingSession(_ session: NSDraggingSession, ignoreModifierKeysFor context: NSDraggingContext) -> Bool {
        // AppKit's file-drag Option handling rewrites the session mask on mouse-up
        // and cancels copy. We choose copy vs move in the destination instead.
        true
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Re-query `sourceOperationMaskFor` when ⌥/⌘ changes mid-drag (copy badge on destinations).
        _ = FileDragDropOperations.sourceOperationMask(for: .withinApplication, filePaths: draggingPaths)
        startDragAutoScroll()
        dragAutoScrollTick()
    }

    private func dragPathsForPath(_ sourcePath: String) -> [String] {
        guard imagePaths.contains(sourcePath) else { return [] }
        if let appState {
            let selected = appState.selection.selectedFiles
            if selected.count > 1, selected.contains(sourcePath) {
                return imagePaths.filter { selected.contains($0) }
            }
        }
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
        stopDragAutoScroll()
        dragSourcePath = nil
        dragStartPoint = nil
        deferredThumbnailClick = nil
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
        appState?.thumbnailDragSourcePaths = []
        resetDragState()
    }

    // MARK: - Internal reorder via drop (Python ``dropEvent``)

    private func internalReorderDropOperation(for paths: [String]) -> NSDragOperation {
        let known = Set(imagePaths)
        guard paths.allSatisfy({ known.contains($0) }) else { return [] }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        forwardDraggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        forwardDraggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        forwardDraggingExited(sender)
    }

    func forwardDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isReferenceGraphMode else { return [] }
        let paths = localFilePaths(from: sender)
        guard !paths.isEmpty else { return [] }
        startDragAutoScroll()
        return internalReorderDropOperation(for: paths)
    }

    func forwardDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isReferenceGraphMode else { return [] }
        let paths = localFilePaths(from: sender)
        guard !paths.isEmpty else { return [] }
        let point = draggingLocationInGrid(sender)
        updateDropIndicator(at: point)
        startDragAutoScroll()
        dragAutoScrollTick()
        return internalReorderDropOperation(for: paths)
    }

    func forwardDraggingExited(_ sender: NSDraggingInfo?) {
        guard !pointerIsInsideThumbnailViewport else { return }
        stopDragAutoScroll()
        dropInsertionIndex = nil
        dropIndicatorRect = nil
        needsDisplay = true
    }

    func forwardPerformDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDragOperation(sender)
    }

    private func draggingLocationInGrid(_ sender: NSDraggingInfo) -> NSPoint {
        guard let window else { return convert(sender.draggingLocation, from: nil) }
        let inWindow = window.convertPoint(fromScreen: sender.draggingLocation)
        return convert(inWindow, from: nil)
    }

    private var pointerIsInsideThumbnailViewport: Bool {
        guard let scrollView = enclosingScrollView, let window else { return false }
        return ThumbnailDragAutoScroll.pointerHorizontallyInScrollViewport(
            scrollView: scrollView,
            mouseInWindow: window.mouseLocationOutsideOfEventStream
        )
    }

    private func updateDropIndicator(at point: NSPoint) {
        let insertion = insertionIndex(at: point)
        dropInsertionIndex = insertion
        let indicator = dropIndicatorRect(for: insertion)
        if let previous = dropIndicatorRect {
            setNeedsDisplay(previous.union(indicator))
        } else {
            setNeedsDisplay(indicator)
        }
        dropIndicatorRect = indicator
    }

    private func startDragAutoScroll() {
        guard !isReferenceGraphMode, dragAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: ThumbnailDragAutoScroll.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragAutoScrollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragAutoScrollTimer = timer
    }

    private func stopDragAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    /// Python `_update_auto_scroll` + `_handle_auto_scroll` (16 ms, percent of viewport height).
    private func dragAutoScrollTick() {
        guard let scrollView = enclosingScrollView, let window else {
            stopDragAutoScroll()
            return
        }
        let mouse = window.mouseLocationOutsideOfEventStream
        guard let pointer = ThumbnailDragAutoScroll.pointerInScrollViewport(
            scrollView: scrollView,
            mouseInWindow: mouse
        ) else { return }
        guard pointer.x >= 0, pointer.x <= pointer.width else { return }
        let delta = ThumbnailDragAutoScroll.scrollStep(
            xInViewport: pointer.x,
            yInViewport: pointer.y,
            viewportWidth: pointer.width,
            viewportHeight: pointer.height
        )
        guard delta != 0 else { return }
        let visible = scrollView.documentVisibleRect
        let documentHeight = scrollView.documentView?.frame.height ?? bounds.height
        let maxOriginY = max(0, documentHeight - visible.height)
        if delta < 0, visible.origin.y <= 0 { return }
        if delta > 0, visible.origin.y >= maxOriginY - 0.5 { return }
        let newY = min(max(0, visible.origin.y + delta), maxOriginY)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: visible.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
        updateDropIndicator(at: convert(mouse, from: nil))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = pathsInDisplayOrderForReorder(localFilePaths(from: sender))
        guard let insertion = dropInsertionIndex else { return false }
        let known = Set(imagePaths)
        guard !paths.isEmpty, paths.allSatisfy({ known.contains($0) }) else { return false }
        defer { resetDragState() }
        gridDelegate?.thumbnailGridDidReorder(paths: paths, insertionIndex: insertion)
        return true
    }

    /// Preserve grid order for multi-select drags (pasteboard URL order is not reliable).
    private func pathsInDisplayOrderForReorder(_ paths: [String]) -> [String] {
        let pathSet = Set(paths)
        if !draggingPaths.isEmpty {
            return draggingPaths.filter { pathSet.contains($0) }
        }
        if let source = appState?.thumbnailDragSourcePaths, !source.isEmpty {
            return source.filter { pathSet.contains($0) }
        }
        return imagePaths.filter { pathSet.contains($0) }
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

    var isInlineRenaming: Bool { renameEditor != nil }

    func claimKeyboardFocus() {
        guard window != nil else {
            logKey("claimKeyboardFocus skipped (no window)")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if self.isInlineRenaming {
                self.logKey("claimKeyboardFocus skipped (inline rename)")
                return
            }
            if NSApp.modalWindow != nil {
                self.logKey("claimKeyboardFocus skipped (modal window)")
                return
            }
            if let key = NSApp.keyWindow,
               key !== window,
               BrowserWindowIdentity.isAuxiliaryWindow(key) {
                self.logKey("claimKeyboardFocus skipped (auxiliary key window)")
                return
            }
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
            if let rowLayout = canvasLayoutResult?.rowLayout, !rowLayout.rowToIndices.isEmpty {
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
        if let rect = canvasLayoutResult?.itemFrames[index] {
            return rect
        }
        if let rect = referenceNodeFrames[index] {
            return rect
        }
        return ThumbnailLayout.frame(for: index, metrics: metrics)
    }

    private func overlayHeight(for index: Int, path: String) -> CGFloat {
        if let custom = canvasLayoutResult?.overlayHeights[index] {
            return custom
        }
        if let custom = referenceOverlayHeightsByIndex[index] {
            return custom
        }
        return ThumbnailLayout.overlayLabelHeight(
            showFilename: showFilenames,
            showImageSize: showImageSize
        )
    }

    private func wrappedOverlayLines(for index: Int, path: String) -> [String] {
        if let lines = canvasLayoutResult?.wrappedLines[index], !lines.isEmpty {
            return ThumbnailFilenameOverlayService.linesForDrawing(
                overlay: ThumbnailFilenameOverlay(wrappedLines: lines, overlayHeight: overlayHeight(for: index, path: path)),
                path: path,
                showImageSize: showImageSize,
                dimensionText: dimensionText(for: path)
            )
        }
        if let lines = referenceWrappedLinesByIndex[index], !lines.isEmpty {
            return ThumbnailFilenameOverlayService.linesForDrawing(
                overlay: ThumbnailFilenameOverlay(wrappedLines: lines, overlayHeight: overlayHeight(for: index, path: path)),
                path: path,
                showImageSize: showImageSize,
                dimensionText: dimensionText(for: path)
            )
        }
        return []
    }

    private func imageFrame(in cell: NSRect, at index: Int) -> NSRect {
        let path = imagePaths.indices.contains(index) ? imagePaths[index] : ""
        let overlay = overlayHeight(for: index, path: path)
        return NSRect(
            x: cell.minX,
            y: cell.minY,
            width: cell.width,
            height: max(0, cell.height - overlay)
        )
    }

    private func drawSectionSeparator(_ separator: ThumbnailSectionedLayout.SeparatorItem) {
        let rect = separator.rect
        if let label = separator.label, !label.isEmpty {
            let font = NSFont.boldSystemFont(ofSize: 13)
            let thumbText = themeColors.thumbnailText.nsColor
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: thumbText,
            ]
            let textRect = NSRect(x: rect.minX + 12, y: rect.minY + 6, width: rect.width - 24, height: rect.height - 8)
            (label as NSString).draw(in: textRect, withAttributes: attrs)
        }
        themeColors.thumbnailText.nsColor.withAlphaComponent(0.35).setStroke()
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

    /// Keeps SwiftUI top cover band aligned with layout scrollbar reserve (does not cover scroller).
    func syncTopCoverScrollbarReserveIfNeeded() {
        guard let appState else { return }
        let reserve = verticalScrollbarReservedWidth()
        guard abs(appState.thumbnailVerticalScrollbarReserve - reserve) > 0.5 else { return }
        appState.thumbnailVerticalScrollbarReserve = reserve
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

    private func scheduleLoadVisibleThumbnails(debounced: Bool, allowBackgroundSweep: Bool = true) {
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
            loadVisibleThumbnails(
                scheduleBackground: allowBackgroundSweep,
                allowBackgroundSweep: allowBackgroundSweep
            )
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
        guard shouldScheduleAutomaticBackgroundSweep() else { return }
        scheduleBackgroundThumbnailLoading(excluded: excluded)
    }

    /// Pixel size passed to ``ThumbnailCache`` (Python ``current_thumbnail_size`` / disk cache key suffix).
    private func thumbnailGenerationPixelSize() -> Int {
        let cell = Int(metrics.cellWidth.rounded(.up))
        return min(
            Int(ThumbnailLayout.maxCellSize),
            max(ThumbnailGridLayoutService.minThumbnailSize, cell)
        )
    }

    /// Fill view-layer pixmaps from disk/memory cache for the viewport (Python reuse loaded pixmap).
    private func hydrateVisibleThumbnailsFromCacheIfNeeded() {
        guard thumbnailLoadingActive, let appState, let scrollView = enclosingScrollView else { return }
        let visible = visibleThumbnailIndices(in: scrollView.documentVisibleRect)
        guard !visible.isEmpty else { return }
        let pixelSize = thumbnailGenerationPixelSize()
        let pathsToHydrate: [String] = visible.prefix(80).compactMap { index in
            guard imagePaths.indices.contains(index) else { return nil }
            let path = imagePaths[index]
            return thumbnails[path] == nil ? path : nil
        }
        guard !pathsToHydrate.isEmpty else { return }
        let cache = appState.thumbnailCache
        Task { @MainActor in
            for path in pathsToHydrate {
                guard self.imagePaths.contains(path), self.thumbnails[path] == nil else { continue }
                guard let cgImage = await cache.cachedThumbnail(for: path, size: pixelSize) else { continue }
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                self.thumbnails[path] = image
                self.ensureImageDimensionsCached(for: path)
                if let paintIndex = self.imagePaths.firstIndex(of: path) {
                    self.setNeedsDisplay(self.thumbnailRect(for: paintIndex))
                }
            }
        }
    }

    private func offscreenPathsNeedLoading(excluded: Set<Int>) -> Bool {
        for index in 0..<imagePaths.count where !excluded.contains(index) {
            if thumbnails[imagePaths[index]] == nil {
                return true
            }
        }
        return false
    }

    /// Full-grid background decode is queued for every missing pixmap; skip for very large folders (scroll loads instead).
    private func shouldScheduleAutomaticBackgroundSweep() -> Bool {
        imagePaths.count < TimingConstants.largeFolderAutomaticBackgroundSweepThreshold
    }

    /// Python `current_thumbnail_size` when auto; config `thumbnail_cell_size` when manual.
    private func resolvedLayoutCellSize(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        sectionedDuplicateFilenames: Bool = false
    ) -> CGFloat {
        let manualFlag = configSource?.bool(forKey: "manual_thumbnail_size", default: false) ?? false
        let manual = manualFlag && !specificFilesActive
        if manual {
            let raw = configSource?.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
                ?? ThumbnailLayout.defaultCellSize
            let size = min(
                ThumbnailLayout.maxCellSize,
                max(ThumbnailLayout.minCellSize, CGFloat(raw))
            )
            return size
        }
        var overlay = ThumbnailFilenameOverlayService.conservativeOverlayHeight(
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
                    thumbnailSize: ThumbnailLayout.defaultCellSize,
                    showExtensions: showExtensions,
                    basenamesNeedingExtensions: basenamesNeedingExtensions,
                    duplicatePathDisplay: false
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
            pathsOrderFingerprint: pathsOrderFingerprint,
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
            isDuplicateSectionMode: isDuplicateSectionMode,
            exifSectionStarts: isExifSectionMode ? exifDateSections.map(\.startIndex) : [],
            isExifSectionMode: isExifSectionMode,
            showExtensions: showExtensions
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
        if let canvasLayoutResult {
            let rowBounds = canvasLayoutResult.rowVerticalBounds
            if !rowBounds.isEmpty {
                let rows = rowIndicesIntersecting(query, rowBounds: rowBounds)
                var result: [Int] = []
                for row in rows {
                    guard let indices = canvasLayoutResult.rowLayout.rowToIndices[row] else { continue }
                    if canvasLayoutResult.usesUniformRowHeights {
                        result.append(contentsOf: indices)
                    } else {
                        for index in indices {
                            if canvasLayoutResult.itemFrames[index]?.intersects(query) == true {
                                result.append(index)
                            }
                        }
                    }
                }
                ThumbnailGridPerfDiagnostics.recordIntersectionScan(count: result.count)
                return result
            }
            let scanned = (0..<imagePaths.count).filter { index in
                guard let frame = canvasLayoutResult.itemFrames[index] else { return false }
                return frame.intersects(query)
            }
            ThumbnailGridPerfDiagnostics.recordIntersectionScan(count: scanned.count)
            return scanned
        }
        if isReferenceGraphMode {
            return ThumbnailLayout.indicesIntersecting(
                query,
                metrics: metrics,
                itemCount: imagePaths.count,
                referenceNodeFrames: referenceNodeFrames
            )
        }
        let fallback = ThumbnailLayout.indicesIntersecting(
            query,
            metrics: metrics,
            itemCount: imagePaths.count,
            referenceNodeFrames: nil
        )
        ThumbnailGridPerfDiagnostics.recordIntersectionScan(count: fallback.count)
        return fallback
    }

    private func rowIndicesIntersecting(_ query: NSRect, rowBounds: [(minY: CGFloat, maxY: CGFloat)]) -> [Int] {
        guard !rowBounds.isEmpty, !query.isEmpty else { return [] }
        var result: [Int] = []
        for (row, bounds) in rowBounds.enumerated() {
            if bounds.maxY < query.minY { continue }
            if bounds.minY > query.maxY { break }
            result.append(row)
        }
        return result
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
        if canvasLayoutResult != nil {
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
        if thumbnails[path] != nil {
            ensureImageDimensionsCached(for: path)
            return
        }
        if loadingPaths.contains(path) { return }
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
                guard let image else {
                    if self.thumbnailLoadingActive,
                       self.appState?.fileData.currentViewMode == .thumbnail,
                       self.imagePaths.contains(path) {
                        if priority == .visible || priority == .nearVisible {
                            self.scheduleLoadVisibleThumbnails(debounced: true)
                        } else if priority == .background {
                            self.startBackgroundThumbnailLoadingIfNeeded()
                        }
                    }
                    return
                }
                self.thumbnails[path] = image
                self.noteImageDimensionsAvailable(for: path)
                if let paintIndex = self.imagePaths.firstIndex(of: path) {
                    self.setNeedsDisplay(self.thumbnailRect(for: paintIndex))
                } else {
                    self.needsDisplay = true
                }
            }
        }
    }

    private func scheduleBackgroundThumbnailLoading(excluded: Set<Int>) {
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
                let claimedSession = self.backgroundLoadSession
                await appState.thumbnailCache.noteBackgroundLoadSession(claimedSession)
                self.queueBackgroundThumbnailBatch(
                    indices: backgroundIndices,
                    claimedSession: claimedSession,
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

    private func queueBackgroundThumbnailBatch(
        indices: [Int],
        claimedSession: UInt64,
        submitOffset: Int = 0
    ) {
        guard claimedSession == backgroundLoadSession else {
            if thumbnailLoadingActive, !backgroundLoadingSuspended {
                startBackgroundThumbnailLoadingIfNeeded()
            }
            return
        }
        guard thumbnailLoadingActive else { return }
        guard !backgroundLoadingSuspended else { return }
        guard appState?.fileData.currentViewMode == .thumbnail else { return }

        let batchSize = TimingConstants.thumbnailBackgroundLoadBatchSize
        let batchEnd = min(indices.count, batchSize)
        guard submitOffset < batchEnd else {
            let remaining = Array(indices.dropFirst(batchSize))
            guard !remaining.isEmpty, !backgroundLoadingSuspended else { return }
            let followUp = DispatchWorkItem { [weak self] in
                self?.queueBackgroundThumbnailBatch(
                    indices: remaining,
                    claimedSession: claimedSession,
                    submitOffset: 0
                )
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
            backgroundLoadSession: claimedSession,
            isBackground: true
        )

        let nextOffset = submitOffset + 1
        let stagger = DispatchWorkItem { [weak self] in
            self?.queueBackgroundThumbnailBatch(
                indices: indices,
                claimedSession: claimedSession,
                submitOffset: nextOffset
            )
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

    private func loadVisibleThumbnails(scheduleBackground: Bool = true, allowBackgroundSweep: Bool = true) {
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

        guard let appState else { return }
        let visiblePaths = orderedVisible.map { imagePaths[$0] }
        let nearPaths = orderedNear.map { imagePaths[$0] }
        let scheduleBackgroundAfterLoad = scheduleBackground
        let excluded = visibleSet.union(nearVisible)
        let needsBackgroundSweep = offscreenPathsNeedLoading(excluded: excluded)
        visibleThumbnailLoadGeneration += 1
        let loadGeneration = visibleThumbnailLoadGeneration

        // Reprioritize before starting loads. Starting loads first (then reprioritizing) cancels
        // in-flight decodes without retry — common after disk cache clear / tree "Clear cache".
        Task { @MainActor in
            guard loadGeneration == self.visibleThumbnailLoadGeneration else { return }
            if visiblePaths != self.lastVisiblePathsForReprioritize {
                await appState.thumbnailCache.reprioritizeForViewport(
                    orderedVisiblePaths: visiblePaths,
                    orderedNearPaths: nearPaths
                )
                self.lastVisiblePathsForReprioritize = visiblePaths
            }
            guard loadGeneration == self.visibleThumbnailLoadGeneration else { return }

            var loadRequests = 0
            for (order, path) in visiblePaths.enumerated() {
                loadRequests += 1
                self.requestThumbnailLoad(
                    for: path,
                    priority: .visible,
                    queueOrder: order
                )
            }
            for (order, path) in nearPaths.enumerated() {
                loadRequests += 1
                self.requestThumbnailLoad(
                    for: path,
                    priority: .nearVisible,
                    queueOrder: order
                )
            }
            ThumbnailGridPerfDiagnostics.recordThumbnailLoadRequests(count: loadRequests)

            let maySweep = allowBackgroundSweep && self.shouldScheduleAutomaticBackgroundSweep()
            if scheduleBackgroundAfterLoad,
               maySweep,
               !self.backgroundLoadingSuspended,
               needsBackgroundSweep {
                self.scheduleBackgroundThumbnailLoading(excluded: excluded)
            }
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
            fillColor = themeColors.thumbnailGridBackground.nsColor
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
        let overlayBandHeight = overlayHeight(for: index, path: path)
        guard overlayBandHeight > 0 else { return }

        let labelRect = NSRect(
            x: cell.minX + 4,
            y: cell.minY + cell.height - overlayBandHeight,
            width: max(0, cell.width - 8),
            height: overlayBandHeight
        )

        let wrappedLines = resolvedOverlayLines(for: index, path: path, labelWidth: labelRect.width)
        guard !wrappedLines.isEmpty else { return }

        let font = ThumbnailFilenameOverlayService.overlayFont
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
            .foregroundColor: themeColors.thumbnailText.nsColor,
            .paragraphStyle: paragraph,
        ]
        var y = pillRect.minY + 2
        for line in wrappedLines {
            let lineWidth = ThumbnailFontMetricsCache.advanceWidth(for: line, font: font)
            let drawX = pillRect.midX - lineWidth / 2
            let drawY = y + (lineHeight - font.boundingRectForFont.height) / 2
            (line as NSString).draw(at: NSPoint(x: drawX, y: drawY), withAttributes: attrs)
            y += lineHeight
        }
    }

    private func ensureImageDimensionsCached(for path: String) {
        guard showImageSize else { return }
        guard appState?.metadataCache.cachedPixelSize(path: path) == nil else { return }
        appState?.metadataCache.ensurePixelSizeCached(path: path)
        noteImageDimensionsAvailable(for: path)
    }

    private func noteImageDimensionsAvailable(for path: String) {
        guard showImageSize else { return }
        guard let dims = appState?.metadataCache.cachedPixelSize(path: path),
              dims.width > 0, dims.height > 0 else {
            return
        }
        let text = "\(dims.width)x\(dims.height)"
        if imageDimensionCache[path] == text { return }
        imageDimensionCache[path] = text
        if let paintIndex = imagePaths.firstIndex(of: path) {
            setNeedsDisplay(thumbnailRect(for: paintIndex))
        }
    }

    private func dimensionText(for path: String) -> String? {
        if let cached = imageDimensionCache[path] { return cached }
        guard let dims = appState?.metadataCache.cachedPixelSize(path: path),
              dims.width > 0, dims.height > 0 else {
            return nil
        }
        let text = "\(dims.width)x\(dims.height)"
        imageDimensionCache[path] = text
        return text
    }

    /// Insertion index from pointer position using the same cell frames as painting (`cellFrame`).
    private func insertionIndex(at point: NSPoint) -> Int {
        let count = imagePaths.count
        guard count > 0 else { return 0 }
        for index in 0..<count {
            let cell = cellFrame(for: index)
            if point.y < cell.minY {
                return index
            }
            if cell.minY <= point.y, point.y <= cell.maxY, point.x < cell.midX {
                return index
            }
        }
        return count
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

        if insertion >= imagePaths.count {
            let last = cellFrame(for: imagePaths.count - 1)
            let x = last.maxX + ThumbnailLayout.horizontalSpacing
            return NSRect(x: x - 1, y: last.minY, width: 2, height: last.height)
        }
        let cell = cellFrame(for: insertion)
        return NSRect(x: cell.minX - 1, y: cell.minY, width: 2, height: cell.height)
    }

    private func drawDropIndicator(in rect: NSRect) {
        themeColors.currentImageBorder.nsColor.withAlphaComponent(0.85).setFill()
        rect.fill()
    }

    private func drawPlaceholder(for path: String, in rect: NSRect) {
        let ext = (path as NSString).pathExtension.uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: themeColors.thumbnailText.nsColor,
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
        guard let index = FileDataModel.indexOfPath(path, in: imagePaths) else { return }
        if !showFilenames, !showImageSize {
            showFilenames = true
            reloadLayout()
            DispatchQueue.main.async { [weak self] in
                self?.beginInlineRename(path: path)
            }
            return
        }
        guard let editorRect = inlineRenameEditorRect(for: index) else { return }
        cancelInlineRename(restoreFocus: false)
        selectIndex(index, scroll: true, notifyDelegate: false)
        layoutSubtreeIfNeeded()
        let basename = URL(fileURLWithPath: imagePaths[index]).deletingPathExtension().lastPathComponent
        let editor = NSTextField(frame: editorRect)
        editor.stringValue = basename
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = true
        editor.backgroundColor = overlayBoxColor
        editor.textColor = themeColors.thumbnailText.nsColor
        editor.font = NSFont(name: "Arial", size: 13) ?? NSFont.systemFont(ofSize: 13)
        editor.focusRingType = .none
        editor.wantsLayer = true
        applyRenameEditorBorder(editor: editor, valid: true)
        editor.delegate = self
        addSubview(editor, positioned: .above, relativeTo: nil)
        renameEditor = editor
        renameEditingPath = imagePaths[index]
        renameCanceled = false
        editor.selectText(nil)
        window?.makeFirstResponder(editor)
    }

    private func applyRenameEditorBorder(editor: NSTextField, valid: Bool) {
        editor.layer?.borderWidth = 2
        editor.layer?.borderColor = (valid
            ? NSColor(red: 135 / 255, green: 206 / 255, blue: 235 / 255, alpha: 1)
            : NSColor(red: 220 / 255, green: 50 / 255, blue: 50 / 255, alpha: 1)).cgColor
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
        if renameCanceled {
            renameCanceled = false
            cancelInlineRename()
            return
        }
        guard let editor = renameEditor, let originalPath = renameEditingPath else { return }
        let newBase = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalBase = URL(fileURLWithPath: originalPath).deletingPathExtension().lastPathComponent
        if newBase.isEmpty || newBase == originalBase {
            cancelInlineRename()
            return
        }
        if let error = FileOperationsService.validateMacOSFilenameBase(newBase) {
            appState?.status.show(error)
            applyRenameEditorBorder(editor: editor, valid: false)
            editor.selectText(nil)
            return
        }
        cancelInlineRename()
        onInlineRenameCommitted?(originalPath, newBase)
    }

    /// Pill rect matching `drawOverlay` (for hit-testing rename on the label).
    private func filenamePillRect(for index: Int) -> NSRect? {
        guard imagePaths.indices.contains(index) else { return nil }
        let path = imagePaths[index]
        let cell = cellFrame(for: index)
        let overlayBandHeight = overlayHeight(for: index, path: path)
        guard overlayBandHeight > 0 else { return nil }

        let labelRect = NSRect(
            x: cell.minX + 4,
            y: cell.minY + cell.height - overlayBandHeight,
            width: max(0, cell.width - 8),
            height: overlayBandHeight
        )
        let wrappedLines = resolvedOverlayLines(for: index, path: path, labelWidth: labelRect.width)
        guard !wrappedLines.isEmpty else { return nil }

        let lineHeight = ThumbnailLayout.labelHeight
        let totalTextHeight = CGFloat(wrappedLines.count) * lineHeight
        return NSRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: labelRect.width,
            height: min(labelRect.height, totalTextHeight + 4)
        )
    }

    /// Single-line editor band aligned with the basename line in the pill (F2 / overlay click).
    private func inlineRenameEditorRect(for index: Int) -> NSRect? {
        guard let pill = filenamePillRect(for: index) else {
            let cell = cellFrame(for: index)
            return NSRect(
                x: cell.minX + 4,
                y: cell.minY + 4,
                width: max(40, cell.width - 8),
                height: 22
            )
        }
        let path = imagePaths[index]
        let lines = resolvedOverlayLines(for: index, path: path, labelWidth: pill.width)
        let lineHeight = ThumbnailLayout.labelHeight
        var firstBasenameLine = 0
        if isDuplicateSectionMode, showFilenames {
            if let separatorIndex = lines.firstIndex(where: { $0.contains("──────────") }) {
                firstBasenameLine = min(separatorIndex + 1, max(0, lines.count - 1))
            }
        } else if showFilenames, showImageSize, lines.count > 1,
                  lines.last?.contains("x") == true,
                  lines.last?.first?.isNumber == true {
            // Dimension line is last; edit basename on the first filename line.
            firstBasenameLine = 0
        }
        let y = pill.minY + 2 + CGFloat(firstBasenameLine) * lineHeight
        return NSRect(
            x: pill.minX + 4,
            y: y,
            width: max(40, pill.width - 8),
            height: lineHeight + 2
        )
    }

    private func resolvedOverlayLines(for index: Int, path: String, labelWidth: CGFloat) -> [String] {
        var wrappedLines = wrappedOverlayLines(for: index, path: path)
        if wrappedLines.isEmpty, showFilenames || showImageSize {
            let overlay = ThumbnailFilenameOverlayService.overlay(
                for: path,
                cellWidth: labelWidth + 8,
                showFilename: showFilenames,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                displayStyle: isDuplicateSectionMode ? .duplicatePath : .basename,
                wrapMode: isDuplicateSectionMode || isExifSectionMode
                    ? .sectionedMax(thumbnailSize: thumbnailGenerationPixelSize())
                    : .cellWidth
            )
            wrappedLines = ThumbnailFilenameOverlayService.linesForDrawing(
                overlay: overlay,
                path: path,
                showImageSize: showImageSize,
                dimensionText: dimensionText(for: path)
            )
        }
        return wrappedLines
    }

    private func filenameOverlayRect(for index: Int) -> NSRect? {
        inlineRenameEditorRect(for: index)
    }
}

extension ThumbnailGridNSView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameCanceled = true
            cancelInlineRename()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineRename()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = renameEditor else { return }
        let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = FileOperationsService.validateMacOSFilenameBase(text) == nil
        applyRenameEditorBorder(editor: editor, valid: valid)
    }

}
