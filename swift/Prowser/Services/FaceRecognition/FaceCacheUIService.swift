import AppKit
import Foundation

/// Cache Faces UI (port of `image_browser_window.cache_faces`).
@MainActor
enum FaceCacheUIService {
    static func cacheFaces(appState: AppState, recursive: Bool = true, directoryOverride: String? = nil) async {
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }

        guard FaceEngine.isBridgeLinked() else {
            StyledMessageDialog.showWarning(
                title: "Face recognition unavailable",
                message: "Native dlib is not linked in this build."
            )
            return
        }

        let currentDirectory = directoryOverride
            ?? SearchImagePathCollector.currentSearchDirectory(appState: appState)
            ?? ((appState.fileData.displayedImages.first as NSString?)?.deletingLastPathComponent)
        guard let currentDirectory, !currentDirectory.isEmpty,
              FileManager.default.fileExists(atPath: currentDirectory) else {
            StyledMessageDialog.showWarning(title: "No directory", message: "No current directory to cache faces in.")
            return
        }

        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required to cache face encodings (⌘=)."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Cache Faces", message: error.localizedDescription)
            return
        }

        let maxDepth: Int = {
            var depth = appState.config.int(forKey: "search_depth", default: 4)
            if !recursive { depth = 0 }
            return depth
        }()

        let panel = CancellableProgressPanelController(
            title: "Cache Faces",
            labelText: "Checking face cache…",
            maximum: 1,
            showsTimeRemainingEstimate: true,
            usesExtractionBasedTimeEstimate: true
        )
        panel.show()

        let profile = appState.config.profilePaths
        let faceCache = appState.faceCache
        let extensions = appState.config.imageExtensions

        let pathList = await Task.detached(priority: .userInitiated) {
            FaceScanRunner.imagePaths(
                rootDirectory: currentDirectory,
                maxDepth: maxDepth,
                imagePaths: nil,
                imageExtensions: extensions
            )
        }.value

        let missingCount = await Task.detached(priority: .userInitiated) {
            pathList.reduce(into: 0) { count, path in
                if !faceCache.hasCachedFaces(imagePath: path) { count += 1 }
            }
        }.value

        if pathList.isEmpty {
            panel.close()
            StyledMessageDialog.showInformation(
                title: "Cache Faces",
                message: "No images found in this directory (and subdirs to depth \(maxDepth))."
            )
            return
        }

        if missingCount == 0 {
            panel.close()
            StyledMessageDialog.showInformation(
                title: "Cache Faces",
                message: "All \(pathList.count) images already have face data in the cache (including images with no faces found)."
            )
            return
        }

        panel.setMaximum(pathList.count)
        panel.setRemainingExtractionsForEstimate(missingCount)
        panel.update(label: "Caching faces…")

        FaceGatheringCoordinator.setForegroundFaceScanActive(true, profile: profile)
        defer { FaceGatheringCoordinator.setForegroundFaceScanActive(false, profile: profile) }

        let count = await FaceScanRunner.runScanAsync(
            profile: profile,
            faceCache: faceCache,
            rootDirectory: currentDirectory,
            maxDepth: maxDepth,
            imagePaths: pathList,
            imageExtensions: extensions,
            progress: { cur, max, path, processed, extractionDuration in
                Task { @MainActor in
                    panel.setMaximum(max)
                    panel.update(value: cur, label: (path as NSString).lastPathComponent)
                }
                if processed, let extractionDuration {
                    panel.recordExtractionDuration(extractionDuration)
                }
            },
            shouldCancel: { panel.cancelRequested }
        )
        panel.close()
        if panel.cancelRequested {
            appState.status.show("Cache faces cancelled")
        } else {
            appState.status.show("Cached faces for \(count) images")
        }
    }

}
