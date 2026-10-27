import AppKit
import Foundation
import SwiftUI

@MainActor
enum SimilaritySearchService {
    static func run(appState: AppState, options: SimilaritySearchOptions) async {
        appState.prepareMainViewForImageSearch()

        let expandedCustom = AppState.expandedSearchDirectoryPath(options.customDirectory)
        var resolvedOptions = options
        resolvedOptions.customDirectory = expandedCustom

        let refs = referencePaths(appState: appState)
        let multiSelectRefs = refs.count > 1 ? refs : []
        guard !refs.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Reference Image", message: "Select or highlight an image to search from.")
            return
        }

        let respectFilenameFilter = !resolvedOptions.ignoreFilenameFilter
        let displayedSeed = appState.fileData.displayedImages
        let paths = SearchImagePathCollector.collectPaths(
            appState: appState,
            recursive: resolvedOptions.recursive,
            customDirectory: resolvedOptions.customDirectory,
            useCustomDirectory: resolvedOptions.useCustomDirectory,
            // Python always injects the reference image(s) into the candidate list,
            // even when searching a custom directory that does not contain them.
            includeDisplayed: refs,
            respectFilenameFilter: respectFilenameFilter,
            alwaysIncludeUnfiltered: Set(refs)
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No images found to search.")
            return
        }

        let searchDir = resolvedOptions.useCustomDirectory
            ? resolvedOptions.customDirectory
            : SearchImagePathCollector.currentSearchDirectory(appState: appState)
        appState.pinFileTreeForSearchScopeDirectory(
            resolvedOptions.customDirectory,
            useCustomDirectory: resolvedOptions.useCustomDirectory
        )
        let metricName = appState.config.string(forKey: "similarity_metric", default: "cosine")
        let resnetForLog = appState.config.string(forKey: "resnet_model", default: "resnet18")
        let filterForLog = respectFilenameFilter
            ? appState.filterSettings.filterPattern
            : "*"
        var scopeExtra = "metric=\(metricName) resnet=\(resnetForLog)"
        if resolvedOptions.ignoreFilenameFilter {
            scopeExtra += " ignore_filter=true"
        }
        SimilaritySearchLog.logScope(
            config: appState.config,
            kind: "CNN",
            candidateCount: paths.count,
            recursive: resolvedOptions.recursive,
            searchDirectory: searchDir,
            filterPattern: filterForLog,
            searchDepth: appState.config.int(forKey: "search_depth", default: 4),
            referencePaths: refs,
            extra: scopeExtra
        )

        appState.backgroundImageRecognition.suspendForForegroundSearch()
        defer { appState.backgroundImageRecognition.resumeAfterForegroundSearch() }
        appState.refreshImageRecognitionForCurrentSettings()

        let panel = CancellableProgressPanelController(
            title: "Find Similar Images",
            labelText: "Preparing…",
            maximum: paths.count,
            detailText: ImageSearchResultPresentation.searchIndexingDetailText,
            mutedNoteColor: NSColor(appState.theme.colors.dialogMutedText)
        )
        panel.show()
        func closeProgressPanel() {
            panel.close()
        }

        let resnet = appState.config.string(forKey: "resnet_model", default: "resnet18")
        let modelIDs = ModelManifest.resnetBundleIDs(for: resnet)
        let profile = appState.config.profilePaths
        let missingResnet = ImageRecognitionPaths.missingModelIDs(profile: profile, ids: modelIDs)
        let useCoreML = missingResnet.isEmpty
            || ModelManifest.isDownloadAvailable(
                profile: profile,
                downloadBaseURL: appState.config.imageRecognitionModelDownloadBaseURL(),
                modelIDs: missingResnet
            )

        let reportProgress: (Int, Int, String) -> Void = { cur, max, label in
            panel.setMaximum(max)
            panel.update(value: cur, label: label)
        }

