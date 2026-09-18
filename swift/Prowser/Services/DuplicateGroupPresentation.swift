import Foundation

/// Finish path for exact-duplicate search (port of `_present_duplicate_groups_browse_view`).
@MainActor
enum DuplicateGroupPresentation {
    struct DuplicateSection: Equatable, Sendable {
        let startIndex: Int
        let groupKey: String
    }

    /// Within each byte-identical hash group, paths to multi-select: all but the lexicographically smallest full path.
    /// Covers duplicates in different subdirectories (one copy per folder) as well as multiple copies in one folder.
    nonisolated static func perDirectoryAutoSelectPaths(
        groupPathPairs: [(hash: String, path: String)]
    ) -> Set<String> {
        guard !groupPathPairs.isEmpty else { return [] }
        var out: Set<String> = []
        var index = 0
        let count = groupPathPairs.count
        while index < count {
            let fileHash = groupPathPairs[index].hash
            var groupPaths: [String] = []
            while index < count, groupPathPairs[index].hash == fileHash {
                groupPaths.append(normalizedPath(groupPathPairs[index].path))
                index += 1
            }
            let sorted = groupPaths.sorted()
            if sorted.count > 1 {
                out.formUnion(sorted.dropFirst())
            }
        }
        return out
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    nonisolated static func duplicateSections(from groupPathPairs: [(hash: String, path: String)]) -> [DuplicateSection] {
        var sections: [DuplicateSection] = []
        var currentKey: String?
        for (idx, pair) in groupPathPairs.enumerated() {
            if pair.hash != currentKey {
                sections.append(DuplicateSection(startIndex: idx, groupKey: pair.hash))
                currentKey = pair.hash
            }
        }
        return sections
    }

    static func present(
        appState: AppState,
        groupPathPairs: [(hash: String, path: String)],
        currentImagePath: String?,
        statusMessage: String,
        autoSelect: Bool = true
    ) {
        guard !groupPathPairs.isEmpty else { return }

        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )

        let normalizedPairs: [(hash: String, path: String)] = groupPathPairs.compactMap { pair in
            guard let path = FileDataModel.normalizePath(pair.path) else { return nil }
            return (hash: pair.hash, path: path)
        }
        guard !normalizedPairs.isEmpty else { return }

        let displayed = normalizedPairs.map(\.path)
        let sections = duplicateSections(from: normalizedPairs)
        let autoSel = autoSelect
            ? perDirectoryAutoSelectPaths(groupPathPairs: normalizedPairs)
            : Set<String>()

        appState.duplicateSections = sections
        appState.config.updateSetting("sort_mode", value: SortMode.duplicates.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)
        appState.setSpecificFilesActive(true)

        if autoSelect {
            if !autoSel.isEmpty {
                appState.selection.selectedFiles = autoSel
            } else {
                appState.selection.clear()
            }
        } else {
            appState.selection.clear()
        }

        appState.fileData.setDisplayedImages(displayed)

        if autoSelect {
            if !autoSel.isEmpty {
                let keeper = displayed.first { !autoSel.contains($0) } ?? displayed[0]
                appState.fileData.setCurrentImagePath(keeper)
            } else if let currentImagePath,
                      let normalized = FileDataModel.normalizePath(currentImagePath),
                      displayed.contains(normalized) {
                appState.fileData.setCurrentImagePath(normalized)
            } else if let first = displayed.first {
                appState.fileData.setCurrentImagePath(first)
            }
            let highlightIndex = appState.fileData.displayedImages.firstIndex(
                of: appState.fileData.currentImagePath ?? ""
            )
            appState.selection.emitSelectionChanged(highlightIndex: highlightIndex)
        } else {
            if let currentImagePath,
               let normalized = FileDataModel.normalizePath(currentImagePath),
               displayed.contains(normalized) {
                appState.fileData.setCurrentImagePath(normalized)
            } else if let first = displayed.first {
                appState.fileData.setCurrentImagePath(first)
            }
            let highlightIndex = appState.fileData.displayedImages.firstIndex(
                of: appState.fileData.currentImagePath ?? ""
            )
            appState.selection.emitSelectionChanged(highlightIndex: highlightIndex)
        }

        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        } else if appState.fileData.currentViewMode != .thumbnail {
            appState.fileData.setViewMode(.thumbnail)
        }

        appState.thumbnailGridHost?.reloadLayoutIfNeeded()
        appState.status.show(statusMessage)
        appState.menuRefresh.refreshAll()
    }

    static func clearDuplicatePresentation(appState: AppState) {
        if !appState.duplicateSections.isEmpty {
            appState.duplicateSections = []
        }
    }
}
