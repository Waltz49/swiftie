import AppKit
import Foundation

struct PersonSearchOptions: Sendable {
    var subjectID: String
    var recursive: Bool
    var useCustomDirectory: Bool
    var customDirectory: String
}

@MainActor
enum PersonSearchService {
    static func run(appState: AppState, options: PersonSearchOptions) async {
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }

        guard FaceEngine.isBridgeLinked() else {
            StyledMessageDialog.showWarning(
                title: "Search for Known Person",
                message: "Native dlib is not linked in this build. Run swift/Scripts/build_dlib_macos.sh and rebuild."
            )
            return
        }

        let store = appState.knownFaces
        guard let subject = store.subject(id: options.subjectID), !subject.samples.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search for Known Person", message: "No face samples found for this person.")
            return
        }
        let knownEncodings = subject.samples.compactMap { sample -> [Double]? in
            sample.embedding.count == 128 ? sample.embedding : nil
        }
        guard !knownEncodings.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search for Known Person", message: "No face encodings for this person.")
            return
        }

        appState.prepareMainViewForImageSearch()

        let expandedCustom = AppState.expandedSearchDirectoryPath(options.customDirectory)
        var resolvedOptions = options
        resolvedOptions.customDirectory = expandedCustom
        appState.pinFileTreeForSearchScopeDirectory(
            expandedCustom,
            useCustomDirectory: resolvedOptions.useCustomDirectory
        )

        let displayedSeed = appState.fileData.displayedImages
        let includeDisplayed = resolvedOptions.useCustomDirectory ? [] : displayedSeed
        let paths = SearchImagePathCollector.collectPaths(
            appState: appState,
            recursive: resolvedOptions.recursive,
            customDirectory: resolvedOptions.customDirectory,
            useCustomDirectory: resolvedOptions.useCustomDirectory,
            includeDisplayed: includeDisplayed
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No images found to search.")
            return
        }

        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required for Search for Known Person (⌘P) and face caching."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
            return
        }

        let panel = CancellableProgressPanelController(
            title: "Search for Known Person",
            labelText: "Checking face cache…",
            maximum: 1,
            showsTimeRemainingEstimate: true,
            usesExtractionBasedTimeEstimate: true
        )
        panel.show()

        let profile = appState.config.profilePaths
        let faceCache = appState.faceCache
        let extensions = appState.config.imageExtensions

        let missingCount = await Task.detached(priority: .userInitiated) {
            paths.reduce(into: 0) { count, path in
                if !faceCache.hasCachedFaces(imagePath: path) { count += 1 }
            }
        }.value

        panel.setMaximum(paths.count)
        panel.setRemainingExtractionsForEstimate(max(missingCount, 1))
        panel.update(label: missingCount == 0 ? "Searching for known person…" : "Caching faces…")

        FaceGatheringCoordinator.setForegroundFaceScanActive(true, profile: profile)
        defer { FaceGatheringCoordinator.setForegroundFaceScanActive(false, profile: profile) }

        if missingCount > 0 {
            let cached = await FaceScanRunner.runScanAsync(
                profile: profile,
                faceCache: appState.faceCache,
                rootDirectory: paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? "",
                maxDepth: 0,
                imagePaths: paths,
                imageExtensions: extensions,
                progress: { cur, max, path, processed, extractionDuration in
                    Task { @MainActor in
                        panel.setMaximum(max)
                        panel.update(value: cur, label: "Caching faces… \((path as NSString).lastPathComponent)")
                    }
                    if processed, let extractionDuration {
                        panel.recordExtractionDuration(extractionDuration)
                    }
                },
                shouldCancel: { panel.cancelRequested }
            )
            _ = cached
        }

        if panel.cancelRequested {
            panel.close()
            appState.status.show("Search for known person cancelled")
            return
        }

        panel.setRemainingExtractionsForEstimate(paths.count)
        panel.update(value: 0, label: "Searching for known person…")

        let knownFloat = knownEncodings.map { $0.map(Float.init) }
        let tolerance = Float(FaceEngine.defaultTolerance)
        let cancelRequested = { panel.cancelRequested }

        var matching = await Task.detached(priority: .userInitiated) {
            var results: [(path: String, distance: Double)] = []
            results.reserveCapacity(paths.count / 4)
            for (index, path) in paths.enumerated() {
                if cancelRequested() { break }
                if index % 8 == 0 {
                    await Task.yield()
                    let progressIndex = index
                    let label = (path as NSString).lastPathComponent
                    await MainActor.run {
                        panel.update(value: progressIndex, label: label)
                    }
                }
                guard let encodings = faceCache.getEncodings(imagePath: path) else { continue }
                var bestMean: Double?
                for enc in encodings {
                    guard enc.count == 128 else { continue }
                    let encF = enc.map(Float.init)
                    guard FaceEngine.compareFaces(
                        knownEncodings: knownFloat,
                        unknownEncoding: encF,
                        tolerance: tolerance
                    ) else { continue }
                    if let mean = FaceEngine.meanFaceDistance(knownEncodings: knownFloat, unknownEncoding: encF) {
                        if bestMean == nil || mean < bestMean! { bestMean = mean }
                    }
                }
                if let bestMean { results.append((path, bestMean)) }
            }
            return results
        }.value

        matching.sort { $0.distance < $1.distance }
        let ordered = matching.map(\.path)
        if ordered.isEmpty {
            panel.close()
            StyledMessageDialog.showInformation(title: "No Matches Found", message: "No images found containing this person.")
            return
        }

        panel.beginIndeterminatePhase(label: "Updating thumbnail view…")

        let filesChanged = Set(displayedSeed) != Set(ordered)
        await ImageSearchResultPresentation.applyCustomOrderedList(
            appState: appState,
            orderedPaths: ordered,
            currentImagePath: ordered.first,
            statusMessage: "Search for known person (\(ordered.count) images)",
            saveHistory: filesChanged || resolvedOptions.recursive,
            waitForViewportThumbnails: true
        )
        panel.close()
    }
}
