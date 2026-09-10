import AppKit
import SwiftUI

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
        scrollView.drawsBackground = false

        let gridView = ThumbnailGridNSView(frame: .zero)
        gridView.gridDelegate = context.coordinator
        gridView.configSource = appState.config
        scrollView.documentView = gridView
        context.coordinator.gridView = gridView
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
        private var lastSyncedIndex = -1

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
        }

        func claimKeyboardFocus() {
            gridView?.claimKeyboardFocus()
        }

        func handleNavigate(_ direction: ThumbnailNavigateDirection) {
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
        }

        func syncFromAppState() {
            guard let gridView else { return }
            let paths = appState.fileData.displayedImages
            gridView.emptyStateStyle = ThumbnailEmptyStateStyle.from(theme: appState.theme.colors)
            gridView.currentDirectory = appState.fileData.currentDirectory
            gridView.filterPattern = appState.filterSettings.filterPattern
            gridView.imageExtensions = appState.config.imageExtensions
            if gridView.imagePaths != paths {
                gridView.imagePaths = paths
                gridView.clearThumbnails()
                lastSyncedIndex = -1
            }
            gridView.updateEmptyStateContext()
            let index = resolvedHighlightIndex(in: paths)
            let inThumbnailMode = appState.fileData.currentViewMode == .thumbnail
            gridView.wrapAround = appState.config.bool(forKey: "wrap_around", default: true)
            gridView.showFilenames = appState.config.bool(forKey: "thumbnail_filename_visible", default: false)
            gridView.showImageSize = appState.config.bool(forKey: "show_image_size", default: false)
            gridView.overlayBoxColor = NSColor(appState.theme.colors.thumbnailFilenameOverlay)
            gridView.reloadLayout()
            if index != lastSyncedIndex {
                gridView.selectIndex(index, scroll: inThumbnailMode, notifyDelegate: false)
                lastSyncedIndex = index
            } else {
                gridView.currentIndex = index
                if inThumbnailMode {
                    gridView.scrollToSelectionAfterLayout()
                }
            }
            if inThumbnailMode {
                gridView.claimKeyboardFocus()
            }
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
            gridView.claimKeyboardFocus()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak gridView] in
                gridView?.scrollToSelectionAfterLayout()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak gridView] in
                gridView?.scrollToSelectionAfterLayout()
            }
        }

        func thumbnailGridDidSelect(index: Int, path: String) {
            lastSyncedIndex = index
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(path)
            appState.selection.selectedFiles = [path]
            appState.selection.emitSelectionChanged(highlightIndex: index)
        }

        func thumbnailGridDidOpenBrowse(index: Int, path: String) {
            thumbnailGridDidSelect(index: index, path: path)
            appState.fileData.setViewMode(.browse)
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
                let cgImage = await appState.thumbnailCache.generateThumbnail(for: path, size: size)
                let image = cgImage.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                completion(image)
            }
        }

        func thumbnailGridShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView) {
            ThumbnailContextMenu.show(for: event, clickedIndex: clickedIndex, in: view, appState: appState)
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
