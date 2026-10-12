import AppKit
import Foundation

/// Central keyboard routing. Port of `keyboard_handler.py` (phase 1).
@MainActor
final class KeyboardHandlerController {
    private weak var appState: AppState?
    private var monitor: Any?
    private var doubleTapLastKey: UInt16?
    private var doubleTapLastTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 2.4

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
            self.appState?.recordSearchInvocationTreeContextFromKeyEvent(event)
            if self.tryHandleJobsPanelToggleShortcut(event) {
                return nil
            }
            if self.tryHandleFileTreeKeyboard(event) {
                return nil
            }
            if Self.isolateNonBrowserKeyDown(event) {
                return nil
            }
            let handled = self.handleKeyDown(event)
            return handled ? nil : event
        }
    }

    /// ⌘J — show/hide floating job control panel (main window, panel, and text fields).
    private func tryHandleJobsPanelToggleShortcut(_ event: NSEvent) -> Bool {
        guard BundleCapabilities.imageGenUIEnabled, let appState else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else { return false }
        guard event.charactersIgnoringModifiers?.lowercased() == "j" else { return false }
        appState.toggleJobsPanel()
        return true
    }

    /// Tree forwards unhandled keys here (Python `keyboard_handler_manager.handle_key_event` from the tree view).
    func handleKeyEventFromTree(_ event: NSEvent) -> Bool {
        let handled = handleKeyDown(event, fromTreeFocus: true)
        if handled, Self.treeJumpKeyShouldMoveFocusToCanvas(event) {
            appState?.focusMainCanvas()
            appState?.syncFileTreeKeyboardFocus(from: event.window)
        }
        return handled
    }

    /// Tree pane shortcuts (context menu parity) — run before global Search menu / Edit ⌘C.
    private func tryHandleFileTreeKeyboard(_ event: NSEvent) -> Bool {
        guard let appState else { return false }
        guard appState.fileTreePaneHasKeyboardFocus(in: event.window) else { return false }
        guard let outline = appState.fileTreeOutlineView,
              let coordinator = outline.coordinator else { return false }
        return FileTreeKeyboard.handle(
            event: event,
            outlineView: outline,
            coordinator: coordinator,
            appState: appState
        )
    }

    /// E/H and Home/End jump the active image; focus should leave the file tree (thumbnail/list/browse canvas).
    private static func treeJumpKeyShouldMoveFocusToCanvas(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.shift) {
            return false
        }
        switch event.keyCode {
        case 115, 119: // Home, End
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h", "e":
            return true
        default:
            return false
        }
    }

    static func fileTreeKeyboardTargetIsFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is FileTreeOutlineView { return true }
        if let stop = responder as? MainWindowTabFocusStopView, stop.role == .tree { return true }
        return false
    }

    /// ⌘F / ⌘P (not ⇧⌘P or ⌃⌘P) — tree-scoped search sheet priming.
    static func isSearchDirectoryPrimingShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option) else { return false }
        let c = event.charactersIgnoringModifiers?.lowercased()
        if c == "f" { return !flags.contains(.shift) }
        if c == "p" { return !flags.contains(.shift) && !flags.contains(.control) }
        return false
    }

    /// ⇧⌘C — Cache Subdirectories' Thumbnails; tree focus is captured before the menu steals it.
    static func isTreeScopedCacheShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.shift),
              !flags.contains(.option), !flags.contains(.control) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    /// Returns true when the event was handled (and should be consumed).
    private func handleKeyDown(_ event: NSEvent, fromTreeFocus: Bool = false) -> Bool {
        guard appState != nil else { return false }
        guard shouldHandle(event, fromTreeFocus: fromTreeFocus) else { return false }
        guard let appState else { return false }

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

        // ⌘1…9 / ⌘0 use destination_menu_action; ⌥⌘ forces copy (Python Alt+Ctrl+N / Alt+Ctrl+0).
        if hasCommand, !hasShift {
            if event.keyCode == 29 {
                appState.fileOperations.moveToLastDropLocation(copyOnly: hasOption ? true : nil)
                return true
            }
            if let digit = controlDigitIndex(event) {
                appState.fileOperations.moveToDestination(
                    slot: digit + 1,
                    copyOnly: hasOption ? true : nil
                )
                return true
            }
        }

        // ⌘⇧D toggles debug mode (Python ctrl_shift_d). Nested Debug menu
        // shortcuts do not receive key equivalents, so handle it here.
        if hasCommand, hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "d" {
            appState.toggleDebugMode()
            return true
        }

        // ⌘⇧I toggles browse number overlay (Python ctrl_shift_i).
        if hasCommand, hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "i" {
            appState.toggleNumberOverlay()
            return true
        }

        // ⌘I — thumbnail overlay cycle, or browse filename/index overlay (Python browse ctrl_i).
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "i" {
            appState.cycleThumbnailOverlay()
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

        if hasCommand, hasOption, !hasShift, !hasControl {
            if event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "÷" {
                if BundleCapabilities.imageGenUIEnabled {
                    appState.editActiveQueueJob()
                    return true
                }
            }
        }

        if hasControl, !hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            appState.cycleActiveJobsSurfaceSize()
            return true
        }

        // ⌘[ compact, ⌘] one job, ⌘\ all jobs — same as Python ⌥[ / ⌥] / ⌥\.
        if !hasShift, !hasControl, hasCommand != hasOption,
           let jobsMode = jobsQueueSizeShortcutMode(event) {
            return appState.setJobsQueueSizeMode(
                jobsMode,
                requireActive: jobsMode != .strip
            )
        }

        if hasOption, !hasCommand, !hasShift, !hasControl {
            switch event.charactersIgnoringModifiers {
            case "/", "÷":
                if BundleCapabilities.imageGenUIEnabled {
                    appState.openImageGenDialog()
                    return true
                }
            default:
                break
            }
        }

        if hasShift, hasOption, !hasCommand, !hasControl,
           event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "÷" {
            if BundleCapabilities.imageGenUIEnabled {
                appState.openFastImageGenDialog()
                return true
            }
        }

        // ^H — open home directory (Python Tools menu Meta+H).
        if hasControl, !hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "h" {
            appState.openHomeDirectory()
            return true
        }

        // ⌘; — swap browse image history first two (Last Image).
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers == ";" {
            if appState.fileData.currentViewMode == .browse {
                appState.swapBrowseImageHistoryFirstTwoAndShow()
                return true
            }
        }

        // ⌘⇧H — show image in directory.
        if hasCommand, hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "h" {
            appState.showImageInDirectory()
            return true
        }

        // ⌘L / ⇧⌘L — lock / unlock (Python `keyboard_handler`; thumbnail grid focus may not reach SwiftUI menus).
        if hasCommand, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            switch appState.fileData.currentViewMode {
            case .thumbnail, .browse:
                if hasShift {
                    appState.fileOperations.unlockSelectedFiles()
                    return true
                }
                if appState.config.bool(forKey: "allow_thumbnail_locking", default: false) {
                    appState.fileOperations.lockSelectedFiles()
                    return true
                }
            default:
                break
            }
        }

        // ⌘⇧E — edit EXIF user comment (Python ShiftCmdEShortcutFilter).
        if hasCommand, hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            appState.beginEditUserComment()
            return true
        }

        // ⌘⇧O — open file (Python); ⌘O is open directory via menu.
        if hasCommand, hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "o" {
            appState.openFileDialog()
            return true
        }

        // ⌘G — show GPS location on map.
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            appState.openMapForCurrentImage()
            return true
        }

        // ⌘E — edit in external editor (Python Qt Ctrl+E → ⌘E on macOS).
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            appState.fileOperations.openWithExternalEditor()
            return true
        }

        let searchView = appState.fileData.currentViewMode == .thumbnail
            || appState.fileData.currentViewMode == .browse
            || appState.fileData.currentViewMode == .list
        if searchView, hasCommand, !hasOption, !hasControl {
            if hasShift, event.charactersIgnoringModifiers?.lowercased() == "k" {
                appState.searchOperations.presentClipSearchDialog()
                return true
            }
            if !hasShift, event.charactersIgnoringModifiers?.lowercased() == "k" {
                appState.searchOperations.presentSimilaritySearchDialog()
                return true
            }
            if !hasShift, event.charactersIgnoringModifiers?.lowercased() == "f" {
                if appState.fileTreePaneHasKeyboardFocus(in: event.window) {
                    return false
                }
                appState.searchOperations.presentClipSearchDialog()
                return true
            }
            if !hasShift, !hasControl, event.charactersIgnoringModifiers?.lowercased() == "p" {
                if appState.fileTreePaneHasKeyboardFocus(in: event.window) {
                    return false
                }
                appState.searchOperations.presentPersonSearchDialog()
                return true
            }
        }

        // ⌘⇧Return — collapse file tree to home (⌘↩ expand is handled in `FileTreeKeyboard` when tree is focused).
        if hasCommand, hasShift, !hasOption, !hasControl,
           event.keyCode == 36 || event.keyCode == 76 {
            appState.collapseFileTree()
            return true
        }

        // Browse view: ⌘+arrow pans when zoomed.
        if hasCommand, !hasShift, !hasOption, !hasControl,
           appState.fileData.currentViewMode == .browse {
            switch event.keyCode {
            case 123:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.panLeft))
                return true
            case 124:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.panRight))
                return true
            case 126:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.panUp))
                return true
            case 125:
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.panDown))
                return true
            default:
                break
            }
        }

        // ⌘, — settings (Python File → Settings… Ctrl+,).
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers == "," || event.keyCode == 43 {
            appState.openSettingsWindow()
            return true
        }

        // ⌘Delete / ⌘Backspace — move to trash (handle here so menu focus is not stolen).
        if hasCommand, !hasOption, !hasControl, isDeleteKey(event) {
            appState.fileOperations.deleteSelectedFiles()
            return true
        }

        // ⌘C — copy path (Python `copy_file_path_to_clipboard`; tree uses FileTreeKeyboard).
        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            if appState.fileTreePaneHasKeyboardFocus(in: event.window) {
                return false
            }
            return copyFilePathToClipboard(appState: appState)
        }

        // ^C — copy image (Python Edit ▸ Copy Image).
        if hasControl, !hasCommand, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            appState.fileOperations.copyImageToClipboard()
            return true
        }

        // Let other Command-key bindings fall through to menus.
        if hasCommand { return false }

        // ⌥T/P/O/I — show one sidebar pane (hide siblings on that column).
        if hasOption, !hasControl, !hasShift {
            if handleOptionPaneExclusiveShortcut(event, appState: appState) {
                return true
            }
        }

        // F3 — Image History (Python File ▸ Image History WindowShortcut).
        if !hasCommand, !hasControl, !hasShift, !hasOption, Self.isF3Key(event) {
            let mode = appState.fileData.currentViewMode
            if mode == .browse || mode == .thumbnail {
                appState.openBrowseImageHistory()
                return true
            }
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
            return handleBrowse(
                event,
                appState: appState,
                hasShift: hasShift,
                hasControl: hasControl,
                hasOption: hasOption
            )
        case .slideshow, .slideshow2, .slideshow3:
            return handleSlideshow(event, appState: appState)
        }
    }

    private func shouldHandle(_ event: NSEvent, fromTreeFocus: Bool = false) -> Bool {
        guard appState != nil else { return false }
        if NSApp.modalWindow != nil { return false }
        let keyWindow = event.window ?? NSApp.keyWindow
        if SceneWindowChrome.isJobsPanelWindow(keyWindow) {
            if isTextInputFocused(in: keyWindow) { return false }
        } else if !BrowserWindowIdentity.browserWindowOwnsShortcuts(event: event) {
            return false
        }
        if !fromTreeFocus, appState!.fileTreePaneHasKeyboardFocus(in: event.window) {
            // Python Image History is a WindowShortcut; still handle F3 when the tree has focus.
            if !Self.isF3Key(event) {
                return false
            }
        }
        if isTextInputFocused(in: event.window) { return false }
        if NSApp.keyWindow == nil { return false }
        return true
    }

    /// Preferences are non-modal, but browser shortcuts must not run while Preferences is key.
    static func settingsPreferencesShouldReceiveKeyboard(appState: AppState, event: NSEvent) -> Bool {
        preferencesPanelOwnsKeyboardFocus(appState: appState, event: event)
    }

    /// Shared gate for menu shortcuts, the keyboard handler, and the thumbnail grid.
    static func preferencesPanelOwnsKeyboardFocus(appState: AppState, event: NSEvent? = nil) -> Bool {
        guard appState.isSettingsDialogVisible else { return false }
        if isPreferencesWindow(NSApp.keyWindow) { return true }
        if let event, isPreferencesWindow(event.window) { return true }
        return false
    }

    /// Consume Command shortcuts that would otherwise hit browser menus while a dialog
    /// is key or a text field is first responder (⌘A select-all thumbnails, ⌘C copy path, …).
    static func isolateNonBrowserKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control) else { return false }

        if isWindowChromeCommand(event) { return false }

        let keyWindow = NSApp.keyWindow
        if SceneWindowChrome.isJobsPanelWindow(keyWindow) {
            let textInJobsPanel = (keyWindow?.firstResponder).map(Self.isTextEditingResponder) ?? false
            if !textInJobsPanel { return false }
        }
        let textFocused = (keyWindow?.firstResponder).map(isTextEditingResponder) ?? false
        let dialogOwns = !BrowserWindowIdentity.browserWindowOwnsShortcuts(event: event)
        guard textFocused || dialogOwns else { return false }

        if isTextNavigationCommand(event) { return false }
        if dialogOwns, isDialogSaveCommand(event) { return false }

        if performStandardEditingShortcut(event) {
            return true
        }
        return true
    }

    private static func isWindowChromeCommand(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        return chars == "w" || chars == "q"
    }

    private static func isDialogSaveCommand(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func isTextNavigationCommand(_ event: NSEvent) -> Bool {
        isArrowKey(event.keyCode)
    }

    @discardableResult
    private static func performStandardEditingShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        guard !option else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where !shift:
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "c" where !shift:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "x" where !shift:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "v" where !shift:
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "z" where !shift:
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case "z" where shift:
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        default:
            return false
        }
    }

    /// `[` `]` `\` — key codes stay stable when Command or Option is held.
    private func jobsQueueSizeShortcutMode(_ event: NSEvent) -> JobsQueueSizeMode? {
        switch event.keyCode {
        case 33: return .strip
        case 30: return .one
        case 42: return .all
        default: return nil
        }
    }

    private static func isF3Key(_ event: NSEvent) -> Bool {
        event.keyCode == 99 || event.specialKey == .f3
    }

    private static func isArrowKey(_ keyCode: UInt16) -> Bool {
        keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
    }

    static func isArrowKeyPublic(_ keyCode: UInt16) -> Bool {
        isArrowKey(keyCode)
    }

    static func firstResponderIsInWindow(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder === window { return false }
        if let view = responder as? NSView {
            return view.window === window
        }
        return false
    }

    static func mouseIsInWindow(_ window: NSWindow) -> Bool {
        window.frame.contains(NSEvent.mouseLocation)
    }

    static func isLikelyMainBrowserWindow(_ window: NSWindow?) -> Bool {
        BrowserWindowIdentity.isMainBrowserWindow(window)
    }

    static func visiblePreferencesWindow() -> NSWindow? {
        NSApp.windows.first { isPreferencesWindow($0) && $0.isVisible }
    }

    static func isPreferencesWindow(_ window: NSWindow?) -> Bool {
        BrowserWindowIdentity.isPreferencesWindow(window)
    }

    private func isTextInputFocused(in eventWindow: NSWindow?) -> Bool {
        let window = eventWindow ?? NSApp.keyWindow
        guard let responder = window?.firstResponder else { return false }
        return Self.isTextEditingResponder(responder)
    }

    static func isTextEditingResponder(_ responder: NSResponder) -> Bool {
        if responder is NSTextView || responder is NSTextField || responder is NSSecureTextField {
            return true
        }
        let typeName = String(describing: type(of: responder))
        if typeName.contains("TextField") || typeName.contains("TextEditor") || typeName.contains("TextView") {
            return true
        }
        if let view = responder as? NSView {
            var current: NSView? = view
            while let candidate = current {
                if candidate is NSTextView || candidate is NSTextField || candidate is NSSecureTextField {
                    return true
                }
                current = candidate.superview
            }
        }
        return false
    }

    private func handleThumbnailOrList(
        _ event: NSEvent,
        appState: AppState,
        hasShift: Bool,
        hasControl: Bool
    ) -> Bool {
        if !hasShift, !hasControl {
            switch event.keyCode {
            case 3: // F — enter browse (Python browse_view_action)
                return openBrowse(appState: appState)
            case 96: // F5 — reference graph for active image
                if let path = appState.fileData.currentImagePath {
                    appState.showReferenceGraph(for: path)
                    return true
                }
            case 109: // F10 — clear directory history stacks
                appState.clearDirectoryHistory()
                return true
            case 111: // F12 — toggle list view
                appState.toggleListView()
                return true
            default:
                break
            }
        }

        if !hasShift, !hasControl {
            switch event.keyCode {
            case 115: // Home
                jumpToFirst(appState: appState)
                return true
            case 119: // End
                jumpToLast(appState: appState)
                return true
            default:
                break
            }
        }

        if hasShift, !hasControl {
            switch event.keyCode {
            case 115:
                selectRangeToFirst(appState: appState)
                return true
            case 119:
                selectRangeToLast(appState: appState)
                return true
            default:
                break
            }
        }

        if !hasShift, !hasControl {
            switch event.keyCode {
            case 27, 24, 29, 69: // -, +/=, 0, keypad =
                if appState.fileData.currentViewMode == .list {
                    switch event.keyCode {
                    case 27: appState.adjustListRowHeight(delta: -2); return true
                    case 24, 69: appState.adjustListRowHeight(delta: 2); return true
                    case 29: appState.resetListRowHeight(); return true
                    default: break
                    }
                } else if appState.fileData.currentViewMode == .thumbnail {
                    switch event.keyCode {
                    case 27:
                        appState.adjustThumbnailCellSize(multiplier: 1 / 1.1)
                        return true
                    case 24, 69:
                        appState.adjustThumbnailCellSize(multiplier: 1.1)
                        return true
                    case 29:
                        appState.resetThumbnailCellSize()
                        return true
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        if appState.fileData.currentViewMode == .thumbnail, !hasShift {
            switch event.keyCode {
            case 120: // F2 rename
                if let path = appState.fileData.currentImagePath {
                    appState.beginRename(path: path)
                    return true
                }
            default:
                break
            }
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
        if hasControl {
            return false
        }
        return handleLetter(event, appState: appState)
    }

    private func handleBrowse(
        _ event: NSEvent,
        appState: AppState,
        hasShift: Bool,
        hasControl: Bool,
        hasOption: Bool
    ) -> Bool {
        if hasShift, !hasControl, !hasOption, event.keyCode == 49 {
            appState.toggleSpaceKeyMode()
            return true
        }

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

        if hasControl, !hasShift, !hasOption,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.fitCanvasWidth))
            return true
        }

        if hasOption, !hasShift, !hasControl {
            switch event.keyCode {
            case 27, 43: // minus, keypad -
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.fitCanvasWidth))
                return true
            case 24, 69: // equals/plus, keypad =
                appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.fitCanvasHeight))
                return true
            default:
                break
            }
        }

        switch event.keyCode {
        case 115: // Home
            jumpToFirst(appState: appState)
            return true
        case 119: // End
            jumpToLast(appState: appState)
            return true
        case 123, 126: return navigateLinear(appState: appState, delta: -1)
        case 124, 125: return navigateLinear(appState: appState, delta: 1)
        case 53, 36: return returnToThumbnails(appState: appState)
        case 49:
            if appState.spaceKeyMode == "advance" {
                return navigateLinear(appState: appState, delta: 1)
            }
            return returnToThumbnails(appState: appState)
        case 27, 43: // minus, keypad -
            appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.zoomOut))
            return true
        case 24, 69: // equals/plus, keypad =
            appState.eventBus.emit(.browseKeyboard, payload: .browseAction(.zoomIn))
            return true
        case 96: // F5 — reference graph for active image (Python thumbnail + browse)
            if let path = appState.fileData.currentImagePath {
                appState.showReferenceGraph(for: path)
                return true
            }
        case 97: // F6 — sharpen when zoomed in browse view
            appState.toggleBrowseZoomSharpen()
            return true
        case 109: // F10
            appState.clearDirectoryHistory()
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
            return handleBrowseDoubleTap(
                event,
                keyCode: 17,
                appState: appState,
                onMatch: {
                    _ = returnToThumbnails(appState: appState)
                    appState.showFileTree()
                }
            )
        case "p":
            return handleBrowseDoubleTap(
                event,
                keyCode: 35,
                appState: appState,
                onMatch: {
                    _ = returnToThumbnails(appState: appState)
                    appState.showPreviewPane()
                }
            )
        case "b":
            appState.toggleStatusBar()
            return true
        case "j":
            return toggleJobsPaneShortcut(appState: appState)
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = flags.contains(.shift)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)

        if event.keyCode == 44 || event.keyCode == 122 {
            appState.showKeyboardHelp = true
            return true
        }

        if hasCommand, !hasShift, !hasControl,
           event.keyCode == 36 || event.keyCode == 76 {
            appState.collapseFileTree()
            return true
        }

        switch appState.fileData.currentViewMode {
        case .slideshow:
            return handleSlideshow1(event, appState: appState, hasShift: hasShift)
        case .slideshow2:
            return handleSlideshow2(event, appState: appState, hasShift: hasShift, hasControl: hasControl)
        case .slideshow3:
            return handleSlideshow3(event, appState: appState, hasShift: hasShift, hasControl: hasControl)
        default:
            return false
        }
    }

    private func handleSlideshow1(_ event: NSEvent, appState: AppState, hasShift: Bool) -> Bool {
        switch event.keyCode {
        case 53:
            appState.fileData.setViewMode(.thumbnail)
            return true
        case 45: // N — advance
            appState.slideshowStep(delta: 1)
            return true
        case 18: appState.adjustSlideshowRate(slower: true); return true
        case 19: appState.adjustSlideshowRate(slower: false); return true
        case 20: appState.adjustSlideshowTransitionSpeed(slower: true); return true
        case 21: appState.adjustSlideshowTransitionSpeed(slower: false); return true
        case 23: appState.adjustSlideshowMaxRotation(increase: false); return true
        case 22: appState.adjustSlideshowMaxRotation(increase: true); return true
        case 26: appState.decreaseSlideshowOverlap(); return true
        case 28: appState.increaseSlideshowOverlap(); return true
        case 29: appState.applySlideshowPreset("0"); return true
        case 25: appState.applySlideshowPreset("9"); return true
        case 126: return appState.slideshowDirectionAdvanceIfMatches("top")
        case 125: return appState.slideshowDirectionAdvanceIfMatches("bottom")
        case 123: return appState.slideshowDirectionAdvanceIfMatches("left")
        case 124: return appState.slideshowDirectionAdvanceIfMatches("right")
        case 36, 49, 3: // return, space, F — enter browse
            appState.openBrowseFromSlideshow()
            return true
        default:
            break
        }

        if hasShift, event.charactersIgnoringModifiers?.lowercased() == "r" {
            appState.setSlideshowDirection("random")
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c" {
            appState.setSlideshowDirection("none")
            return true
        }
        return false
    }

    private func handleSlideshow2(
        _ event: NSEvent,
        appState: AppState,
        hasShift: Bool,
        hasControl: Bool
    ) -> Bool {
        if hasControl, !hasShift,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            appState.fitSlideshow2ToCanvasWidth()
            return true
        }

        switch event.keyCode {
        case 53:
            appState.fileData.setViewMode(.thumbnail)
            return true
        case 27, 43:
            adjustSlideshow2Enlargement(appState: appState, delta: -0.2)
            return true
        case 24, 69:
            adjustSlideshow2Enlargement(appState: appState, delta: 0.2)
            return true
        case 18:
            adjustSlideshow2Speed(appState: appState, delta: hasShift ? -100 : -2)
            return true
        case 19:
            adjustSlideshow2Speed(appState: appState, delta: hasShift ? 100 : 2)
            return true
        case 36, 49:
            appState.openBrowseFromSlideshow()
            return true
        default:
            break
        }

        if hasShift {
            switch event.keyCode {
            case 123, 126:
                appState.slideshowStep(delta: -1)
                return true
            case 124, 125:
                appState.slideshowStep(delta: 1)
                return true
            default:
                break
            }
        }

        if !hasShift, event.charactersIgnoringModifiers?.lowercased() == "q" {
            let enabled = !appState.config.bool(forKey: "slideshow2_high_quality_scaling", default: false)
            appState.config.updateSetting("slideshow2_high_quality_scaling", value: enabled)
            appState.config.applySettingsChange(emit: appState.eventBus)
            appState.status.show("High-quality scaling: \(enabled ? "enabled" : "disabled")")
            return true
        }
        return false
    }

    private func handleSlideshow3(
        _ event: NSEvent,
        appState: AppState,
        hasShift: Bool,
        hasControl: Bool
    ) -> Bool {
        _ = hasShift
        _ = hasControl
        switch event.keyCode {
        case 53:
            appState.fileData.setViewMode(.thumbnail)
            return true
        case 18:
            adjustSlideshow3Speed(appState: appState, delta: -1)
            return true
        case 19:
            adjustSlideshow3Speed(appState: appState, delta: 1)
            return true
        case 36, 49:
            appState.fileData.setViewMode(.thumbnail)
            return true
        default:
            return false
        }
    }

    private func adjustSlideshow2Enlargement(appState: AppState, delta: Double) {
        let current = appState.config.double(forKey: "slideshow2_enlargement", default: 1.2)
        let next = min(3.0, max(0.5, current + delta))
        appState.config.updateSetting("slideshow2_enlargement", value: next)
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.status.show(String(format: "Panning zoom: %.1fx", next))
    }

    private func adjustSlideshow2Speed(appState: AppState, delta: Int) {
        let current = appState.config.int(forKey: "slideshow2_speed", default: 8)
        let next = min(1860, max(1, current + delta))
        appState.config.updateSetting("slideshow2_speed", value: next)
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.status.show("Panning speed: \(next)px/s")
    }

    private func adjustSlideshow3Speed(appState: AppState, delta: Int) {
        let current = appState.config.int(forKey: "slideshow3_speed", default: 1)
        let next = max(1, current + delta)
        appState.config.updateSetting("slideshow3_speed", value: next)
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.status.show("Floating frames speed: \(next)")
    }

    /// ⌥ + pane letter — exclusive pane on left (T, P) or right (O, I). Uses key codes for layout safety.
    private func handleOptionPaneExclusiveShortcut(_ event: NSEvent, appState: AppState) -> Bool {
        let configKey: String?
        switch event.keyCode {
        case 17: configKey = "file_tree_visible" // T
        case 35: configKey = "preview_visible" // P
        case 31: configKey = "shortcuts_sidebar_visible" // O
        case 34: configKey = "information_sidebar_visible" // I
        default: configKey = nil
        }
        guard let configKey else { return false }
        appState.showSidebarPaneExclusive(configKey: configKey)
        return true
    }

    /// Python View ▸ Jobs Pane (`QKeySequence('J')` → `toggle_jobs_pane`).
    private func toggleJobsPaneShortcut(appState: AppState) -> Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        appState.toggleJobsPane()
        return true
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
        case "x":
            applySort(.exifDate, reversed: false, appState: appState)
            return true
        case "y":
            applySort(.exifYear, reversed: false, appState: appState)
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
        case "p":
            appState.togglePreviewPane()
            return true
        case "b":
            appState.toggleStatusBar()
            return true
        case "j":
            return toggleJobsPaneShortcut(appState: appState)
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
        case "x":
            applySort(.exifDate, reversed: true, appState: appState)
            return true
        case "y":
            applySort(.exifYear, reversed: true, appState: appState)
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
        if appState.fileData.currentViewMode == .thumbnail, appState.specificFilesActive {
            appState.goBack()
            return true
        }
        if appState.selection.multiSelectMode {
            SelectionService.clearSelection(appState: appState)
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
        if Self.preferencesPanelOwnsKeyboardFocus(appState: appState) {
            return false
        }
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        if rangeSelect {
            navigateWithRangeSelect(appState: appState, direction: direction, images: images)
            return true
        }

        // Python arrow handlers clear thumbnail selection before moving highlight.
        if !appState.selection.selectedFiles.isEmpty {
            SelectionService.clearSelection(appState: appState)
        }
        appState.selection.rangeAnchorIndex = nil

        switch appState.fileData.currentViewMode {
        case .thumbnail:
            if direction == .up || direction == .down {
                let currentIndex = resolvedCurrentIndex(appState: appState, images: images)
                let stepSign = direction == .up ? -1 : 1
                let nextIndex = computeVerticalTargetIndex(
                    appState: appState,
                    currentIndex: currentIndex,
                    stepSign: stepSign,
                    count: images.count
                )
                appState.fileData.setCurrentIndex(nextIndex)
                appState.fileData.setCurrentImagePath(images[nextIndex])
            } else {
                let wrap = appState.config.bool(forKey: "wrap_around", default: true)
                let currentIndex = resolvedCurrentIndex(appState: appState, images: images)
                let delta = direction == .left ? -1 : 1
                let nextIndex = nextIndex(currentIndex, delta: delta, count: images.count, wrap: wrap)
                appState.fileData.setCurrentIndex(nextIndex)
                appState.fileData.setCurrentImagePath(images[nextIndex])
            }
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
        let currentIndex = resolvedCurrentIndex(appState: appState, images: images)
        if appState.selection.rangeAnchorIndex == nil {
            appState.selection.rangeAnchorIndex = currentIndex
        }

        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let listMode = appState.fileData.currentViewMode == .list

        let targetIndex: Int
        if listMode {
            let delta = (direction == .left || direction == .up) ? -1 : 1
            targetIndex = nextIndex(currentIndex, delta: delta, count: images.count, wrap: wrap)
        } else if direction == .up || direction == .down {
            let stepSign = direction == .up ? -1 : 1
            targetIndex = computeVerticalTargetIndex(
                appState: appState,
                currentIndex: currentIndex,
                stepSign: stepSign,
                count: images.count
            )
        } else {
            targetIndex = nextIndexForDirection(
                currentIndex,
                direction: direction,
                count: images.count,
                wrap: wrap,
                listMode: false
            )
        }

        appState.fileData.setCurrentIndex(targetIndex)
        appState.fileData.setCurrentImagePath(images[targetIndex])
        applyRangeSelection(appState: appState, images: images, index: targetIndex)
    }

    private func resolvedCurrentIndex(appState: AppState, images: [String]) -> Int {
        guard !images.isEmpty else { return 0 }
        if let path = appState.fileData.currentImagePath,
           let index = images.firstIndex(of: path) {
            return index
        }
        let idx = appState.fileData.currentIndex
        return min(max(0, idx), images.count - 1)
    }

    /// Column-aware vertical step for Shift+Up/Down. Port of Python `_compute_shift_vertical_target`.
    private func computeVerticalTargetIndex(
        appState: AppState,
        currentIndex: Int,
        stepSign: Int,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        let safeCurrent = min(max(0, currentIndex), count - 1)
        if let rowLayout = appState.thumbnailSectionedRowLayout,
           !appState.duplicateSections.isEmpty {
            return rowLayout.verticalTarget(currentIndex: safeCurrent, stepSign: stepSign)
        }
        let columns = max(1, resolvedThumbnailColumns(appState: appState, count: count))
        let row = safeCurrent / columns
        let col = safeCurrent % columns
        let targetRow = row + stepSign
        if targetRow < 0 || targetRow > (count - 1) / columns {
            return safeCurrent
        }
        var targetIndex = targetRow * columns + col
        let lastIndex = count - 1
        if targetIndex > lastIndex {
            targetIndex = lastIndex
        }
        return targetIndex
    }

    private func navigateList(appState: AppState, direction: ThumbnailNavigateDirection, images: [String]) {
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        }
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let currentIndex = resolvedCurrentIndex(appState: appState, images: images)
        let next = nextIndex(currentIndex, delta: delta, count: images.count, wrap: wrap)
        appState.fileData.setCurrentImagePath(images[next])
    }

    private func navigateLinear(appState: AppState, direction: ThumbnailNavigateDirection, images: [String]) {
        let delta = (direction == .left || direction == .up) ? -1 : 1
        _ = navigateLinear(appState: appState, delta: delta, images: images)
    }

    private func navigateLinear(appState: AppState, delta: Int, images: [String]? = nil) -> Bool {
        let paths = images ?? appState.fileData.displayedImages
        guard !paths.isEmpty else { return false }
        if !appState.selection.selectedFiles.isEmpty {
            SelectionService.clearSelection(appState: appState, preserveCurrentImage: true)
            appState.selection.rangeAnchorIndex = nil
        }
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let currentIndex = resolvedCurrentIndex(appState: appState, images: paths)
        let next = nextIndex(currentIndex, delta: delta, count: paths.count, wrap: wrap)
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
        if appState.selection.multiSelectMode { SelectionService.clearSelection(appState: appState) }
        appState.selection.rangeAnchorIndex = nil
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(first)
        appState.listViewHost?.revealActiveRow(force: true)
    }

    private func jumpToLast(appState: AppState) {
        let images = appState.fileData.displayedImages
        guard let last = images.last else { return }
        if appState.selection.multiSelectMode { SelectionService.clearSelection(appState: appState) }
        appState.selection.rangeAnchorIndex = nil
        appState.fileData.setCurrentIndex(images.count - 1)
        appState.fileData.setCurrentImagePath(last)
        appState.listViewHost?.revealActiveRow(force: true)
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
        SelectionService.handleRangeSelection(
            appState: appState,
            currentIndex: index,
            anchor: appState.selection.rangeAnchorIndex
        )
    }

    private func openBrowse(appState: AppState) -> Bool {
        guard appState.fileData.currentImagePath != nil else { return false }
        resetBrowseDoubleTap()
        SelectionService.openBrowseForCurrentSelection(appState: appState)
        return true
    }

    private func returnToThumbnails(appState: AppState) -> Bool {
        resetBrowseDoubleTap()
        appState.closeBrowseView()
        return true
    }

    private func applySort(_ mode: SortMode, reversed: Bool, appState: AppState) {
        appState.applySortMode(mode, reversed: reversed)
    }

    private func pageScroll(appState: AppState, direction: Int) -> Bool {
        guard appState.fileData.currentViewMode == .thumbnail else { return false }
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        if appState.selection.multiSelectMode {
            SelectionService.clearSelection(appState: appState)
        }
        appState.selection.rangeAnchorIndex = nil

        let pageSize = thumbnailPageSize(appState: appState)
        let delta = direction * pageSize
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let current = resolvedCurrentIndex(appState: appState, images: images)
        let next = nextIndex(current, delta: delta, count: images.count, wrap: wrap)
        appState.fileData.setCurrentIndex(next)
        appState.fileData.setCurrentImagePath(images[next])
        return true
    }

    private func thumbnailPageSize(appState: AppState) -> Int {
        if let grid = appState.thumbnailGridHost, !appState.fileData.displayedImages.isEmpty {
            return grid.keyboardPageScrollDelta()
        }
        let images = appState.fileData.displayedImages
        let columns = max(1, thumbnailColumns(appState: appState, count: images.count))
        return max(columns, columns * 5)
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
        return computeVerticalTargetIndex(
            appState: appState,
            currentIndex: currentIndex,
            stepSign: stepSign,
            count: count
        )
    }

    private func resolvedThumbnailColumns(appState: AppState, count: Int) -> Int {
        if appState.thumbnailGridColumns > 0 {
            return appState.thumbnailGridColumns
        }
        return estimatedThumbnailColumns(appState: appState, count: count)
    }

    private func estimatedThumbnailColumns(appState: AppState, count: Int) -> Int {
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

    private func thumbnailColumns(appState: AppState, count: Int) -> Int {
        resolvedThumbnailColumns(appState: appState, count: count)
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

    private func resetBrowseDoubleTap() {
        doubleTapLastKey = nil
        doubleTapLastTime = 0
    }

    private func handleBrowseDoubleTap(
        _ event: NSEvent,
        keyCode: UInt16,
        appState: AppState,
        onMatch: () -> Void
    ) -> Bool {
        if event.isARepeat { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if doubleTapLastKey == keyCode, now - doubleTapLastTime < doubleTapWindow {
            doubleTapLastKey = nil
            doubleTapLastTime = 0
            onMatch()
            return true
        }
        doubleTapLastKey = keyCode
        doubleTapLastTime = now
        return true
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

    /// Forward delete (117) and backspace/delete (51) both map to trash shortcuts on macOS.
    private func isDeleteKey(_ event: NSEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
    }

    private func copyFilePathToClipboard(appState: AppState) -> Bool {
        let paths = appState.pathsForCopyPathCommand(focusWindow: NSApp.keyWindow)
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
            return true
        }
        appState.fileOperations.copyPathsToClipboard(paths)
        return true
    }

}
