import AppKit
import Foundation

/// Search sheets, browse exit before search, copy-path parity, tree search scope.
extension AppState {
    enum PersonSearchSheetWindowTitle {
        static let knownPerson = "Search for Known Person"
        static let personInCurrentImage = "Search for Person in Current Image"
    }

    struct SearchSheetDirectoryPrime: Sendable {
        var useCustomDirectory: Bool
        var customDirectory: String
    }

    /// Captured at search shortcut keyDown while the file tree may still be first responder.
    struct SearchInvocationTreeContext: Sendable {
        var hadTreeFocus: Bool
        var scopeDirectory: String?
    }

    func consumeSimilaritySearchDirectoryPrime() -> SearchSheetDirectoryPrime? {
        defer { pendingSimilaritySearchDirectoryPrime = nil }
        return pendingSimilaritySearchDirectoryPrime
    }

    /// Call from the local key monitor before menu shortcuts or focus changes (Python menu `tree_had_focus` capture).
    func recordSearchInvocationTreeContextFromKeyEvent(_ event: NSEvent) {
        guard KeyboardHandlerController.isSearchDirectoryPrimingShortcut(event) else { return }
        syncFileTreeKeyboardFocus(from: event.window)
        let focused = fileTreePaneHasKeyboardFocus(in: event.window)
        let scope = focused ? fileTreeSearchScopeDirectory() : nil
        pendingSearchInvocationTreeContext = SearchInvocationTreeContext(
            hadTreeFocus: focused,
            scopeDirectory: scope
        )
    }

    func captureSearchInvocationTreeContext() -> SearchInvocationTreeContext {
        if let pending = pendingSearchInvocationTreeContext {
            pendingSearchInvocationTreeContext = nil
            return pending
        }
        syncFileTreeKeyboardFocus()
        let focused = fileTreePaneHasKeyboardFocus()
        return SearchInvocationTreeContext(
            hadTreeFocus: focused,
            scopeDirectory: focused ? fileTreeSearchScopeDirectory() : nil
        )
    }

    func fileTreeSearchScopeDirectory() -> String? {
        guard let path = fileTreeOutlineView?.coordinator?.treeSearchScopeDirectoryPath() else { return nil }
        guard !FileTreePathRestrictions.isRootOrSystemVolume(path) else { return nil }
        return path
    }

    func primeClipSearchDirectoryForPresentation(
        directoryOverride: String?,
        treeContext: SearchInvocationTreeContext
    ) {
        if let explicit = directoryOverride.flatMap({ Self.expandedSearchDirectoryPath($0) }),
           !explicit.isEmpty {
            primeClipSearchDirectory(useCustomDirectory: true, directory: explicit)
            return
        }
        if treeContext.hadTreeFocus, let dir = treeContext.scopeDirectory {
            primeClipSearchDirectory(useCustomDirectory: true, directory: dir)
        }
    }

    func primePersonSearchDirectoryForPresentation(
        directoryOverride: String?,
        treeContext: SearchInvocationTreeContext
    ) {
        if let explicit = directoryOverride.flatMap({ Self.expandedSearchDirectoryPath($0) }),
           !explicit.isEmpty {
            primePersonSearchDirectory(useCustomDirectory: true, directory: explicit)
            return
        }
        if treeContext.hadTreeFocus, let dir = treeContext.scopeDirectory {
            primePersonSearchDirectory(useCustomDirectory: true, directory: dir)
        }
    }

    func primeSimilaritySearchDirectoryForPresentation(
        directoryOverride: String?,
        treeContext: SearchInvocationTreeContext
    ) {
        if let explicit = directoryOverride.flatMap({ Self.expandedSearchDirectoryPath($0) }),
           !explicit.isEmpty {
            let expanded = Self.expandedSearchDirectoryPath(explicit)
            pendingSimilaritySearchDirectoryPrime = SearchSheetDirectoryPrime(
                useCustomDirectory: true,
                customDirectory: expanded
            )
            return
        }
        if treeContext.hadTreeFocus, let dir = treeContext.scopeDirectory {
            let expanded = Self.expandedSearchDirectoryPath(dir)
            pendingSimilaritySearchDirectoryPrime = SearchSheetDirectoryPrime(
                useCustomDirectory: true,
                customDirectory: expanded
            )
        }
    }

