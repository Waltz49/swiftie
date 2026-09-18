import Foundation

@MainActor
enum SimilaritySearchService {
    static func run(appState: AppState, options: SimilaritySearchOptions) async {
        if appState.fileData.currentViewMode == .list {
            appState.toggleListView()
        }
        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }

        let refs = referencePaths(appState: appState)
        let multiSelectRefs = refs.count > 1 ? refs : []
        guard !refs.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Reference Image", message: "Select or highlight an image to search from.")
            return
        }

        let displayedSeed = appState.fileData.displayedImages
        let paths = SearchImagePathCollector.collectPaths(
            appState: appState,
            recursive: options.recursive,
            customDirectory: options.customDirectory,
            useCustomDirectory: options.useCustomDirectory,
            includeDisplayed: refs
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No images found to search.")
            return
        }

        let panel = CancellableProgressPanelController(
            title: "Find Similar Images",
            labelText: "Preparing…",
            maximum: paths.count
        )
        panel.show()

        let resnet = appState.config.string(forKey: "resnet_model", default: "resnet18")
        let modelIDs = ModelManifest.resnetBundleIDs(for: resnet)
        let profile = appState.config.profilePaths
        let missingResnet = ImageRecognitionPaths.missingModelIDs(profile: profile, ids: modelIDs)
        let useCoreML = missingResnet.isEmpty
            || ModelManifest.isRemoteDownloadAvailable(modelIDs: missingResnet)

        let reportProgress: (Int, Int, String) -> Void = { cur, max, label in
            panel.setMaximum(max)
            panel.update(value: cur, label: label)
        }

        do {
            let refKeys = refs.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
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
                panel.close()
                appState.imageRecognition.flushCaches()
                appState.status.show("Similar image search cancelled")
                return
            }
            panel.close()

            let metric = SimilarityOrdering.Metric.fromSettings(
                appState.config.string(forKey: "similarity_metric", default: "cosine")
            )
            let pathsCopy = paths
            let ordered = await Task.detached(priority: .userInitiated) {
                SimilarityOrdering.orderBySimilarity(
                    paths: pathsCopy,
                    features: features,
                    referencePaths: refKeys,
                    metric: metric
                )
            }.value

            guard !ordered.isEmpty else {
                StyledMessageDialog.showWarning(title: "No Results", message: "No similar images found.")
                return
            }

            let statusMessage = useCoreML
                ? "Similar images (\(ordered.count))"
                : "Similar images (\(ordered.count), Vision)"
            let filesChanged = Set(displayedSeed) != Set(ordered)
            ImageSearchResultPresentation.applyCustomOrderedList(
                appState: appState,
                orderedPaths: ordered,
                currentImagePath: appState.fileData.currentImagePath,
                statusMessage: statusMessage,
                saveHistory: filesChanged || options.recursive,
                multiSelectReferencePaths: multiSelectRefs.isEmpty ? nil : multiSelectRefs
            )
        } catch ModelDownloadError.userDeclined {
            panel.close()
        } catch {
            panel.close()
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
