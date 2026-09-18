import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    func updateStatusBarPeek(nearBottom: Bool) {
        guard config.bool(forKey: "raise_status_bar_on_cursor_near_bottom", default: true) else { return }
        guard !chromeSuppressed else { return }
        let hidden = !config.bool(forKey: "status_bar_visible", default: true)
        guard hidden else {
            if statusBarPeekActive { statusBarPeekActive = false }
            return
        }
        if nearBottom && !statusBarPeekActive {
            statusBarPeekActive = true
            sidebarLayoutRevision += 1
            notifyMainContentLayoutChanged()
        } else if !nearBottom && statusBarPeekActive {
            statusBarPeekActive = false
            sidebarLayoutRevision += 1
            notifyMainContentLayoutChanged()
        }
    }
    func toggleInformationSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "information_sidebar_visible", default: true)
        config.updateSetting("information_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
    }

    func toggleShortcutsSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "shortcuts_sidebar_visible", default: true)
        config.updateSetting("shortcuts_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
    }
    func setFileTreeToolbarVisible(_ visible: Bool) {
        guard fileTreeToolbarVisible != visible else { return }
        fileTreeToolbarVisible = visible
        config.updateSetting("file_tree_show_toolbar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    func setInformationMenuBarVisible(_ visible: Bool) {
        guard informationMenuBarVisible != visible else { return }
        informationMenuBarVisible = visible
        config.updateSetting("information_show_menu_bar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    func loadSidebarToolbarSettings() {
        fileTreeToolbarVisible = config.bool(forKey: "file_tree_show_toolbar", default: true)
        informationMenuBarVisible = config.bool(forKey: "information_show_menu_bar", default: true)
    }

    func reloadSidebarWidthsFromConfig() {
        leftSidebarWidth = SidebarWidthLimits.clampLeft(config.sidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(config.rightSidebarWidth)
    }

    func refreshSidebarLayout() {
        reloadSidebarWidthsFromConfig()
        sidebarLayoutRevision += 1
    }

    func updateLeftSidebarWidth(_ width: CGFloat) {
        let clamped = SidebarWidthLimits.clampLeft(width)
        guard clamped > 0, abs(clamped - leftSidebarWidth) > 1 else { return }
        leftSidebarWidth = clamped
        persistSidebarWidth(side: .left, width: clamped)
    }

    func updateRightSidebarWidth(_ width: CGFloat) {
        let clamped = SidebarWidthLimits.clampRight(width)
        guard clamped > 0, abs(clamped - rightSidebarWidth) > 1 else { return }
        rightSidebarWidth = clamped
        persistSidebarWidth(side: .right, width: clamped)
    }

    func persistSidebarWidth(side: SidebarSplitSide, width: CGFloat) {
        let rounded = Int(round(width))
        let minimum = side == .left
            ? Int(SidebarWidthLimits.leftMin)
            : Int(SidebarWidthLimits.rightMin)
        guard rounded >= minimum else { return }
        switch side {
        case .left:
            if Int(round(config.sidebarWidth)) != rounded {
                config.updateSetting("sidebar_width", value: rounded)
            }
        case .right:
            if Int(round(config.rightSidebarWidth)) != rounded {
                config.updateSetting("right_sidebar_width", value: rounded)
            }
        }
    }

    /// Flush sidebar column widths to `settings.json` (quit + layout changes). Pane sizes are
    /// already saved at drag end / fit (Python `saved_splitter_sizes`).
    func persistAllSidebarLayout() {
        persistSidebarWidth(side: .left, width: leftSidebarWidth)
        persistSidebarWidth(side: .right, width: rightSidebarWidth)
        if !chromeSuppressed {
            persistChromeVisibilityToConfig()
        }
    }
    /// Port of Python ``preview_widget.isVisible()`` for thumbnail click behavior.
    var isPreviewPaneVisible: Bool {
        guard Self.previewPaneIsConfiguredVisible(config: config, viewMode: fileData.currentViewMode) else {
            return false
        }
        return previewPaneInLayout
    }

    /// Settings + layout say the preview column should exist (not necessarily mounted yet).
    static func previewPaneIsConfiguredVisible(config: AppConfig, viewMode: ViewMode) -> Bool {
        if viewMode == .browse { return false }
        guard config.bool(forKey: "left_sidebar_visible", default: true) else { return false }
        return config.bool(forKey: "preview_visible", default: true)
    }

    /// Exit browse mode and return to thumbnail view (port of ``close_browse_view``).
    func closeBrowseView() {
        if let path = fileData.currentImagePath {
            fileData.setCurrentImagePath(path)
        }
        fileData.setViewMode(.thumbnail)
    }

    /// True when at least one left sidebar pane is open.
    var leftSidebarPaneActive: Bool {
        if fileData.currentViewMode == .browse { return false }
        if config.bool(forKey: "file_tree_visible", default: true) { return true }
        if config.bool(forKey: "preview_visible", default: true) { return true }
        return false
    }

    /// True when at least one right sidebar pane is open.
    var rightSidebarPaneActive: Bool {
        if config.bool(forKey: "shortcuts_sidebar_visible", default: true) { return true }
        if config.bool(forKey: "information_sidebar_visible", default: true) { return true }
        return false
    }

    var statusBarColumnVisible: Bool {
        !chromeSuppressed && config.bool(forKey: "status_bar_visible", default: true)
    }

    var effectiveStatusBarHeight: CGFloat {
        if let override = chromeLayoutOverride {
            return override.statusBarHeight
        }
        if statusBarColumnVisible { return ChromeLayoutAnimator.statusBarHeight }
        if statusBarPeekActive,
           config.bool(forKey: "raise_status_bar_on_cursor_near_bottom", default: true) {
            return ChromeLayoutAnimator.statusBarHeight
        }
        return 0
    }

    var effectiveLeftSidebarWidth: CGFloat {
        if let override = chromeLayoutOverride {
            return override.leftWidth
        }
        return leftSidebarColumnVisible ? leftSidebarWidth : 0
    }

    var effectiveRightSidebarWidth: CGFloat {
        if let override = chromeLayoutOverride {
            return override.rightWidth
        }
        return rightSidebarColumnVisible ? rightSidebarWidth : 0
    }

    var effectiveLeftSidebarVisible: Bool {
        if chromeLayoutOverride != nil {
            return (chromeLayoutOverride?.leftWidth ?? 0) > 0.5
        }
        return leftSidebarColumnVisible
    }

    var effectiveRightSidebarVisible: Bool {
        if chromeLayoutOverride != nil {
            return (chromeLayoutOverride?.rightWidth ?? 0) > 0.5
        }
        return rightSidebarColumnVisible
    }

    var leftSidebarColumnVisible: Bool {
        !chromeSuppressed
            && config.bool(forKey: "left_sidebar_visible", default: true)
            && leftSidebarPaneActive
    }

    var rightSidebarColumnVisible: Bool {
        !chromeSuppressed
            && config.bool(forKey: "right_sidebar_visible", default: true)
            && rightSidebarPaneActive
    }

    var isAnyChromeVisible: Bool {
        statusBarColumnVisible || leftSidebarColumnVisible || rightSidebarColumnVisible
    }

    var chromeToggleMenuTitle: String {
        isAnyChromeVisible ? "Hide Panes" : "Show Panes"
    }

    func toggleChrome() {
        if isAnyChromeVisible {
            chromeSavedLayout = captureChromeLayout()
            let from = currentChromeLayoutSnapshot()
            let to = ChromeLayoutSnapshot(leftWidth: 0, rightWidth: 0, statusBarHeight: 0)
            animateChromeLayout(from: from, to: to) {
                self.chromeSuppressed = true
                self.chromeLayoutOverride = nil
                self.persistChromeVisibilityToConfig()
                self.noteSidebarLayoutChanged()
            }
        } else {
            if let saved = chromeSavedLayout {
                chromeSuppressed = false
                restoreChromeLayout(saved)
            } else {
                chromeSuppressed = false
                showDefaultChrome()
            }
            let from = ChromeLayoutSnapshot(leftWidth: 0, rightWidth: 0, statusBarHeight: 0)
            let to = targetChromeLayoutSnapshot()
            animateChromeLayout(from: from, to: to) {
                self.chromeLayoutOverride = nil
                self.noteSidebarLayoutChanged()
            }
        }
    }

    func captureChromeLayout() -> ChromeSavedLayout {
        ChromeSavedLayout(
            statusBarVisible: config.bool(forKey: "status_bar_visible", default: true),
            fileTreeVisible: config.bool(forKey: "file_tree_visible", default: true),
            previewVisible: config.bool(forKey: "preview_visible", default: true),
            chatVisible: config.bool(forKey: "chat_visible", default: false),
            shortcutsVisible: config.bool(forKey: "shortcuts_sidebar_visible", default: true),
            informationVisible: config.bool(forKey: "information_sidebar_visible", default: true),
            leftSidebarVisible: config.bool(forKey: "left_sidebar_visible", default: true),
            rightSidebarVisible: config.bool(forKey: "right_sidebar_visible", default: true),
            leftSidebarWidth: leftSidebarWidth,
            rightSidebarWidth: rightSidebarWidth,
            leftSplitterSizes: leftSidebarSplit.savedSizes,
            rightSplitterSizes: rightSidebarSplit.savedSizes
        )
    }

    func restoreChromeLayout(_ layout: ChromeSavedLayout) {
        leftSidebarWidth = SidebarWidthLimits.clampLeft(layout.leftSidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(layout.rightSidebarWidth)
        if layout.leftSplitterSizes.count == 3 {
            config.saveSplitterSizes(leftSidebarSplit.persistenceKey, sizes: layout.leftSplitterSizes)
        }
        if layout.rightSplitterSizes.count == 3 {
            config.saveSplitterSizes(rightSidebarSplit.persistenceKey, sizes: layout.rightSplitterSizes)
        }
        config.updateSetting("status_bar_visible", value: layout.statusBarVisible)
        config.updateSetting("file_tree_visible", value: layout.fileTreeVisible)
        config.updateSetting("preview_visible", value: layout.previewVisible)
        config.updateSetting("chat_visible", value: layout.chatVisible)
        config.updateSetting("shortcuts_sidebar_visible", value: layout.shortcutsVisible)
        config.updateSetting("information_sidebar_visible", value: layout.informationVisible)
        config.updateSetting("left_sidebar_visible", value: layout.leftSidebarVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
        persistSidebarWidth(side: .left, width: leftSidebarWidth)
        persistSidebarWidth(side: .right, width: rightSidebarWidth)
    }

    func showDefaultChrome() {
        config.updateSetting("status_bar_visible", value: true)
        config.updateSetting("file_tree_visible", value: true)
        config.updateSetting("preview_visible", value: true)
        config.updateSetting("chat_visible", value: true)
        config.updateSetting("shortcuts_sidebar_visible", value: true)
        config.updateSetting("information_sidebar_visible", value: true)
        config.updateSetting("left_sidebar_visible", value: true)
        config.updateSetting("right_sidebar_visible", value: true)
    }

    func persistChromeVisibilityToConfig() {
        if chromeSuppressed {
            config.updateSetting("status_bar_visible", value: false)
            config.updateSetting("file_tree_visible", value: false)
            config.updateSetting("preview_visible", value: false)
            config.updateSetting("chat_visible", value: false)
            config.updateSetting("shortcuts_sidebar_visible", value: false)
            config.updateSetting("information_sidebar_visible", value: false)
            config.updateSetting("right_sidebar_visible", value: false)
            return
        }
        let layout = captureChromeLayout()
        config.updateSetting("status_bar_visible", value: layout.statusBarVisible)
        config.updateSetting("file_tree_visible", value: layout.fileTreeVisible)
        config.updateSetting("preview_visible", value: layout.previewVisible)
        config.updateSetting("chat_visible", value: layout.chatVisible)
        config.updateSetting("shortcuts_sidebar_visible", value: layout.shortcutsVisible)
        config.updateSetting("information_sidebar_visible", value: layout.informationVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
    }

    func clearChromeSuppression() {
        chromeSuppressed = false
    }

    func onSidebarPaneToggled(side: SidebarSplitSide, paneIndex: Int, nowVisible: Bool) {
        if side == .left, nowVisible, paneIndex != 2,
           config.bool(forKey: "chat_visible", default: false) {
            config.updateSetting("chat_visible", value: false)
        }
        if nowVisible {
            revealSidebarColumn(side)
        }
        noteSidebarLayoutChanged()
    }

    func noteSidebarLayoutChanged() {
        if !chromeSuppressed {
            config.updateSetting("left_sidebar_visible", value: leftSidebarPaneActive)
            config.updateSetting("right_sidebar_visible", value: rightSidebarPaneActive)
        }
        // Pane sizes are persisted only by user drag / fit (Python `_on_splitter_moved`,
        // `_resize_pane_to_height`); show/hide relayouts from the saved sizes.
        sidebarLayoutRevision += 1
        notifyMainContentLayoutChanged()
    }

    func notifyMainContentLayoutChanged() {
        eventBus.emit(.mainContentLayoutChanged)
        MainWindowKeyViewLoop.sync(appState: self)
    }

    func handleTreeForwardedKeyboard(_ event: NSEvent) -> Bool {
        keyboardHandler.handleKeyEventFromTree(event)
    }

    func setLeftSidebarPaneVisible(configKey: String, visible: Bool) {
        clearChromeSuppression()
        if visible, configKey != "chat_visible",
           config.bool(forKey: "chat_visible", default: false) {
            config.updateSetting("chat_visible", value: false)
        }
        config.updateSetting(configKey, value: visible)
        if visible { revealSidebarColumn(.left) }
        noteSidebarLayoutChanged()
    }

    func revealSidebarColumn(_ side: SidebarSplitSide) {
        switch side {
        case .left:
            config.updateSetting("left_sidebar_visible", value: true)
        case .right:
            config.updateSetting("right_sidebar_visible", value: true)
        }
    }

    func toggleStatusBar() {
        clearChromeSuppression()
        let currentlyVisible = config.bool(forKey: "status_bar_visible", default: true)
        let from = currentChromeLayoutSnapshot()
        if currentlyVisible {
            let to = ChromeLayoutSnapshot(
                leftWidth: from.leftWidth,
                rightWidth: from.rightWidth,
                statusBarHeight: 0
            )
            animateChromeLayout(from: from, to: to) {
                self.config.updateSetting("status_bar_visible", value: false)
                self.chromeLayoutOverride = nil
                self.notifyMainContentLayoutChanged()
            }
        } else {
            config.updateSetting("status_bar_visible", value: true)
            let to = ChromeLayoutSnapshot(
                leftWidth: from.leftWidth,
                rightWidth: from.rightWidth,
                statusBarHeight: ChromeLayoutAnimator.statusBarHeight
            )
            animateChromeLayout(from: from, to: to) {
                self.chromeLayoutOverride = nil
                self.notifyMainContentLayoutChanged()
            }
        }
    }

    func applySortMode(_ mode: SortMode, reversed: Bool) {
        if fileData.currentViewMode == .list {
            fileData.setViewMode(.thumbnail)
        }
        guard fileData.currentViewMode == .thumbnail || fileData.currentViewMode == .browse else { return }
        guard !fileData.displayedImages.isEmpty else { return }

        config.updateSetting("sort_mode", value: mode.rawValue)
        config.updateSetting("sort_reversed", value: reversed)
        if mode != .exifDate && mode != .exifYear && mode != .duplicates {
            clearDeletedPlaceholders()
        }
        if mode != .duplicates {
            duplicateSections = []
        }
        applyCurrentSort()
        status.show(Self.sortStatusMessage(mode: mode, reversed: reversed))
        menuRefresh.refreshAll()
    }

    /// Re-sort the current displayed list in place (Python `apply_current_sort`).
    /// Does not rescan the directory.
    func applyCurrentSort() {
        let current = fileData.currentImagePath
        let options = SortingService.Options.from(config: config)
        let sorted = SortingService.sorted(
            fileData.displayedImages,
            options: options,
            metadataCache: metadataCache
        )
        metadataCache.saveIfNeeded()
        fileData.setDisplayedImages(sorted)
        if options.mode == .duplicates {
            let pairs = DuplicateHashService.duplicateGroupPairs(sorted)
            duplicateSections = DuplicateGroupPresentation.duplicateSections(from: pairs)
        } else if !duplicateSections.isEmpty {
            duplicateSections = []
        }
        if let current, sorted.contains(current) {
            fileData.setCurrentImagePath(current)
        }
    }

    private static func sortStatusMessage(mode: SortMode, reversed: Bool) -> String {
        switch mode {
        case .size:
            let direction = reversed ? "Smallest first" : "Largest first"
            return "Sort mode set to Size (\(direction))"
        case .name:
            return reversed ? "Sort mode set to Name (Z-A)" : "Sort mode set to Name (A-Z)"
        case .date:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to Date (\(direction))"
        case .exifDate:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to EXIF Date (\(direction))"
        case .exifYear:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to EXIF Year (\(direction))"
        case .custom:
            return "Sort mode set to Custom"
        case .random:
            return "Random Sort"
        default:
            return "Sort mode set to \(mode.displayName)"
        }
    }

    func setUseExifDate(_ enabled: Bool) {
        config.updateSetting("use_exif_date", value: enabled)
        config.applySettingsChange(emit: eventBus)
    }

    func presentFilterEditSheet() {
        showFilterDialog = true
    }

    func saveFilterPresets(_ filters: [String]) {
        config.saveFilters(filters)
    }

    func currentChromeLayoutSnapshot() -> ChromeLayoutSnapshot {
        if let override = chromeLayoutOverride {
            return override
        }
        return targetChromeLayoutSnapshot()
    }

    func targetChromeLayoutSnapshot() -> ChromeLayoutSnapshot {
        ChromeLayoutSnapshot(
            leftWidth: leftSidebarColumnVisible ? leftSidebarWidth : 0,
            rightWidth: rightSidebarColumnVisible ? rightSidebarWidth : 0,
            statusBarHeight: statusBarColumnVisible ? ChromeLayoutAnimator.statusBarHeight : 0
        )
    }

    func animateChromeLayout(
        from: ChromeLayoutSnapshot,
        to: ChromeLayoutSnapshot,
        onComplete: @escaping () -> Void
    ) {
        chromeLayoutOverride = from
        sidebarLayoutRevision += 1
        ChromeLayoutAnimator.animate(from: from, to: to) { snapshot in
            self.chromeLayoutOverride = snapshot
            self.sidebarLayoutRevision += 1
            self.notifyMainContentLayoutChanged()
        } onComplete: {
            onComplete()
        }
    }
}
