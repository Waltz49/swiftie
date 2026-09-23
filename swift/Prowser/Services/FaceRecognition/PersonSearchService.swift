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
                title: "Search by person",
                message: "Native dlib is not linked in this build. Run swift/Scripts/build_dlib_macos.sh and rebuild."
            )
            return
        }

        let store = appState.knownFaces
        guard let subject = store.subject(id: options.subjectID), !subject.samples.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search by person", message: "No face samples found for this person.")
            return
        }
        let knownEncodings = subject.samples.compactMap { sample -> [Double]? in
            sample.embedding.count == 128 ? sample.embedding : nil
        }
        guard !knownEncodings.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search by person", message: "No face encodings for this person.")
            return
        }

        if appState.fileData.currentViewMode == .list { appState.toggleListView() }
        if appState.fileData.currentViewMode == .browse { appState.fileData.setViewMode(.thumbnail) }

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

        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required for Search by Person (⌘P) and face caching."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Search Failed", message: error.localizedDescription)
            return
        }

        let panel = CancellableProgressPanelController(
            title: "Search by person",
            labelText: "Gathering images…",
            maximum: paths.count
        )
        panel.show()

        let profile = appState.config.profilePaths
        FaceGatheringCoordinator.setForegroundFaceScanActive(true, profile: profile)
        defer { FaceGatheringCoordinator.setForegroundFaceScanActive(false, profile: profile) }

        let extensions = appState.config.imageExtensions
        let cached = await FaceScanRunner.runScanAsync(
            profile: profile,
            faceCache: appState.faceCache,
            rootDirectory: paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? "",
            maxDepth: 0,
            imagePaths: paths,
            imageExtensions: extensions,
            progress: { cur, max, path, _, _ in
                Task { @MainActor in
                    panel.setMaximum(max)
                    panel.update(value: cur, label: (path as NSString).lastPathComponent)
                }
            },
            shouldCancel: { panel.cancelRequested }
        )
        _ = cached

        if panel.cancelRequested {
            panel.close()
            appState.status.show("Person search cancelled")
            return
        }

        panel.update(value: 0, label: "Matching faces…")
        var matching: [(path: String, distance: Double)] = []
        for (index, path) in paths.enumerated() {
            if panel.cancelRequested { break }
            panel.update(value: index, label: (path as NSString).lastPathComponent)
            guard let encodings = appState.faceCache.getEncodings(imagePath: path) else { continue }
            var bestMean: Double?
            for enc in encodings {
                guard FaceEngine.compareFaces(knownEncodings: knownEncodings, unknownEncoding: enc) else { continue }
                if let mean = FaceEngine.faceMeanDistance(knownEncodings: knownEncodings, unknownEncoding: enc) {
                    if bestMean == nil || mean < bestMean! { bestMean = mean }
                }
            }
            if let bestMean { matching.append((path, bestMean)) }
        }
        panel.close()

        matching.sort { $0.distance < $1.distance }
        let ordered = matching.map(\.path)
        if ordered.isEmpty {
            StyledMessageDialog.showInformation(title: "No Matches Found", message: "No images found containing this person.")
            return
        }

        let filesChanged = Set(displayedSeed) != Set(ordered)
        ImageSearchResultPresentation.applyCustomOrderedList(
            appState: appState,
            orderedPaths: ordered,
            currentImagePath: ordered.first,
            statusMessage: "Person search (\(ordered.count) images)",
            saveHistory: filesChanged || options.recursive
        )
    }
}
