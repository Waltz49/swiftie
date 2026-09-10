import AppKit
import Foundation

/// Central keyboard routing. Port of `keyboard_handler.py` (phase 1).
@MainActor
final class KeyboardHandlerController {
    private weak var appState: AppState?
    private var monitor: Any?

    func bind(_ appState: AppState) {
        self.appState = appState
        installMonitor()
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = self.handleKeyDown(event)
            return handled ? nil : event
        }
    }

    /// Returns true when the event was handled (and should be consumed).
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let appState else { return false }
        guard shouldHandle(event) else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)

        KeyboardInputTracer.log(
            "KeyboardHandler keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "?") "
                + "cmd=\(hasCommand) shift=\(hasShift)",
            config: appState.config
        )

        let isCmdArrow = hasCommand && !hasShift && !hasOption
            && (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126)
        if !isCmdArrow {
            appState.selection.resetCmdMulti()
        }

        // ⌘1…9 move to destination; ⌘0 last drop; ⌥⌘1…9 copy (Python menu shortcuts).
        if hasCommand, !hasShift {
            if event.keyCode == 29, !hasOption {
                appState.fileOperations.moveToLastDropLocation(copyOnly: false)
                return true
            }
            if let digit = controlDigitIndex(event) {
                appState.fileOperations.moveToDestination(slot: digit + 1, copyOnly: hasOption)
                return true
            }
        }

        // ⌘⇧I toggles browse number overlay (Python ctrl_shift_i).
        if hasCommand, hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "i" {
            appState.toggleNumberOverlay()
            return true
        }

        // ⌘+arrow multi-select in thumbnail/list view.
        if hasCommand, !hasShift, !hasOption,
           appState.fileData.currentViewMode == .thumbnail || appState.fileData.currentViewMode == .list {
            switch event.keyCode {
            case 123: return navigateCmdMulti(appState: appState, direction: .left)
            case 124: return navigateCmdMulti(appState: appState, direction: .right)
            case 125: return navigateCmdMulti(appState: appState, direction: .down)
            case 126: return navigateCmdMulti(appState: appState, direction: .up)
            default: break
            }
        }

        // ^1…9 open favorite directories (Python keyboard_handler MetaModifier).
        if hasControl, !hasCommand, !hasShift, !hasOption,
           let digit = controlDigitIndex(event) {
            appState.fileOperations.openFavoriteDirectory(slot: digit + 1)
            return true
        }

        // ⌘J — floating job queue panel (Python Control+J in Qt).
        if hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            appState.toggleJobsPanel()
            return true
        }

        // Let other Command-key bindings fall through to menus.
        if hasCommand { return false }

        // ⌃J — cycle jobs pane/panel size (Python Meta+J in Qt).
        if hasControl, !hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            appState.cycleActiveJobsSurfaceSize()
            return true
        }

        // F4, ., ^. — hide/show all panes (Python toggle_chrome).
        if hasControl, !hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers == "." {
            appState.toggleChrome()
            return true
        }
        if !hasCommand, !hasControl, !hasShift, !hasOption {
            if event.keyCode == 118 {
                appState.toggleChrome()
                return true
            }
            if event.charactersIgnoringModifiers == "." {
                appState.toggleChrome()
                return true
            }
        }

        // ⌥[ / ⌥] / ⌥\ — jobs queue size modes.
        if hasOption, !hasCommand, !hasControl, !hasShift {
            switch event.charactersIgnoringModifiers {
            case "[":
                appState.setJobsQueueSizeMode(.strip)
                return true
            case "]":
                appState.setJobsQueueSizeMode(.one, requireActive: true)
                return true
            case "\\":
                appState.setJobsQueueSizeMode(.all, requireActive: true)
                return true
            default:
                break
            }
        }

        // Shift+Escape → forward in history (thumbnail).
        if event.keyCode == 53, hasShift, !hasControl, !hasOption {
            if appState.fileData.currentViewMode == .thumbnail {
                appState.goForward()
                return true
            }
        }

        switch appState.fileData.currentViewMode {
        case .thumbnail, .list:
            return handleThumbnailOrList(
                event,
                appState: appState,
                hasShift: hasShift,
                hasControl: hasControl
            )
        case .browse:
            return handleBrowse(event, appState: appState, hasShift: hasShift)
        case .slideshow, .slideshow2, .slideshow3:
            return handleSlideshow(event, appState: appState)
        }
    }

    private func shouldHandle(_ event: NSEvent) -> Bool {
        guard let appState else { return false }
        if appState.showImageGenCreateSheet || appState.showKeyboardHelp || appState.showAbout {
            return false
        }
        if isTextInputFocused() { return false }
        if NSApp.keyWindow == nil { return false }
        return true
    }

    private func isTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField || responder is NSSecureTextField {
            return true
        }
        if String(describing: type(of: responder)).contains("TextField") {
            return true
        }
        return false
    }

    private func handleThumbnailOrList(
        _ event: NSEvent,
        appState: AppState,
        hasShift: Bool,
        hasControl: Bool
    ) -> Bool {
        if appState.fileData.currentViewMode == .thumbnail, !hasShift {
            switch event.keyCode {
            case 120: // F2 rename
                if let path = appState.fileData.currentImagePath {
                    appState.fileOperations.beginRename(path: path)
                    return true
                }
            case 27:
                appState.adjustThumbnailCellSize(multiplier: 1 / 1.1)
                return true
            case 24:
                appState.adjustThumbnailCellSize(multiplier: 1.1)
                return true
            case 29:
                appState.resetThumbnailCellSize()
                return true
            default:
                break
            }
        }

        if event.keyCode == 101, BundleCapabilities.chatUIEnabled {
            appState.toggleChatPane()
            return true
        }
        if event.keyCode == 43, !hasShift, !hasControl {
            appState.toggleChatPane()
            return true
        }

        switch event.keyCode {
        case 116: return pageScroll(appState: appState, direction: -1)
        case 121: return pageScroll(appState: appState, direction: 1)
        case 123: return navigate(appState: appState, direction: .left, rangeSelect: hasShift)
        case 124: return navigate(appState: appState, direction: .right, rangeSelect: hasShift)
        case 125: return navigate(appState: appState, direction: .down, rangeSelect: hasShift)
        case 126: return navigate(appState: appState, direction: .up, rangeSelect: hasShift)
        case 36, 49: return openBrowse(appState: appState) // return, space
        case 53: return handleEscapeThumbnail(appState: appState)
        case 44, 122: // /, F1
            appState.showKeyboardHelp = true
            return true
        default:
            break
        }

        if hasShift {
            return handleShiftLetter(event, appState: appState)
        }
        return handleLetter(event, appState: appState)
    }

    private func handleBrowse(_ event: NSEvent, appState: AppState, hasShift: Bool) -> Bool {
        if hasShift {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r":
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.resetTransforms))
                return true
            default: break
            }
            switch event.keyCode {
            case 123:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.rotateCounterclockwise))
                return true
            case 124:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.rotateClockwise))
                return true
            case 126:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.flipVertical))
                return true
            case 125:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.flipHorizontal))
                return true
            default:
                break
            }
        }

        switch event.keyCode {
        case 123, 126: return navigateLinear(appState: appState, delta: -1)
        case 124, 125: return navigateLinear(appState: appState, delta: 1)
        case 53, 36: return returnToThumbnails(appState: appState)
        case 49: return navigateLinear(appState: appState, delta: 1) // space
        case 27: // minus
            appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.zoomOut))
            return true
        case 24: // equals/plus
            appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.zoomIn))
            return true
        case 44, 122: // /, F1
            appState.showKeyboardHelp = true
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q", "f":
            return returnToThumbnails(appState: appState)
        case "h":
            jumpToFirst(appState: appState)
            return true
        case "e":
            jumpToLast(appState: appState)
            return true
        case "i":
            appState.toggleInformationSidebar()
            return true
        case "o":
            appState.toggleShortcutsSidebar()
            return true
        case "t":
            appState.toggleFileTree()
            return true
        case "j":
            if BundleCapabilities.imageGenUIEnabled {
                appState.toggleJobsPane()
                return true
            }
            return false
        case "p":
            appState.togglePreviewPane()
            return true
        case "b":
            appState.toggleStatusBar()
            return true
        case "a":
            appState.toggleBrowseActualSize()
            return true
        default:
            if event.keyCode == 0 {
                appState.toggleBrowseActualSize()
                return true
            }
            return false
        }
    }

    private func handleSlideshow(_ event: NSEvent, appState: AppState) -> Bool {
        switch event.keyCode {
        case 53, 36: // esc, return
            appState.fileData.setViewMode(.thumbnail)
            return true
        case 123, 126:
            appState.slideshowStep(delta: -1)
            return true
        case 124, 125, 49: // arrows, space
            appState.slideshowStep(delta: 1)
            return true
        default:
            break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "q" {
            appState.fileData.setViewMode(.thumbnail)
            return true
        }
        return false
    }

    private func handleLetter(_ event: NSEvent, appState: AppState) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h":
            jumpToFirst(appState: appState)
            return true
        case "e":
            jumpToLast(appState: appState)
            return true
        case "n":
            applySort(.name, reversed: false, appState: appState)
            return true
        case "r":
            applySort(.random, reversed: false, appState: appState)
            return true
        case "d":
            applySort(.date, reversed: false, appState: appState)
            return true
        case "z":
            applySort(.size, reversed: false, appState: appState)
            return true
        case "c":
            applySort(.custom, reversed: false, appState: appState)
            return true
        case "i":
            appState.toggleInformationSidebar()
            return true
        case "o":
            appState.toggleShortcutsSidebar()
            return true
        case "t":
            appState.toggleFileTree()
            return true
        case "j":
            if BundleCapabilities.imageGenUIEnabled {
                appState.toggleJobsPane()
                return true
            }
            return false
        case "p":
            appState.togglePreviewPane()
            return true
        case "b":
            appState.toggleStatusBar()
            return true
        case "q":
            if appState.fileData.currentViewMode == .list {
                appState.fileData.setViewMode(.thumbnail)
                return true
            }
            return false
        case "s":
            appState.startSlideshow(.slideshow)
            return true
        default:
            return false
        }
    }

    private func handleShiftLetter(_ event: NSEvent, appState: AppState) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s":
            appState.startSlideshow(.slideshow2)
            return true
        case "n":
            applySort(.name, reversed: true, appState: appState)
            return true
        case "d":
            applySort(.date, reversed: true, appState: appState)
            return true
        case "z":
            applySort(.size, reversed: true, appState: appState)
            return true
        case "h":
            selectRangeToFirst(appState: appState)
            return true
        case "e":
            selectRangeToLast(appState: appState)
            return true
        default:
            return false
        }
    }

    private func handleEscapeThumbnail(appState: AppState) -> Bool {
        if appState.fileData.currentViewMode == .list {
            appState.fileData.setViewMode(.thumbnail)
            return true
        }
        if appState.selection.multiSelectMode {
            appState.selection.clear()
            return true
        }
        appState.goBack()
        return true
    }

    private func navigate(
        appState: AppState,
        direction: ThumbnailNavigateDirection,
        rangeSelect: Bool
    ) -> Bool {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        if rangeSelect {
            navigateWithRangeSelect(appState: appState, direction: direction, images: images)
            return true
        }

        if appState.selection.multiSelectMode {
            appState.selection.clear()
        }
        appState.selection.rangeAnchorIndex = nil

        switch appState.fileData.currentViewMode {
        case .thumbnail:
            appState.eventBus.emit(.thumbnailNavigate, payload: .thumbnailDirection(direction))
        case .list:
            navigateList(appState: appState, direction: direction, images: images)
        default:
            navigateLinear(appState: appState, direction: direction, images: images)
        }
        return true
    }

    private func navigateWithRangeSelect(
        appState: AppState,
        direction: ThumbnailNavigateDirection,
        images: [String]
    ) {
        if appState.selection.rangeAnchorIndex == nil {
            appState.selection.rangeAnchorIndex = appState.fileData.currentIndex
        }

        if appState.fileData.currentViewMode == .thumbnail,
           direction == .up || direction == .down {
            appState.eventBus.emit(.thumbnailNavigate, payload: .thumbnailDirection(direction))
            applyRangeSelection(appState: appState, images: images, index: appState.fileData.currentIndex)
            return
        }

        let nextIndex = nextIndexForDirection(
            appState.fileData.currentIndex,
            direction: direction,
            count: images.count,
            wrap: appState.config.bool(forKey: "wrap_around", default: true),
            listMode: appState.fileData.currentViewMode == .list
        )

        appState.fileData.setCurrentIndex(nextIndex)
        appState.fileData.setCurrentImagePath(images[nextIndex])
        applyRangeSelection(appState: appState, images: images, index: nextIndex)
    }

    private func navigateList(appState: AppState, direction: ThumbnailNavigateDirection, images: [String]) {
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        }
        navigateLinear(appState: appState, delta: delta, images: images)
    }

    private func navigateLinear(appState: AppState, direction: ThumbnailNavigateDirection, images: [String]) {
        let delta = (direction == .left || direction == .up) ? -1 : 1
        navigateLinear(appState: appState, delta: delta, images: images)
    }

    private func navigateLinear(appState: AppState, delta: Int, images: [String]? = nil) -> Bool {
        let paths = images ?? appState.fileData.displayedImages
        guard !paths.isEmpty else { return false }
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let next = nextIndex(appState.fileData.currentIndex, delta: delta, count: paths.count, wrap: wrap)
        appState.fileData.setCurrentIndex(next)
        appState.fileData.setCurrentImagePath(paths[next])
        return true
    }

    private func nextIndexForDirection(
        _ index: Int,
        direction: ThumbnailNavigateDirection,
        count: Int,
        wrap: Bool,
        listMode: Bool
    ) -> Int {
        if listMode {
            let delta = (direction == .left || direction == .up) ? -1 : 1
            return nextIndex(index, delta: delta, count: count, wrap: wrap)
        }
        switch direction {
        case .left: return nextIndex(index, delta: -1, count: count, wrap: wrap)
        case .right: return nextIndex(index, delta: 1, count: count, wrap: wrap)
        case .up, .down:
            // Vertical steps defer to thumbnail grid via event bus when in thumbnail mode.
            let delta = direction == .up ? -1 : 1
            return nextIndex(index, delta: delta, count: count, wrap: wrap)
        }
    }

    private func nextIndex(_ index: Int, delta: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        let raw = index + delta
        if wrap { return ((raw % count) + count) % count }
        return min(max(0, raw), count - 1)
    }

    private func jumpToFirst(appState: AppState) {
        let images = appState.fileData.displayedImages
        guard let first = images.first else { return }
        if appState.selection.multiSelectMode { appState.selection.clear() }
        appState.selection.rangeAnchorIndex = nil
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(first)
    }

    private func jumpToLast(appState: AppState) {
        let images = appState.fileData.displayedImages
        guard let last = images.last else { return }
        if appState.selection.multiSelectMode { appState.selection.clear() }
        appState.selection.rangeAnchorIndex = nil
        appState.fileData.setCurrentIndex(images.count - 1)
        appState.fileData.setCurrentImagePath(last)
    }

    private func selectRangeToFirst(appState: AppState) {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return }
        if appState.selection.rangeAnchorIndex == nil {
            appState.selection.rangeAnchorIndex = appState.fileData.currentIndex
        }
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(images[0])
        applyRangeSelection(appState: appState, images: images, index: 0)
    }

    private func selectRangeToLast(appState: AppState) {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return }
        if appState.selection.rangeAnchorIndex == nil {
            appState.selection.rangeAnchorIndex = appState.fileData.currentIndex
        }
        let last = images.count - 1
        appState.fileData.setCurrentIndex(last)
        appState.fileData.setCurrentImagePath(images[last])
        applyRangeSelection(appState: appState, images: images, index: last)
    }

    private func applyRangeSelection(appState: AppState, images: [String], index: Int) {
        let anchor = appState.selection.rangeAnchorIndex ?? index
        let low = min(anchor, index)
        let high = max(anchor, index)
        appState.selection.selectedFiles = Set(images[low...high])
        appState.selection.emitSelectionChanged(highlightIndex: index)
    }

    private func openBrowse(appState: AppState) -> Bool {
        guard appState.fileData.currentImagePath != nil else { return false }
        appState.fileData.setViewMode(.browse)
        return true
    }

    private func returnToThumbnails(appState: AppState) -> Bool {
        if let path = appState.fileData.currentImagePath,
           let index = appState.fileData.displayedImages.firstIndex(of: path) {
            appState.fileData.setCurrentIndex(index)
        }
        appState.fileData.setViewMode(.thumbnail)
        return true
    }

    private func applySort(_ mode: SortMode, reversed: Bool, appState: AppState) {
        appState.config.updateSetting("sort_mode", value: mode.rawValue)
        appState.config.updateSetting("sort_reversed", value: reversed)
        appState.refreshDirectory()
    }

    private func pageScroll(appState: AppState, direction: Int) -> Bool {
        guard appState.fileData.currentViewMode == .thumbnail else { return false }
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        if appState.selection.multiSelectMode {
            appState.selection.clear()
        }
        appState.selection.rangeAnchorIndex = nil

        let pageSize = thumbnailPageSize(appState: appState)
        let delta = direction * pageSize
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let next = nextIndex(appState.fileData.currentIndex, delta: delta, count: images.count, wrap: wrap)
        appState.fileData.setCurrentIndex(next)
        appState.fileData.setCurrentImagePath(images[next])
        return true
    }

    private func thumbnailPageSize(appState: AppState) -> Int {
        let cellSize = appState.config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
        let sidebar = appState.leftSidebarColumnVisible ? appState.leftSidebarWidth : 0
        let right = appState.rightSidebarColumnVisible ? appState.rightSidebarWidth : 0
        let viewportWidth = max(400, 1100 - sidebar - right)
        let showFilename = appState.config.bool(forKey: "thumbnail_filename_visible", default: false)
        let showSize = appState.config.bool(forKey: "show_image_size", default: false)
        let metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: appState.fileData.displayedImages.count,
            showFilename: showFilename,
            showImageSize: showSize,
            cellSize: CGFloat(cellSize)
        )
        let rowsPerPage = 5
        return max(1, metrics.columns * rowsPerPage)
    }

    private func navigateCmdMulti(appState: AppState, direction: ThumbnailNavigateDirection) -> Bool {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }
        guard appState.fileData.currentViewMode == .thumbnail || appState.fileData.currentViewMode == .list else {
            return false
        }

        let currentPath = appState.fileData.currentImagePath
        guard let currentPath, let currentIndex = images.firstIndex(of: currentPath) else { return false }

        if appState.selection.selectedFiles.isEmpty {
            appState.selection.selectedFiles = [currentPath]
        }

        let axis = (direction == .left || direction == .right) ? "h" : "v"
        let stepSign = (direction == .left || direction == .up) ? -1 : 1
        let listMode = appState.fileData.currentViewMode == .list

        if appState.selection.cmdMultiOriginIndex == nil {
            appState.selection.cmdMultiOriginIndex = currentIndex
            appState.selection.cmdMultiAxis = axis
            appState.selection.cmdMultiSign = stepSign
            let nextIndex = computeCmdMultiNextIndex(
                appState: appState,
                currentIndex: currentIndex,
                axis: axis,
                stepSign: stepSign,
                listMode: listMode,
                count: images.count
            )
            if nextIndex == appState.selection.cmdMultiOriginIndex {
                setCurrentIndex(appState: appState, images: images, index: nextIndex)
                return true
            }
            setCurrentIndex(appState: appState, images: images, index: nextIndex)
            toggleIndex(appState: appState, images: images, index: nextIndex)
            return true
        }

        guard let originIndex = appState.selection.cmdMultiOriginIndex,
              originIndex >= 0, originIndex < images.count else {
            appState.selection.cmdMultiOriginIndex = currentIndex
            return navigateCmdMulti(appState: appState, direction: direction)
        }

        let originPath = images[originIndex]
        let currentIsOrigin = currentPath == originPath

        func axisDistance(_ index: Int) -> Int {
            if axis == "h" || listMode {
                return abs(index - originIndex)
            }
            let columns = thumbnailColumns(appState: appState, count: images.count)
            let originRow = originIndex / columns
            return abs((index / columns) - originRow)
        }

        let nextPeek = computeCmdMultiNextIndex(
            appState: appState,
            currentIndex: currentIndex,
            axis: axis,
            stepSign: stepSign,
            listMode: listMode,
            count: images.count
        )
        let movingTowardsOrigin = axisDistance(nextPeek) < axisDistance(currentIndex)

        if currentIsOrigin {
            let nextIndex = nextPeek
            if nextIndex == originIndex {
                setCurrentIndex(appState: appState, images: images, index: nextIndex)
                if axis == "v" {
                    appState.selection.cmdMultiOriginIndex = nextIndex
                }
                return true
            }
            setCurrentIndex(appState: appState, images: images, index: nextIndex)
            toggleIndex(appState: appState, images: images, index: nextIndex)
            if axis == "v" {
                appState.selection.cmdMultiOriginIndex = nextIndex
            }
            return true
        }

        if movingTowardsOrigin {
            if appState.selection.selectedFiles.contains(currentPath), currentPath != originPath {
                appState.selection.selectedFiles.remove(currentPath)
            }
            let nextIndex = nextPeek
            if appState.selection.selectedFiles.count == 1,
               appState.selection.selectedFiles.contains(originPath) {
                if nextIndex == originIndex {
                    let awayIndex = computeCmdMultiNextIndex(
                        appState: appState,
                        currentIndex: nextIndex,
                        axis: axis,
                        stepSign: stepSign,
                        listMode: listMode,
                        count: images.count
                    )
                    setCurrentIndex(appState: appState, images: images, index: awayIndex)
                    if awayIndex != nextIndex {
                        toggleIndex(appState: appState, images: images, index: awayIndex)
                    }
                } else {
                    setCurrentIndex(appState: appState, images: images, index: nextIndex)
                }
            } else {
                setCurrentIndex(appState: appState, images: images, index: nextIndex)
            }
        } else {
            let nextIndex = nextPeek
            if nextIndex == originIndex {
                setCurrentIndex(appState: appState, images: images, index: nextIndex)
                return true
            }
            setCurrentIndex(appState: appState, images: images, index: nextIndex)
            toggleIndex(appState: appState, images: images, index: nextIndex)
        }

        if axis == "v" {
            appState.selection.cmdMultiOriginIndex = appState.fileData.currentIndex
        }
        appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
        return true
    }

    private func computeCmdMultiNextIndex(
        appState: AppState,
        currentIndex: Int,
        axis: String,
        stepSign: Int,
        listMode: Bool,
        count: Int
    ) -> Int {
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        if axis == "h" || listMode {
            return nextIndex(currentIndex, delta: stepSign, count: count, wrap: wrap)
        }
        let columns = thumbnailColumns(appState: appState, count: count)
        return nextIndex(currentIndex, delta: stepSign * columns, count: count, wrap: wrap)
    }

    private func thumbnailColumns(appState: AppState, count: Int) -> Int {
        let cellSize = appState.config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
        let sidebar = appState.leftSidebarColumnVisible ? appState.leftSidebarWidth : 0
        let right = appState.rightSidebarColumnVisible ? appState.rightSidebarWidth : 0
        let viewportWidth = max(400, 1100 - sidebar - right)
        let showFilename = appState.config.bool(forKey: "thumbnail_filename_visible", default: false)
        let showSize = appState.config.bool(forKey: "show_image_size", default: false)
        let metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: count,
            showFilename: showFilename,
            showImageSize: showSize,
            cellSize: CGFloat(cellSize)
        )
        return max(1, metrics.columns)
    }

    private func setCurrentIndex(appState: AppState, images: [String], index: Int) {
        guard index >= 0, index < images.count else { return }
        appState.fileData.setCurrentIndex(index)
        appState.fileData.setCurrentImagePath(images[index])
    }

    private func toggleIndex(appState: AppState, images: [String], index: Int) {
        guard index >= 0, index < images.count else { return }
        let path = images[index]
        if appState.selection.selectedFiles.contains(path) {
            appState.selection.selectedFiles.remove(path)
        } else {
            appState.selection.selectedFiles.insert(path)
        }
        appState.fileData.setCurrentIndex(index)
        appState.fileData.setCurrentImagePath(path)
        appState.selection.emitSelectionChanged(highlightIndex: index)
    }

    private func controlDigitIndex(_ event: NSEvent) -> Int? {
        // keyCodes 18-26 = 1-9, 29 = 0
        switch event.keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        case 23: return 4
        case 22: return 5
        case 26: return 6
        case 28: return 7
        case 25: return 8
        default: return nil
        }
    }

}
