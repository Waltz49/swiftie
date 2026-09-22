import Foundation

/// Remove thumbnail-list entries whose paths match enabled exclude rules (Python `exclude_files_from_view`).
@MainActor
enum ThumbnailExcludeService {
    static func hasEnabledExcludeRules(config: AppConfig) -> Bool {
        !enabledExcludeSubstrings(config: config).isEmpty
    }

    static func excludeFilesFromView(appState: AppState) {
        guard appState.fileData.currentViewMode == .thumbnail else { return }

        let rules = enabledExcludeSubstrings(config: appState.config)
        guard !rules.isEmpty else { return }

        let displayed = appState.fileData.displayedImages
        guard !displayed.isEmpty else { return }

        var filtered: [String] = []
        for imagePath in displayed {
            guard FileManager.default.fileExists(atPath: imagePath) else { continue }
            guard let fullPath = FileDataModel.normalizePath(imagePath) else { continue }
            let shouldExclude = rules.contains { fullPath.contains($0) }
            if !shouldExclude {
                filtered.append(imagePath)
            }
        }

        guard !filtered.isEmpty else {
            StyledMessageDialog.showWarning(
                title: "Cannot Exclude",
                message: "Excluding these directories would leave no images to display."
            )
            return
        }

        appState.fileData.setDisplayedImages(filtered)

        let existingSelection = appState.selection.selectedFiles.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        if existingSelection != appState.selection.selectedFiles {
            appState.selection.selectedFiles = existingSelection
            appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
        }

        appState.menuRefresh.refreshAll()
    }

    private static func enabledExcludeSubstrings(config: AppConfig) -> [String] {
        config.excludeDirectories().compactMap { entry in
            guard entry["enabled"] as? Bool == true else { return nil }
            guard let raw = entry["path"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed as NSString).expandingTildeInPath
        }
    }
}
