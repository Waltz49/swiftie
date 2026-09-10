import AppKit
import Foundation

/// Search menu actions (duplicates, similarity, etc.). Port of `file_operations_manager.py` search helpers.
@MainActor
final class SearchOperationsService {
    private weak var appState: AppState?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func presentSimilaritySearch() {
        guard let appState else { return }
        guard referencePaths(appState: appState).isEmpty == false else {
            showAlert("No reference image", informative: "Select an image first.")
            return
        }
        appState.showSimilaritySearchSheet = true
    }

    func findSimilarImages() {
        presentSimilaritySearch()
    }

    func presentPersonSearch() {
        guard let appState else { return }
        let subjects = KnownFacesStore.loadSubjects(dataDirectory: appState.config.dataDirectory)
        guard !subjects.isEmpty else {
            showAlert(
                "Search by Person",
                informative: "No known people with face samples. Add people in Settings → Face Recognition, or run Extract Faces first."
            )
            return
        }
        appState.showPersonSearchSheet = true
    }

    func runPersonSearch(
        subjectID: String,
        options: SimilaritySearchOptions,
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async throws -> (paths: [String], personName: String) {
        guard let appState else { return ([], "") }
        let candidates = collectCandidatePaths(appState: appState, options: options, references: [])
        guard !candidates.isEmpty else {
            throw SearchError.noCandidates
        }

        exitSlideshowIfNeeded(appState: appState)
        if appState.fileData.currentViewMode == .browse || appState.fileData.currentViewMode == .list {
            appState.fileData.setViewMode(.thumbnail)
        }

        let bridge = appState.workers.personSearch
        guard bridge.isAvailable else {
            throw SearchError.pythonUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            bridge.onFinished = { paths, personName in
                continuation.resume(returning: (paths, personName))
            }
            bridge.onError = { error in
                if error == "Cancelled" {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: SearchError.workerFailed(error))
                }
            }
            bridge.onProgress = onProgress
            do {
                try bridge.search(subjectID: subjectID, candidatePaths: candidates, scanMissing: true)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func applyPersonSearchResults(_ paths: [String], personName: String) {
        guard let appState else { return }
        guard !paths.isEmpty else {
            let label = personName.isEmpty ? "this person" : personName
            showAlert("No Matches Found", informative: "No images in the search space contain \"\(label)\".")
            return
        }

        let savedPath = appState.fileData.currentImagePath
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.fileData.setDisplayedImages(paths)
        if let savedPath, paths.contains(savedPath) {
            appState.fileData.setCurrentImagePath(savedPath)
        } else {
            appState.fileData.setCurrentIndex(0)
            appState.fileData.setCurrentImagePath(paths[0])
        }
        appState.fileData.setViewMode(.thumbnail)
        let label = personName.isEmpty ? "person" : personName
        appState.status.show("Person search (\(label)): \(paths.count) images")
    }

    func runSimilaritySearch(
        options: SimilaritySearchOptions,
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        guard let appState else { return [] }
        let references = referencePaths(appState: appState)
        guard !references.isEmpty else {
            throw SearchError.noReferenceImage
        }

        let candidates = collectCandidatePaths(appState: appState, options: options, references: references)
        guard !candidates.isEmpty else {
            throw SearchError.noCandidates
        }

        exitSlideshowIfNeeded(appState: appState)
        if appState.fileData.currentViewMode == .browse || appState.fileData.currentViewMode == .list {
            appState.fileData.setViewMode(.thumbnail)
        }

        let bridge = appState.workers.similaritySearch
        guard bridge.isAvailable else {
            throw SearchError.pythonUnavailable
        }

        let metric = appState.config.string(forKey: "similarity_metric", default: "cosine")
        return try await withCheckedThrowingContinuation { continuation in
            bridge.onFinished = { paths in
                continuation.resume(returning: paths)
            }
            bridge.onError = { error in
                if error == "Cancelled" {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: SearchError.workerFailed(error))
                }
            }
            bridge.onProgress = onProgress
            do {
                try bridge.search(
                    referencePaths: references,
                    candidatePaths: candidates,
                    similarityMetric: metric
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func applySimilarityResults(_ paths: [String]) {
        guard let appState else { return }
        guard !paths.isEmpty else {
            showAlert("No Matches Found", informative: "No similar images found matching the search criteria.")
            return
        }

        let savedPath = appState.fileData.currentImagePath
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.fileData.setDisplayedImages(paths)
        if let savedPath, paths.contains(savedPath) {
            appState.fileData.setCurrentImagePath(savedPath)
        } else {
            appState.fileData.setCurrentIndex(0)
            appState.fileData.setCurrentImagePath(paths[0])
        }
        appState.fileData.setViewMode(.thumbnail)
        appState.status.show("Similarity search: \(paths.count) images")
    }

    func findExactDuplicatesInDisplayed() {
        guard let appState else { return }
        let paths = filteredDisplayedPaths(appState: appState)
        guard !paths.isEmpty else {
            showAlert("No images displayed", informative: "")
            return
        }
        presentDuplicateResults(paths, appState: appState, scope: "current view")
    }

    func findExactDuplicatesRecursive() {
        guard let appState else { return }
        guard let directory = appState.fileData.currentDirectory else {
            showAlert("No directory open", informative: "Open a folder first.")
            return
        }
        let paths = DirectoryScanner.scanDirectoryRecursive(
            at: directory,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern
        )
        guard !paths.isEmpty else {
            showAlert("No images found", informative: "No matching images in this folder tree.")
            return
        }
        presentDuplicateResults(paths, appState: appState, scope: "recursive")
    }

    private func referencePaths(appState: AppState) -> [String] {
        let displayed = Set(appState.fileData.displayedImages)
        let selected = appState.selection.selectedFiles.filter { displayed.contains($0) }
        if selected.count > 1 {
            return selected.sorted()
        }
        if let current = appState.fileData.currentImagePath, FileManager.default.fileExists(atPath: current) {
            return [current]
        }
        return []
    }

    private func collectCandidatePaths(
        appState: AppState,
        options: SimilaritySearchOptions,
        references: [String]
    ) -> [String] {
        let extensions = appState.config.imageExtensions
        let filterPattern = appState.filterSettings.filterPattern
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)

        var paths: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(resolved).inserted else { return }
            guard FileManager.default.fileExists(atPath: resolved) else { return }
            if filterPattern != "*" && !filterPattern.isEmpty {
                let name = (resolved as NSString).lastPathComponent
                guard DirectoryScanner.matchesGlob(name, pattern: filterPattern) else { return }
            }
            paths.append(resolved)
        }

        for ref in references { add(ref) }

        if options.recursive {
            let searchDir: String
            if options.useCustomDirectory,
               !options.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchDir = (options.directoryPath as NSString).expandingTildeInPath
            } else if let current = appState.fileData.currentDirectory {
                searchDir = current
            } else {
                searchDir = (references.first as NSString?)?.deletingLastPathComponent ?? ""
            }
            guard !searchDir.isEmpty, FileManager.default.fileExists(atPath: searchDir) else { return paths }
            if searchDir == "/" {
                return paths
            }
            let scanned = DirectoryScanner.scanDirectoryRecursive(
                at: searchDir,
                extensions: extensions,
                filterPattern: filterPattern,
                maxDepth: maxDepth,
                excludedPaths: excluded,
                includeHidden: showHidden
            )
            for path in scanned { add(path) }
        } else if options.useCustomDirectory,
                  !options.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searchDir = (options.directoryPath as NSString).expandingTildeInPath
            let scanned = DirectoryScanner.scanDirectory(
                at: searchDir,
                extensions: extensions,
                filterPattern: filterPattern
            )
            for path in scanned { add(path) }
        } else {
            for path in appState.fileData.displayedImages { add(path) }
        }

        return paths
    }

    private func filteredDisplayedPaths(appState: AppState) -> [String] {
        let displayed = appState.fileData.displayedImages
        let pattern = appState.filterSettings.filterPattern
        if pattern == "*" || pattern.isEmpty { return displayed }
        return displayed.filter { DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern) }
    }

    private func presentDuplicateResults(_ paths: [String], appState: AppState, scope: String) {
        exitSlideshowIfNeeded(appState: appState)

        let duplicates = DuplicateHashService.duplicateSortedPaths(paths)
        guard !duplicates.isEmpty else {
            showAlert("No Duplicates Found", informative: "No exact byte-for-byte duplicates found (\(scope)).")
            return
        }

        let savedPath = appState.fileData.currentImagePath
        appState.config.updateSetting("sort_mode", value: SortMode.duplicates.rawValue)
        appState.fileData.setDisplayedImages(duplicates)
        if let savedPath, duplicates.contains(savedPath) {
            appState.fileData.setCurrentImagePath(savedPath)
        } else {
            appState.fileData.setCurrentIndex(0)
            appState.fileData.setCurrentImagePath(duplicates[0])
        }
        appState.fileData.setViewMode(.browse)
    }

    private func exitSlideshowIfNeeded(appState: AppState) {
        switch appState.fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            appState.fileData.setViewMode(.thumbnail)
        default:
            break
        }
    }

    private func showAlert(_ title: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.runModal()
    }
}

enum SearchError: LocalizedError {
    case noReferenceImage
    case noCandidates
    case pythonUnavailable
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReferenceImage: return "No reference image selected."
        case .noCandidates: return "No images found to search."
        case .pythonUnavailable: return "Python environment is not available for similarity search."
        case .workerFailed(let message): return message
        }
    }
}
