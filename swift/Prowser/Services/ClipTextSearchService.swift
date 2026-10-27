import AppKit
import Foundation
import SwiftUI

@MainActor
enum ClipTextSearchService {
    static func run(appState: AppState, options: ClipSearchOptions) async {
        appState.prepareMainViewForImageSearch()

        let expandedCustom = AppState.expandedSearchDirectoryPath(options.customDirectory)
        var resolvedOptions = options
        resolvedOptions.customDirectory = expandedCustom
        appState.pinFileTreeForSearchScopeDirectory(
            expandedCustom,
            useCustomDirectory: resolvedOptions.useCustomDirectory
        )

        let respectFilenameFilter = !resolvedOptions.ignoreFilenameFilter
        let displayedSeed = appState.fileData.displayedImages
        let includeDisplayed = resolvedOptions.useCustomDirectory ? [] : displayedSeed
        let paths = SearchImagePathCollector.collectPaths(
            appState: appState,
            recursive: resolvedOptions.recursive,
            customDirectory: resolvedOptions.customDirectory,
            useCustomDirectory: resolvedOptions.useCustomDirectory,
            includeDisplayed: includeDisplayed,
            respectFilenameFilter: respectFilenameFilter
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No images found to search.")
            return
        }

        let clipName = appState.config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let searchDir = resolvedOptions.useCustomDirectory ? resolvedOptions.customDirectory : SearchImagePathCollector.currentSearchDirectory(appState: appState)
        let filterForLog = respectFilenameFilter
            ? appState.filterSettings.filterPattern
            : "*"
        var scopeExtra =
            "threshold=\(String(format: "%.2f", options.threshold)) clip=\(clipName) prompt=\(options.prompt.prefix(120))"
        if resolvedOptions.ignoreFilenameFilter {
            scopeExtra += " ignore_filter=true"
        }
        SimilaritySearchLog.logScope(
            config: appState.config,
            kind: "CLIP text",
            candidateCount: paths.count,
            recursive: options.recursive,
            searchDirectory: searchDir,
            filterPattern: filterForLog,
            searchDepth: appState.config.int(forKey: "search_depth", default: 4),
            referencePaths: [],
            extra: scopeExtra
        )

        appState.backgroundImageRecognition.suspendForForegroundSearch()
        defer { appState.backgroundImageRecognition.resumeAfterForegroundSearch() }

        let modelIDs = ModelManifest.clipBundleIDs(for: clipName)
        do {
            try await ModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                modelIDs: modelIDs,
                purpose: "Download is required for Search by Text (⌘F) and background indexing."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch is ModelDownloadError {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
            return
        }
        appState.refreshImageRecognitionForCurrentSettings()

        let panel = CancellableProgressPanelController(
            title: "Search by Text",
            labelText: "Encoding prompt…",
            maximum: paths.count,
            detailText: ImageSearchResultPresentation.searchIndexingDetailText,
            mutedNoteColor: NSColor(appState.theme.colors.dialogMutedText)
        )
        panel.show()
        func closeProgressPanel() {
            panel.close()
        }

        do {
            var threshold = Float(options.threshold)
            let textFeature = try await appState.imageRecognition.clipTextFeature(
                prompt: options.prompt,
                config: appState.config
            )

            let imageFeatures = try await appState.imageRecognition.clipImageFeatures(
                for: paths,
                config: appState.config,
                progress: { cur, max, label in
                    panel.setMaximum(max)
                    panel.update(value: cur, label: label)
                },
                shouldCancel: { panel.cancelRequested }
            )

            if let samplePath = paths.first,
               let imageDim = imageFeatures[samplePath]?.count,
               imageDim != textFeature.count {
                closeProgressPanel()
                StyledMessageDialog.showWarning(
                    title: "CLIP Feature Mismatch",
                    message:
                        "Image features (\(imageDim)) and text features (\(textFeature.count)) use different sizes. "
                        + "Reinstall updated CLIP models and clear the CLIP feature cache in Settings → Caches, then search again."
                )
                return
            }
            if panel.cancelRequested {
                closeProgressPanel()
                appState.imageRecognition.flushCaches()
                appState.status.show("Text search cancelled")
                return
            }

            panel.beginIndeterminatePhase(label: "Ranking matches…")

            var ordered = SimilarityOrdering.clipTextRanked(
                paths: paths,
                features: imageFeatures,
                textFeature: textFeature,
                minimumSimilarity: threshold
            )

            if ordered.isEmpty,
               let highest = SimilarityOrdering.highestClipSimilarity(
                   paths: paths,
                   features: imageFeatures,
                   textFeature: textFeature
               ),
               highest < threshold {
                threshold = max(highest - 0.03, 0)
                ordered = SimilarityOrdering.clipTextRanked(
                    paths: paths,
                    features: imageFeatures,
                    textFeature: textFeature,
                    minimumSimilarity: threshold
                )
            }

            if ordered.isEmpty {
                closeProgressPanel()
                StyledMessageDialog.showInformation(
                    title: "No Matches Found",
                    message: "No images found matching the search criteria."
                )
                return
            }

            if respectFilenameFilter {
                ordered = DirectoryScanner.filterPathsMatchingPattern(
                    ordered,
                    pattern: appState.filterSettings.filterPattern
                )
                if ordered.isEmpty {
                    closeProgressPanel()
                    StyledMessageDialog.showInformation(
                        title: "No Matches Found",
                        message: "No images found matching the search criteria."
                    )
                    return
                }
            }

            panel.beginIndeterminatePhase(label: "Updating thumbnail view…")

            let indexedCount = paths.filter { imageFeatures[$0] != nil }.count
            SimilaritySearchLog.logFeatureSummary(
                config: appState.config,
                kind: "CLIP text",
                candidateCount: paths.count,
                indexedCount: indexedCount,
                featureDimension: textFeature.count,
                modelLabel: clipName
            )
            SimilaritySearchLog.logTopCLIPScores(
                config: appState.config,
                paths: paths,
                features: imageFeatures,
                textFeature: textFeature,
                threshold: threshold
            )
            SimilaritySearchLog.log(
                appState.config,
                "CLIP result count=\(ordered.count) threshold=\(String(format: "%.2f", threshold))"
            )

            let filesChanged = Set(displayedSeed) != Set(ordered)
            await ImageSearchResultPresentation.applyCustomOrderedList(
                appState: appState,
                orderedPaths: ordered,
                currentImagePath: ordered.first,
                statusMessage: "Text search (\(ordered.count) images)",
                saveHistory: filesChanged || options.recursive,
                waitForViewportThumbnails: true
            )
            closeProgressPanel()
        } catch ModelDownloadError.userDeclined {
            closeProgressPanel()
        } catch {
            closeProgressPanel()
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
        }
    }
}
