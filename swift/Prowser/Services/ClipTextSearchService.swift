import Foundation

@MainActor
enum ClipTextSearchService {
    static func run(appState: AppState, options: ClipSearchOptions) async {
        if appState.fileData.currentViewMode == .list {
            appState.toggleListView()
        }
        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }

        let displayedSeed = appState.fileData.displayedImages
        let paths = SearchImagePathCollector.collectPaths(
            appState: appState,
            recursive: options.recursive,
            customDirectory: options.customDirectory,
            useCustomDirectory: options.useCustomDirectory,
            includeDisplayed: displayedSeed
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No images found to search.")
            return
        }

        let panel = CancellableProgressPanelController(
            title: "Search by Text",
            labelText: "Encoding prompt…",
            maximum: paths.count
        )
        panel.show()

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
            panel.close()
            if panel.cancelRequested {
                appState.imageRecognition.flushCaches()
                appState.status.show("Text search cancelled")
                return
            }

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
                StyledMessageDialog.showInformation(
                    title: "No Matches Found",
                    message: "No images found matching the search criteria."
                )
                return
            }

            let filesChanged = Set(displayedSeed) != Set(ordered)
            ImageSearchResultPresentation.applyCustomOrderedList(
                appState: appState,
                orderedPaths: ordered,
                currentImagePath: appState.fileData.currentImagePath,
                statusMessage: "Text search (\(ordered.count) images)",
                saveHistory: filesChanged || options.recursive
            )
        } catch ModelDownloadError.userDeclined {
            panel.close()
        } catch {
            panel.close()
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
        }
    }
}