    func primePersonSearchDirectory(useCustomDirectory: Bool, directory: String) {
        let expanded = Self.expandedSearchDirectoryPath(directory)
        pendingPersonSearchDirectoryPrime = SearchSheetDirectoryPrime(
            useCustomDirectory: useCustomDirectory,
            customDirectory: expanded
        )
    }

    func consumePersonSearchDirectoryPrime() -> SearchSheetDirectoryPrime? {
        defer { pendingPersonSearchDirectoryPrime = nil }
        return pendingPersonSearchDirectoryPrime
    }

    func primeClipSearchDirectory(useCustomDirectory: Bool, directory: String) {
        let expanded = Self.expandedSearchDirectoryPath(directory)
        pendingClipSearchDirectoryPrime = SearchSheetDirectoryPrime(
            useCustomDirectory: useCustomDirectory,
            customDirectory: expanded
        )
    }

    func consumeClipSearchDirectoryPrime() -> SearchSheetDirectoryPrime? {
        defer { pendingClipSearchDirectoryPrime = nil }
        return pendingClipSearchDirectoryPrime
    }

    static func expandedSearchDirectoryPath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .expandingTildeInPath
    }

    /// Port of Python `close_browse_view` before CLIP/CNN/person/duplicate searches (not blunt thumbnail flip).
    func prepareMainViewForImageSearch() {
        switch fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            fileData.setViewMode(.thumbnail)
        case .list:
            toggleListView()
        case .browse:
            closeBrowseView()
        case .thumbnail:
            break
        }
    }

    func fileTreeHasKeyboardFocus(in window: NSWindow?) -> Bool {
        fileTreePaneHasKeyboardFocus(in: window)
    }

    /// Tree pane owns keyboard routing (outline or tree tab stop first responder, synced with titlebar highlight).
    func fileTreePaneHasKeyboardFocus(in window: NSWindow? = nil) -> Bool {
        let win = window ?? fileTreeOutlineView?.window ?? NSApp.keyWindow
        syncFileTreeKeyboardFocus(from: win)
        return fileTreeKeyboardFocused
            || KeyboardHandlerController.fileTreeKeyboardTargetIsFocused(in: win)
    }

    /// Python `copy_file_path_to_clipboard` path resolution.
    func pathsForCopyPathCommand(focusWindow: NSWindow? = NSApp.keyWindow) -> [String] {
        if fileTreePaneHasKeyboardFocus(in: focusWindow),
           let outline = fileTreeOutlineView,
           let path = outline.coordinator?.selectedTreeRowPath() {
            return [path]
        }
        if fileData.currentViewMode == .thumbnail, selection.selectedFiles.count > 1 {
            return Array(selection.selectedFiles).sorted()
        }
        if let current = fileData.currentImagePath {
            return [current]
        }
        return []
    }

    func pinFileTreeForSearchScopeDirectory(_ rawDirectory: String?, useCustomDirectory: Bool) {
        guard useCustomDirectory,
              let rawDirectory,
              !rawDirectory.isEmpty else { return }
        let expanded = Self.expandedSearchDirectoryPath(rawDirectory)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        pinUserRequestedTreeDirectoryUntilActiveImageChanges(expanded)
    }

    /// Keep tree highlight on this folder until the active image leaves it (search progress / results).
    func pinUserRequestedTreeDirectoryUntilActiveImageChanges(_ rawDirectory: String) {
        userRequestedTreeClearWork?.cancel()
        userRequestedTreeClearWork = nil
        userRequestedTreeDirectory = FileTreeFilter.standardizedPath(rawDirectory)
        syncFileTreeToActiveImage()
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
