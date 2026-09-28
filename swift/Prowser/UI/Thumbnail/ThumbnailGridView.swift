import AppKit
import SwiftUI

/// Match Python ``apply_thumbnail_scroll_area_chrome`` (grid-colored viewport, not shell ``background``).
enum ThumbnailScrollAreaChrome {
    static func apply(to scrollView: NSScrollView, colors: ThemeColors) {
        let background = colors.thumbnailGridBackground.nsColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        let clip = scrollView.contentView
        clip.drawsBackground = true
        clip.backgroundColor = background
    }
}

struct ThumbnailGridView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        ThumbnailScrollAreaChrome.apply(to: scrollView, colors: appState.theme.colors)

        let gridView = ThumbnailGridNSView(frame: .zero)
        gridView.gridDelegate = context.coordinator
        gridView.configSource = appState.config
        gridView.appState = appState
        gridView.onInlineRenameCommitted = { [weak appState] originalPath, newBaseName in
            guard let appState else { return }
            let outcome = appState.fileOperations.commitFileRename(path: originalPath, newBaseName: newBaseName)
            switch outcome {
            case .unchanged:
                break
            case .renamed(_, let displayName):
                appState.status.show("Renamed to \(displayName)")
            case .keepEditing(let message):
                appState.status.show(message)
                appState.thumbnailGridHost?.beginInlineRename(path: originalPath)
            case .blocked(let title, let message):
                StyledMessageDialog.showInformation(title: title, message: message)
            }
        }
        scrollView.documentView = gridView
        context.coordinator.gridView = gridView
        appState.thumbnailGridHost = gridView
        context.coordinator.scrollView = scrollView
        context.coordinator.observeScrollView(scrollView)
        context.coordinator.startObserving(appState: appState)
        context.coordinator.syncFromAppState()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Observers handle directory/filter/displayed/settings; this coalesces other AppState changes.
        _ = appState.isLoadingDirectory
        _ = appState.showThumbnailDirectoryLoadingCanvas
        _ = appState.config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
        _ = appState.config.bool(forKey: "manual_thumbnail_size", default: false)
        context.coordinator.syncFromAppStateIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, ThumbnailGridDelegate {
        let appState: AppState
        weak var gridView: ThumbnailGridNSView?
        weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var eventSubscriptions: EventBusSubscriptionBag?
        private var lastSyncedIndex = -1
        private var lastSyncedDirectory: String?
        private var lastGridSyncFingerprint: GridSyncFingerprint?
        private var lastSelectionFingerprint: SelectionFingerprint?
        private var lastSyncedThemeID: String?

        /// Fields that drive grid layout, paths, theme, and highlight — not selection chrome alone.
        private struct GridSyncFingerprint: Equatable {
            var themeID: String
            var directory: String?
            var filterPattern: String
            var imagePaths: [String]
            var referenceGraphActive: Bool
            var referenceGraphPathCount: Int
            var referenceGraphEdgeCount: Int
            var referenceGraphFocusPath: String?
            var deletedPlaceholders: Set<String>
            var highlightIndex: Int
            var viewMode: ViewMode
            var wrapAround: Bool
            var showFilenames: Bool
            var showImageSize: Bool
            var showExtensions: Bool
            var imageExtensions: [String]
            var duplicateSections: [DuplicateGroupPresentation.DuplicateSection]
            var exifDateSections: [ExifSectionPresentation.Section]
            var sortMode: String
            var showDirectoryLoadingCanvas: Bool
            var thumbnailCellSize: Double
            var manualThumbnailSize: Bool
            var thumbnailLockPaintRevision: Int
        }

        private struct SelectionFingerprint: Equatable {
            var selectedIndices: Set<Int>
            var multiSelectMode: Bool
        }

        init(appState: AppState) {
            self.appState = appState
        }

        func startObserving(appState: AppState) {
            guard eventSubscriptions == nil else { return }
            let bag = EventBusSubscriptionBag(bus: appState.eventBus)
            eventSubscriptions = bag
            bag.subscribe(.thumbnailNavigate) { [weak self] event in
                guard case .thumbnailDirection(let direction) = event.payload else { return }
                self?.handleNavigate(direction)
            }
            bag.subscribe(.viewModeChanged) { [weak self] event in
                guard let self, case .string(let mode) = event.payload else { return }
                self.applyThumbnailLoadingActive(mode == ViewMode.thumbnail.rawValue)
                if mode == ViewMode.thumbnail.rawValue {
                    self.lastSyncedIndex = -1
                    self.ensureHighlightedVisible()
                }
            }
            bag.subscribe(.filterPatternChanged) { [weak self] _ in
                self?.syncFromAppState()
            }
            bag.subscribe(.directoryChanged) { [weak self] _ in
                self?.syncFromAppState()
            }
            bag.subscribe(.displayedImagesChanged) { [weak self] _ in
                self?.syncFromAppState()
            }
            bag.subscribe(.thumbnailsInvalidated) { [weak self] event in
                guard case .strings(let paths) = event.payload else { return }
                self?.handleThumbnailsInvalidated(paths)
            }
            bag.subscribe(.settingsChanged) { [weak self] _ in
                self?.syncFromAppState()
            }
            bag.subscribe(.fileOperationComplete) { [weak self] _ in
                self?.restoreKeyboardFocusAfterFileOperation()
            }
            // Selection is not part of `GridSyncFingerprint`; keep this observer instead of full grid sync.
            bag.subscribe(.selectionChanged) { [weak self] _ in
                guard let self else { return }
                self.syncSelectionVisualsIfNeeded()
                self.appState.refreshMenuState()
            }
            bag.subscribe(.deletedPlaceholdersChanged) { [weak self] _ in
                guard let self else { return }
                self.syncDeletedPlaceholders()
                if self.appState.isFormattedListMode(),
                   !self.appState.duplicateSections.isEmpty || !self.appState.exifDateSections.isEmpty {
                    self.gridView?.reloadLayoutIfNeeded()
                    self.gridView?.publishNavigationLayoutToAppState()
                }
            }
        }

        private func restoreKeyboardFocusAfterFileOperation() {
            guard appState.fileData.currentViewMode == .thumbnail else { return }
            syncFromAppState()
            claimKeyboardFocus()
        }

        func claimKeyboardFocus() {
            gridView?.claimKeyboardFocus()
        }

        func handleNavigate(_ direction: ThumbnailNavigateDirection) {
            if KeyboardHandlerController.preferencesPanelOwnsKeyboardFocus(appState: appState) {
                return
            }
            KeyboardInputTracer.log(
                "ThumbnailGrid.Coordinator.handleNavigate \(direction)",
                config: appState.config
            )
            guard appState.fileData.currentViewMode == .thumbnail else { return }
            gridView?.navigate(direction)
        }

        func observeScrollView(_ scrollView: NSScrollView) {
            if boundsObserver != nil { return }
            guard let gridView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak gridView] _ in
                let view = gridView
                Task { @MainActor in
                    view?.noteVisibleRectChanged()
                }
            }
            scrollView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak gridView] _ in
                let view = gridView
                Task { @MainActor in
                    view?.noteContainerSizeChanged()
                }
            }
            eventSubscriptions?.subscribe(.mainContentLayoutChanged) { [weak self] _ in
                self?.gridView?.noteContainerSizeChanged()
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        private func handleThumbnailsInvalidated(_ paths: [String]) {
            gridView?.invalidateThumbnails(for: paths)
        }

        func syncFromAppState() {
            syncFromAppState(force: true)
        }

        func syncFromAppStateIfNeeded() {
            syncFromAppState(force: false)
        }

        private func syncFromAppState(force: Bool) {
            guard let gridView else { return }
            let paths = appState.showThumbnailDirectoryLoadingCanvas ? [] : appState.fileData.displayedImages
            let index = resolvedHighlightIndex(in: paths)
            let fingerprint = GridSyncFingerprint(
                themeID: appState.theme.colors.themeID,
                directory: appState.fileData.currentDirectory,
                filterPattern: appState.filterSettings.filterPattern,
                imagePaths: paths,
                referenceGraphActive: appState.referenceGraphActive,
                referenceGraphPathCount: appState.referenceGraphData?.nodes.count ?? 0,
                referenceGraphEdgeCount: appState.referenceGraphData?.edges.count ?? 0,
                referenceGraphFocusPath: appState.referenceGraphFocusPath,
                deletedPlaceholders: appState.deletedFilePlaceholders,
                highlightIndex: index,
                viewMode: appState.fileData.currentViewMode,
                wrapAround: appState.config.bool(forKey: "wrap_around", default: true),
                showFilenames: appState.config.bool(forKey: "thumbnail_filename_visible", default: false),
                showImageSize: appState.config.bool(forKey: "show_image_size", default: false),
                showExtensions: appState.config.bool(forKey: "show_extensions", default: true),
                imageExtensions: appState.config.imageExtensions,
                duplicateSections: appState.duplicateSections,
                exifDateSections: appState.exifDateSections,
                sortMode: appState.config.string(forKey: "sort_mode", default: SortMode.date.rawValue),
                showDirectoryLoadingCanvas: appState.showThumbnailDirectoryLoadingCanvas,
                thumbnailCellSize: appState.config.double(
                    forKey: "thumbnail_cell_size",
                    default: ThumbnailLayout.defaultCellSize
                ),
                manualThumbnailSize: appState.config.bool(forKey: "manual_thumbnail_size", default: false),
                thumbnailLockPaintRevision: appState.thumbnailLockPaintRevision
            )
            if !force, fingerprint == lastGridSyncFingerprint {
                syncSelectionVisualsIfNeeded(to: gridView)
                return
            }
            let pathsChanged = fingerprint.imagePaths != lastGridSyncFingerprint?.imagePaths
            lastGridSyncFingerprint = fingerprint
            if pathsChanged {
                lastSelectionFingerprint = nil
            }

            if force || fingerprint.themeID != lastSyncedThemeID {
                if let scrollView {
                    ThumbnailScrollAreaChrome.apply(to: scrollView, colors: appState.theme.colors)
                }
                gridView.applyTheme(appState.theme.colors)
                lastSyncedThemeID = fingerprint.themeID
            }

            let directory = appState.fileData.currentDirectory
            if lastSyncedDirectory != directory {
                gridView.clearThumbnails()
                lastSyncedDirectory = directory
                lastSyncedIndex = -1
            }
            gridView.currentDirectory = directory
            gridView.filterPattern = appState.filterSettings.filterPattern
            gridView.isLoadingDirectory = fingerprint.showDirectoryLoadingCanvas
            gridView.imageExtensions = appState.config.imageExtensions
            if gridView.imagePaths != paths {
                gridView.pruneThumbnails(keeping: Set(paths))
                gridView.imagePaths = paths
                lastSyncedIndex = -1
            }
            gridView.referenceGraph = appState.referenceGraphActive ? appState.referenceGraphData : nil
            let duplicateMode = fingerprint.sortMode == SortMode.duplicates.rawValue
            let exifMode = fingerprint.sortMode == SortMode.exifDate.rawValue
                || fingerprint.sortMode == SortMode.exifYear.rawValue
            gridView.isDuplicateSectionMode = duplicateMode && !fingerprint.duplicateSections.isEmpty
            gridView.duplicateSections = fingerprint.duplicateSections
            gridView.isExifSectionMode = exifMode && !fingerprint.exifDateSections.isEmpty
            gridView.exifDateSections = fingerprint.exifDateSections
            gridView.deletedPlaceholderPaths = appState.deletedFilePlaceholders
            gridView.updateEmptyStateContext()
            let inThumbnailMode = appState.fileData.currentViewMode == .thumbnail
            applyThumbnailLoadingActive(inThumbnailMode && !fingerprint.showDirectoryLoadingCanvas, gridView: gridView)
            gridView.wrapAround = fingerprint.wrapAround
            if !gridView.isInlineRenaming {
                gridView.showFilenames = fingerprint.showFilenames
            }
            gridView.showImageSize = fingerprint.showImageSize
            gridView.showExtensions = fingerprint.showExtensions
            gridView.overlayBoxColor = appState.theme.colors.thumbnailFilenameOverlay.nsColor
            gridView.reloadLayoutIfNeeded()
            if canvasLayoutUsesRowNavigation(gridView) {
                gridView.publishNavigationLayoutToAppState()
            }
            let columns = max(1, gridView.gridColumnCount)
            if appState.thumbnailGridColumns != columns {
                appState.thumbnailGridColumns = columns
            }
            if index != lastSyncedIndex {
                gridView.selectIndex(index, scroll: inThumbnailMode, notifyDelegate: false)
                lastSyncedIndex = index
            } else {
                gridView.currentIndex = index
            }
            syncSelectionVisualsIfNeeded(to: gridView)
            if inThumbnailMode {
                gridView.startBackgroundThumbnailLoadingIfNeeded()
            }
            if inThumbnailMode,
               !gridView.isInlineRenaming,
               !KeyboardHandlerController.fileTreeKeyboardTargetIsFocused(in: gridView.window) {
                gridView.claimKeyboardFocus()
            }
        }

        private func applyThumbnailLoadingActive(_ active: Bool, gridView: ThumbnailGridNSView? = nil) {
            let gridView = gridView ?? self.gridView
            guard let gridView else { return }
            gridView.thumbnailLoadingActive = active
        }

        private func syncDeletedPlaceholders() {
            guard let gridView else { return }
            gridView.deletedPlaceholderPaths = appState.deletedFilePlaceholders
            gridView.needsDisplay = true
        }

        private func syncSelectionVisualsIfNeeded(to gridView: ThumbnailGridNSView? = nil) {
            let gridView = gridView ?? self.gridView
            guard let gridView else { return }
            let fingerprint = SelectionFingerprint(
                selectedIndices: SelectionService.selectedIndices(appState: appState),
                multiSelectMode: appState.selection.multiSelectMode
            )
            guard fingerprint != lastSelectionFingerprint else { return }
            lastSelectionFingerprint = fingerprint
            gridView.selectedIndices = fingerprint.selectedIndices
            gridView.multiSelectMode = fingerprint.multiSelectMode
            gridView.needsDisplay = true
        }

        private func canvasLayoutUsesRowNavigation(_ gridView: ThumbnailGridNSView) -> Bool {
            !gridView.imagePaths.isEmpty
                && gridView.referenceGraph == nil
        }

        private func resolvedHighlightIndex(in paths: [String]) -> Int {
            if let path = appState.fileData.currentImagePath,
               let index = FileDataModel.indexOfPath(path, in: paths) {
                return index
            }
            return min(max(0, appState.fileData.currentIndex), max(0, paths.count - 1))
        }

        private func ensureHighlightedVisible() {
            guard appState.fileData.currentViewMode == .thumbnail else { return }
            guard let gridView else { return }
            let paths = appState.fileData.displayedImages
            guard !paths.isEmpty else { return }

            let index = resolvedHighlightIndex(in: paths)
            lastSyncedIndex = index
            gridView.selectIndex(index, scroll: false, notifyDelegate: false)
            gridView.scrollToSelectionAfterLayout()
            if !KeyboardHandlerController.fileTreeKeyboardTargetIsFocused(in: gridView.window) {
                gridView.claimKeyboardFocus()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak gridView] in
                gridView?.scrollToSelectionAfterLayout()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak gridView] in
                gridView?.scrollToSelectionAfterLayout()
            }
        }

        func thumbnailGridDidSelect(index: Int, path: String) {
            lastSyncedIndex = index
            if appState.selection.multiSelectMode {
                SelectionService.clearSelection(appState: appState)
            }
            SelectionService.selectThumbnail(appState: appState, index: index, addToSelection: false)
        }

        func thumbnailGridDidClick(
            index: Int,
            path: String,
            shiftPressed: Bool,
            cmdPressed: Bool,
            ctrlPressed: Bool
        ) {
            lastSyncedIndex = index
            SelectionService.handleThumbnailClick(
                appState: appState,
                index: index,
                cmdPressed: cmdPressed,
                shiftPressed: shiftPressed,
                ctrlPressed: ctrlPressed
            )
        }

        func thumbnailGridDidActivateBrowse(path: String) {
            SelectionService.openBrowseFromThumbnailActivation(
                appState: appState,
                path: path,
                isDoubleClick: false
            )
        }

        func thumbnailGridDidOpenBrowse(path: String) {
            if let index = appState.fileData.displayedImages.firstIndex(of: path) {
                lastSyncedIndex = index
            }
            SelectionService.openBrowseFromThumbnailActivation(
                appState: appState,
                path: path,
                isDoubleClick: true
            )
        }

        func thumbnailGridDidReorder(path: String, insertionIndex: Int) {
            _ = ThumbnailReorderService.reorder(
                imagePath: path,
                insertionIndex: insertionIndex,
                appState: appState
            )
        }

        func thumbnailGridNeedsThumbnail(
            path: String,
            size: Int,
            priority: ThumbnailLoadPriority,
            queueOrder: Int,
            backgroundLoadSession: UInt64?,
            completion: @escaping (NSImage?) -> Void
        ) {
            Task { @MainActor in
                let result = await appState.thumbnailCache.generateThumbnailResult(
                    for: path,
                    size: size,
                    priority: priority,
                    queueOrder: queueOrder,
                    backgroundLoadSession: backgroundLoadSession
                )
                let image = result.map {
                    NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height))
                }
                if let result, result.originalWidth > 0, result.originalHeight > 0 {
                    appState.metadataCache.storePixelSize(
                        path: path,
                        width: result.originalWidth,
                        height: result.originalHeight
                    )
                }
                completion(image)
            }
        }

        func thumbnailGridShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView) {
            ThumbnailContextMenu.show(for: event, clickedIndex: clickedIndex, in: view, appState: appState)
        }

        func thumbnailGridDidUpdateLayout(
            columns: Int,
            sectionedRowLayout: ThumbnailSectionedLayout.RowLayout?
        ) {
            let value = max(1, columns)
            if appState.thumbnailGridColumns != value {
                appState.thumbnailGridColumns = value
            }
            if appState.thumbnailSectionedRowLayout != sectionedRowLayout {
                appState.thumbnailSectionedRowLayout = sectionedRowLayout
            }
        }

        func thumbnailGridDidApplyFilter(label: String) {
            let pattern: String
            if label == "All files(*)" {
                pattern = "*"
            } else {
                pattern = FilterPatternFormatting.normalizeForMatching(label)
            }
            appState.applyFilenameFilterPattern(pattern)
        }
    }
}