        do {
            let refKeys = refs.compactMap { ImageRecognitionPath.normalize($0) }
            if refKeys.isEmpty {
                closeProgressPanel()
                StyledMessageDialog.showWarning(
                    title: "Reference Not Found",
                    message: "Could not resolve the reference image path for similarity search."
                )
                return
            }
            let features: [String: [Float]]
            if useCoreML {
                features = try await appState.imageRecognition.cnnFeatures(
                    for: paths,
                    config: appState.config,
                    progress: reportProgress,
                    shouldCancel: { panel.cancelRequested }
                )
            } else {
                features = try await appState.imageRecognition.visionFeatures(
                    for: paths,
                    progress: reportProgress,
                    shouldCancel: { panel.cancelRequested }
                )
            }
            if panel.cancelRequested {
                closeProgressPanel()
                appState.imageRecognition.flushCaches()
                appState.status.show("Similar image search cancelled")
                return
            }

            let refFeatureCount = refKeys.compactMap { features[$0] }.count
            if refFeatureCount == 0 {
                closeProgressPanel()
                StyledMessageDialog.showWarning(
                    title: "Reference Features Missing",
                    message:
                        "Could not compute CNN features for the reference image. "
                        + "Try clearing the CNN feature cache in Settings → Caches and search again."
                )
                return
            }

            panel.beginIndeterminatePhase(label: "Sorting by similarity and building thumbnail view...")

            let metric = SimilarityOrdering.Metric.fromSettings(
                appState.config.string(forKey: "similarity_metric", default: "cosine")
            )
            let pathsCopy = paths
            var ordered = await Task.detached(priority: .userInitiated) {
                SimilarityOrdering.orderBySimilarity(
                    paths: pathsCopy,
                    features: features,
                    referencePaths: refKeys,
                    metric: metric
                )
            }.value

            if panel.cancelRequested {
                closeProgressPanel()
                appState.imageRecognition.flushCaches()
                appState.status.show("Similar image search cancelled")
                return
            }

            guard !ordered.isEmpty else {
                closeProgressPanel()
                StyledMessageDialog.showWarning(title: "No Results", message: "No similar images found.")
                return
            }

            if respectFilenameFilter {
                ordered = DirectoryScanner.filterPathsMatchingPattern(
                    ordered,
                    pattern: appState.filterSettings.filterPattern
                )
                guard !ordered.isEmpty else {
                    closeProgressPanel()
                    StyledMessageDialog.showWarning(title: "No Results", message: "No similar images found.")
                    return
                }
            }

            panel.beginIndeterminatePhase(label: "Updating thumbnail view…")

            let indexedCount = paths.filter { features[$0] != nil }.count
            let sampleDim = refKeys.compactMap { features[$0] }.first?.count
            let backend = useCoreML ? "CoreML" : "Vision"
            SimilaritySearchLog.logFeatureSummary(
                config: appState.config,
                kind: "CNN",
                candidateCount: paths.count,
                indexedCount: indexedCount,
                featureDimension: sampleDim,
                modelLabel: useCoreML ? resnet : "Vision",
                metric: metric.rawValue
            )
            SimilaritySearchLog.logTopCNNScores(
                config: appState.config,
                paths: paths,
                features: features,
                referencePaths: refKeys,
                metric: metric
            )
            SimilaritySearchLog.log(
                appState.config,
                "CNN result count=\(ordered.count) backend=\(backend)"
            )

            let resnetLabel = resnet.replacingOccurrences(of: "resnet", with: "ResNet")
            let statusMessage = useCoreML
                ? "Similar images (\(ordered.count) files, \(indexedCount) indexed, \(resnetLabel))"
                : "Similar images (\(ordered.count) files, \(indexedCount) indexed, Vision)"
            if indexedCount < max(3, paths.count / 4) {
                appState.status.show(
                    "Only \(indexedCount) of \(paths.count) images were indexed — clear CNN cache in Settings if this persists",
                    duration: 6,
                    alwaysShow: true
                )
            }
            let filesChanged = Set(displayedSeed) != Set(ordered)
            await ImageSearchResultPresentation.applyCustomOrderedList(
                appState: appState,
                orderedPaths: ordered,
                currentImagePath: appState.fileData.currentImagePath,
                statusMessage: statusMessage,
                saveHistory: filesChanged || resolvedOptions.recursive,
                multiSelectReferencePaths: multiSelectRefs.isEmpty ? nil : multiSelectRefs,
                waitForViewportThumbnails: true
            )
            closeProgressPanel()
        } catch ModelDownloadError.userDeclined {
            closeProgressPanel()
        } catch is ModelDownloadError {
            closeProgressPanel()
        } catch {
            closeProgressPanel()
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        var value = false
    }

    private static func referencePaths(appState: AppState) -> [String] {
        let selected = SelectionService.orderedSelectedFiles(appState: appState)
        if selected.count > 1 { return selected }
        if let current = appState.fileData.currentImagePath { return [current] }
        return selected
    }
}
