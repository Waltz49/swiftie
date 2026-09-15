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
        gridView.onInlineRenameCommitted = { [weak appState] originalPath, newName in
            guard let appState else { return }
            Task { @MainActor in
                do {
                    let newPath = try appState.fileOperations.rename(path: originalPath, to: newName)
                    appState.fileData.setCurrentImagePath(newPath)
                    appState.selection.selectedFiles = [newPath]
                    appState.status.show("Renamed to \(newName)")
                } catch {
                    StyledMessageDialog.showInformation(
                        title: "Rename Failed",
                        message: error.localizedDescription
                    )
                }
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
        context.coordinator.syncFromAppState()
    }

    @MainActor
    final class Coordinator: NSObject, ThumbnailGridDelegate {
        let appState: AppState
        weak var gridView: ThumbnailGridNSView?
        weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var layoutObserver: UUID?
        private var navigateObserver: UUID?
        private var viewModeObserver: NSObjectProtocol?
        private var filterPatternObserver: NSObjectProtocol?
        private var directoryObserver: NSObjectProtocol?
        private var displayedImagesObserver: NSObjectProtocol?
        private var settingsObserver: UUID?
        private var thumbnailsInvalidatedObserver: UUID?
        private var fileOperationObserver: UUID?
        private var deletedPlaceholdersObserver: UUID?
        private var selectionObserver: NSObjectProtocol?
        private var lastSyncedIndex = -1
        private var lastSyncedDirectory: String?

        init(appState: AppState) {
            self.appState = appState
        }

        func startObserving(appState: AppState) {
            guard navigateObserver == nil else { return }
            navigateObserver = appState.eventBus.subscribe(.thumbnailNavigate) { [weak self] event in
                guard case .thumbnailDirection(let direction) = event.payload else { return }
                Task { @MainActor in self?.handleNavigate(direction) }
            }
            if viewModeObserver == nil {
                viewModeObserver = NotificationCenter.default.addObserver(
                    forName: .prowserViewModeChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let mode = notification.object as? String,
                          mode == ViewMode.thumbnail.rawValue else { return }
                    let coordinator = self
                    Task { @MainActor in coordinator?.ensureHighlightedVisible() }
                }
            }
            if filterPatternObserver == nil {
                filterPatternObserver = NotificationCenter.default.addObserver(
                    forName: .prowserFilterPatternChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let coordinator = self
                    Task { @MainActor in coordinator?.syncFromAppState() }
                }
            }
            if directoryObserver == nil {
                directoryObserver = NotificationCenter.default.addObserver(
                    forName: .prowserDirectoryChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let coordinator = self
                    Task { @MainActor in coordinator?.syncFromAppState() }
                }
            }
            if displayedImagesObserver == nil {
                displayedImagesObserver = NotificationCenter.default.addObserver(
                    forName: .prowserDisplayedImagesChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let coordinator = self
                    Task { @MainActor in coordinator?.syncFromAppState() }
                }
            }
            if thumbnailsInvalidatedObserver == nil {
                thumbnailsInvalidatedObserver = appState.eventBus.subscribe(.thumbnailsInvalidated) { [weak self] event in
                    guard case .strings(let paths) = event.payload else { return }
                    Task { @MainActor in self?.handleThumbnailsInvalidated(paths) }
                }
            }
            if settingsObserver == nil {
                settingsObserver = appState.eventBus.subscribe(.settingsChanged) { [weak self] _ in
                    Task { @MainActor in self?.syncFromAppState() }
                }
            }
            if fileOperationObserver == nil {
                fileOperationObserver = appState.eventBus.subscribe(.fileOperationComplete) { [weak self] _ in
                    Task { @MainActor in self?.restoreKeyboardFocusAfterFileOperation() }
                }
            }
            if selectionObserver == nil {
                selectionObserver = NotificationCenter.default.addObserver(
                    forName: .prowserSelectionChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let coordinator = self
                    Task { @MainActor in
                        coordinator?.syncSelectionVisuals()
                        coordinator?.appState.refreshMenuState()
                    }
                }
            }
            if deletedPlaceholdersObserver == nil {
                deletedPlaceholdersObserver = appState.eventBus.subscribe(.deletedPlaceholdersChanged) { [weak self] _ in
                    Task { @MainActor in self?.syncDeletedPlaceholders() }
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
            if layoutObserver == nil {
                layoutObserver = appState.eventBus.subscribe(.mainContentLayoutChanged) { [weak self] _ in
                    Task { @MainActor in
                        self?.gridView?.noteContainerSizeChanged()
                    }
                }
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            if let viewModeObserver {
                NotificationCenter.default.removeObserver(viewModeObserver)
            }
            if let filterPatternObserver {
                NotificationCenter.default.removeObserver(filterPatternObserver)
            }
            if let directoryObserver {
                NotificationCenter.default.removeObserver(directoryObserver)
            }
            if let displayedImagesObserver {
                NotificationCenter.default.removeObserver(displayedImagesObserver)
            }
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        private func handleThumbnailsInvalidated(_ paths: [String]) {
            gridView?.invalidateThumbnails(for: paths)
        }

        func syncFromAppState() {
            guard let gridView else { return }
            let paths = appState.fileData.displayedImages
            if let scrollView {
                ThumbnailScrollAreaChrome.apply(to: scrollView, colors: appState.theme.colors)
            }
            gridView.applyTheme(appState.theme.colors)
            let directory = appState.fileData.currentDirectory
            if lastSyncedDirectory != directory {
                gridView.clearThumbnails()
                lastSyncedDirectory = directory
                lastSyncedIndex = -1
            }
            gridView.currentDirectory = directory
            gridView.filterPattern = appState.filterSettings.filterPattern
            gridView.imageExtensions = appState.config.imageExtensions
            if gridView.imagePaths != paths {
                gridView.pruneThumbnails(keeping: Set(paths))
                gridView.imagePaths = paths
                lastSyncedIndex = -1
            }
            gridView.referenceGraph = appState.referenceGraphActive ? appState.referenceGraphData : nil
            gridView.deletedPlaceholderPaths = appState.deletedFilePlaceholders
            gridView.updateEmptyStateContext()
            let index = resolvedHighlightIndex(in: paths)
            let inThumbnailMode = appState.fileData.currentViewMode == .thumbnail
            gridView.wrapAround = appState.config.bool(forKey: "wrap_around", default: true)
            gridView.showFilenames = appState.config.bool(forKey: "thumbnail_filename_visible", default: false)
            gridView.showImageSize = appState.config.bool(forKey: "show_image_size", default: false)
            gridView.showExtensions = appState.config.bool(forKey: "show_extensions", default: true)
            gridView.overlayBoxColor = appState.theme.colors.thumbnailFilenameOverlay.nsColor
            gridView.reloadLayoutIfNeeded()
            appState.thumbnailGridColumns = gridView.gridColumnCount
            if index != lastSyncedIndex {
                gridView.selectIndex(index, scroll: inThumbnailMode, notifyDelegate: false)
                lastSyncedIndex = index
            } else {
                gridView.currentIndex = index
                if inThumbnailMode {
                    gridView.scrollToSelectionAfterLayout()
                }
            }
            syncSelectionVisuals(to: gridView)
            if inThumbnailMode,
               !KeyboardHandlerController.fileTreeKeyboardTargetIsFocused(in: gridView.window) {
                gridView.claimKeyboardFocus()
            }
        }

        private func syncDeletedPlaceholders() {
            guard let gridView else { return }
            gridView.deletedPlaceholderPaths = appState.deletedFilePlaceholders
            gridView.needsDisplay = true
        }

        private func syncSelectionVisuals(to gridView: ThumbnailGridNSView? = nil) {
            let gridView = gridView ?? self.gridView
            guard let gridView else { return }
            gridView.selectedIndices = SelectionService.selectedIndices(appState: appState)
            gridView.multiSelectMode = appState.selection.multiSelectMode
            gridView.needsDisplay = true
        }

        private func resolvedHighlightIndex(in paths: [String]) -> Int {
            if let path = appState.fileData.currentImagePath,
               let index = paths.firstIndex(of: path) {
                return index
            }
            return appState.fileData.currentIndex
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

        func thumbnailGridDidActivateBrowse() {
            SelectionService.openBrowseFromThumbnailActivation(
                appState: appState,
                isDoubleClick: false
            )
        }

        func thumbnailGridDidOpenBrowse(index: Int, path: String) {
            lastSyncedIndex = index
            SelectionService.openBrowseFromThumbnailActivation(
                appState: appState,
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

        func thumbnailGridNeedsThumbnail(path: String, size: Int, completion: @escaping (NSImage?) -> Void) {
            Task { @MainActor in
                let result = await appState.thumbnailCache.generateThumbnailResult(for: path, size: size)
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

        func thumbnailGridDidUpdateLayout(columns: Int) {
            appState.thumbnailGridColumns = max(1, columns)
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
