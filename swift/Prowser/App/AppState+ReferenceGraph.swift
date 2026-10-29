import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    /// Python ``InformationSidebar._on_anchor_clicked`` for ``reflevel://``.
    func handleInformationReferenceLevelClick(optionHeld: Bool) {
        guard let path = fileData.currentImagePath,
              FileManager.default.isReadableFile(atPath: path) else { return }
        Task { @MainActor in
            guard let comment = await ExifService.userDescription(path: path) else { return }
            let imageDir = (path as NSString).deletingLastPathComponent
            let entries = ReferenceGraphService.parseReferenceEntries(from: comment)
            guard !entries.isEmpty else { return }

            if optionHeld {
                let (paths, _, extensionSwapped) = ReferenceGraphService.resolveExifReferencePaths(
                    imageDir: imageDir,
                    currentPath: path,
                    entries: entries
                )
                guard !paths.isEmpty else { return }
                if extensionSwapped {
                    status.show(
                        "Some references were found with a different file extension",
                        duration: 5
                    )
                }
                openReferencePaths(paths, focusPath: path)
                return
            }

            let (paths, extensionSwapped) = await ReferenceGraphService.collectReferenceChainPaths(
                imageDir: imageDir,
                rootPath: path,
                entries: entries
            )
            guard paths.count >= 2 else {
                StyledMessageDialog.showInformation(
                    title: "No References Found",
                    message: """
                    This image has no reference information in its EXIF user comment. \
                    References are saved there by the image generation functions when \
                    an image is created from other images.
                    """
                )
                return
            }
            if extensionSwapped {
                status.show(
                    "Some references were found with a different file extension",
                    duration: 5
                )
            }
            await openReferenceGraphPresentation(
                paths: paths,
                focusPath: path,
                extensionSwapped: extensionSwapped
            )
        }
    }

    func showReferenceGraph(for path: String? = nil) {
        guard let imagePath = path ?? fileData.currentImagePath else { return }
        Task { @MainActor in
            await openReferenceGraph(for: imagePath)
        }
    }

    /// Python ``open_reference_graph_for_path``.
    func openReferenceGraph(for imagePath: String) async {
        guard FileManager.default.isReadableFile(atPath: imagePath) else { return }
        guard let comment = await ExifService.userDescription(path: imagePath) else {
            status.show("No EXIF user comment on this image")
            return
        }
        let imageDir = (imagePath as NSString).deletingLastPathComponent
        let entries = ReferenceGraphService.parseReferenceEntries(from: comment)
        guard !entries.isEmpty else {
            StyledMessageDialog.showInformation(
                title: "No References Found",
                message: """
                This image has no reference information in its EXIF user comment. \
                References are saved there by the image generation functions when \
                an image is created from other images.
                """
            )
            return
        }
        let (paths, extensionSwapped) = await ReferenceGraphService.collectReferenceChainPaths(
            imageDir: imageDir,
            rootPath: imagePath,
            entries: entries
        )
        guard paths.count >= 2 else {
            StyledMessageDialog.showInformation(
                title: "No References Found",
                message: """
                This image has no reference information in its EXIF user comment. \
                References are saved there by the image generation functions when \
                an image is created from other images.
                """
            )
            return
        }
        await openReferenceGraphPresentation(
            paths: paths,
            focusPath: imagePath,
            extensionSwapped: extensionSwapped
        )
    }

    func clearReferenceGraphPresentation() {
        referenceGraphActive = false
        referenceGraphData = nil
        referenceGraphFocusPath = nil
        watchCurrentDirectory()
    }

    /// Python ``set_reference_graph_presentation``: build the DAG for a specific-files level.
    /// Focus falls back to the current image, then the first path, when not in the set.
    func setReferenceGraphPresentation(paths: [String], focusPath: String?) async {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count > 1 else {
            clearReferenceGraphPresentation()
            return
        }
        var focus = focusPath ?? fileData.currentImagePath ?? normalized[0]
        if let focusNorm = FileDataModel.normalizePath(focus), !normalized.contains(focusNorm) {
            focus = normalized[0]
        }
        let graph = await ReferenceGraphService.buildReferenceGraph(paths: normalized, focusPath: focus)
        referenceGraphActive = true
        referenceGraphData = graph
        referenceGraphFocusPath = graph.focusPath ?? focus
    }

    func openReferenceGraphPresentation(
        paths: [String],
        focusPath: String,
        extensionSwapped: Bool = false
    ) async {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count >= 2 else { return }
        if extensionSwapped {
            status.show(
                "Some references were found with a different file extension",
                duration: 5
            )
        }

        directoryHistory.saveCurrent(fileData: fileData, config: config, selection: selection)
        directoryLoader.cancelPendingDirectoryLoad()

        await setReferenceGraphPresentation(paths: normalized, focusPath: focusPath)

        config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        config.updateSetting("sort_reversed", value: false)
        let directory = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
        setSpecificFilesActive(true)
        fileData.setCurrentDirectory(directory)
        fileData.setDisplayedImages(normalized)
        if let focus = referenceGraphFocusPath,
           let index = normalized.firstIndex(where: {
               FileDataModel.normalizePath($0) == FileDataModel.normalizePath(focus)
           }) {
            fileData.setCurrentIndex(index)
            fileData.setCurrentImagePath(normalized[index])
        } else {
            fileData.setCurrentIndex(0)
            fileData.setCurrentImagePath(normalized[0])
        }
        if fileData.currentViewMode != .thumbnail {
            fileData.setViewMode(.thumbnail)
        }
        config.updateSetting("last_directory", value: directory)
        // Note: do not emit `.settingsChanged` here — its subscriber reloads the whole
        // directory, which would discard the specific-files reference level.
        eventBus.emit(.directoryLoaded, payload: .string(directory))
        watchCurrentDirectory()
        selection.clear()
        status.show("Reference graph: \(normalized.count) files")
    }

    /// Python ``open_reference_thumbnail_paths``: one image → browse; several → custom-sort thumbnail level.
    func openReferenceThumbnailPaths(_ paths: [String]) {
        directoryLoader.openReferenceThumbnailPaths(paths)
    }

    func openReferencePaths(_ paths: [String], focusPath: String?) {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count >= 2 else { return }
        directoryLoader.applySpecificFilesLevel(
            paths: normalized,
            focusPath: focusPath,
            saveHistory: true,
            statusMessage: "Showing \(normalized.count) reference images"
        )
    }

    func findReferences(to targetPath: String) {
        let candidates = ReferenceGraphService.findReferencesCandidatePaths(
            appState: self,
            excluding: targetPath
        )
        guard !candidates.isEmpty else {
            status.show("No images are available to search")
            return
        }
        Task { @MainActor in
            let matches = await ReferenceGraphService.imagesReferencing(
                targetPath: targetPath,
                in: candidates
            )
            if matches.isEmpty {
                let name = (targetPath as NSString).lastPathComponent
                status.show("No other images reference \"\(name)\" in EXIF")
                return
            }
            findReferencesTargetPath = targetPath
            findReferencesMatches = matches
            showFindReferencesSheet = true
        }
    }
}
