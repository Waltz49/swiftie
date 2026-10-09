import Foundation

/// Reorder displayed thumbnails and persist `.prsort`. Port of `thumbnail_canvas.handle_thumbnail_reorder`.
@MainActor
enum ThumbnailReorderService {
    static func reorder(
        imagePath: String,
        insertionIndex: Int,
        appState: AppState
    ) async -> Bool {
        if PrsortIO.isFileLocked(imagePath) {
            appState.status.show("Cannot reorder locked files")
            return false
        }

        var images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        guard let currentIndex = images.firstIndex(of: imagePath) else { return false }

        var targetIndex = insertionIndex
        if currentIndex < targetIndex {
            targetIndex -= 1
        }
        guard targetIndex != currentIndex, targetIndex >= 0, targetIndex <= images.count else {
            return false
        }

        let selectedBefore = appState.selection.selectedFiles
        let directory = (imagePath as NSString).deletingLastPathComponent

        let sortMode = appState.config.rawSettings()["sort_mode"] as? String ?? "date"
        let autoDateChange = appState.config.bool(forKey: "drag_drop_auto_date_change", default: false)
        let isLocked = PrsortIO.isFileLocked(imagePath)
        let shouldUpdateDates = sortMode == "date" && autoDateChange && !isLocked
        let switchingToCustom = sortMode != SortMode.custom.rawValue && !shouldUpdateDates

        images.remove(at: currentIndex)
        images.insert(imagePath, at: targetIndex)

        var datesWereUpdated = false
        if shouldUpdateDates {
            let isReversed = appState.config.bool(forKey: "sort_reversed", default: false)
            guard updateMtimeForReorder(
                imagePath: imagePath,
                images: images,
                insertionIndex: targetIndex,
                isReversed: isReversed,
                appState: appState
            ) else {
                return false
            }
            datesWereUpdated = true
        }

        appState.beginSuppressDirectoryRefresh()
        defer { appState.endSuppressDirectoryRefresh() }

        let filenames = images.map { ($0 as NSString).lastPathComponent }
        let isReversed = PrsortIO.readCustomSort(in: directory)?.isReversed
            ?? (appState.config.rawSettings()["sort_reversed"] as? Bool ?? false)
        let locked = PrsortIO.lockedFilenames(in: directory)
        let prsortDirectory = directory
        let prsortFilenames = filenames
        let prsortReversed = isReversed
        let prsortLocked = locked
        do {
            try await Task.detached(priority: .utility) {
                try PrsortIO.writeCustomSort(
                    in: prsortDirectory,
                    filenames: prsortFilenames,
                    isReversed: prsortReversed,
                    locked: prsortLocked
                )
            }.value
        } catch {
            appState.status.show("Failed to save custom sort: \(error.localizedDescription)")
            return false
        }
        if switchingToCustom {
            appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        }

        appState.fileData.setDisplayedImages(images)
        appState.selection.selectedFiles = selectedBefore
        if let index = images.firstIndex(of: imagePath) {
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(imagePath)
            appState.selection.emitSelectionChanged(highlightIndex: index)
        }

        if datesWereUpdated {
            appState.status.show("Thumbnail reordered (dates updated)")
        } else if switchingToCustom {
            appState.status.show("Thumbnail reordered (switched to custom sort)")
        } else {
            appState.status.show("Thumbnail reordered")
        }
        return true
    }

    static func insertionIndex(at point: CGPoint, metrics: ThumbnailLayout.GridMetrics, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }

        for index in 0..<itemCount {
            let cell = ThumbnailLayout.frame(for: index, metrics: metrics)
            let centerX = cell.midX

            if point.y < cell.minY {
                return index
            }
            if cell.minY <= point.y, point.y <= cell.maxY, point.x < centerX {
                return index
            }
        }

        return itemCount
    }

    private static func updateMtimeForReorder(
        imagePath: String,
        images: [String],
        insertionIndex: Int,
        isReversed: Bool,
        appState: AppState
    ) -> Bool {
        let fileDir = (imagePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: fileDir) else {
            appState.status.show("Unable to reorder: directory is not writable")
            return false
        }

        var prevTime: TimeInterval?
        var nextTime: TimeInterval?

        if insertionIndex > 0 {
            let prevPath = images[insertionIndex - 1]
            if prevPath != imagePath {
                prevTime = mtime(for: prevPath)
            }
        }
        if insertionIndex + 1 < images.count {
            let nextPath = images[insertionIndex + 1]
            if nextPath != imagePath {
                nextTime = mtime(for: nextPath)
            }
        }

        let newTime: TimeInterval
        if prevTime == nil && nextTime == nil {
            newTime = Date().timeIntervalSince1970
        } else if prevTime == nil {
            newTime = Date().timeIntervalSince1970
        } else if let prevTime, nextTime == nil {
            newTime = isReversed ? prevTime + 1 : prevTime - 1
        } else if let prevTime, let nextTime {
            if isReversed {
                let gap = nextTime - prevTime
                newTime = gap >= 2 ? prevTime + gap / 2 : prevTime + 0.5
            } else {
                let gap = prevTime - nextTime
                newTime = gap >= 2 ? prevTime - gap / 2 : prevTime - 0.5
            }
        } else {
            newTime = Date().timeIntervalSince1970
        }

        guard testAndSetMtime(path: imagePath, newTime: newTime, appState: appState) else {
            appState.status.show("Unable to reorder: permission to change file dates denied")
            return false
        }

        var last = newTime
        for index in (insertionIndex + 1)..<images.count {
            let path = images[index]
            guard let current = mtime(for: path) else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: dir) else { continue }

            var adjusted = current
            var needsShift = false
            if isReversed {
                if current <= last {
                    adjusted = last + 1
                    needsShift = true
                }
            } else if current >= last {
                adjusted = last - 1
                needsShift = true
            }

            if needsShift {
                if setMtime(path: path, time: adjusted, appState: appState) {
                    last = adjusted
                } else if let actual = mtime(for: path) {
                    last = actual
                }
            } else {
                // List was date-sorted before reorder; trailing files already satisfy order.
                break
            }
        }

        return true
    }

    private static func mtime(for path: String) -> TimeInterval? {
        guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private static func testAndSetMtime(path: String, newTime: TimeInterval, appState: AppState) -> Bool {
        guard let original = mtime(for: path) else { return false }
        let newDate = Date(timeIntervalSince1970: newTime)
        do {
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: path)
            let verified = abs((mtime(for: path) ?? 0) - newTime) < 2
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: original)],
                ofItemAtPath: path
            )
            guard verified else { return false }
            return setMtime(path: path, time: newTime, appState: appState)
        } catch {
            return false
        }
    }

    private static func setMtime(path: String, time: TimeInterval, appState: AppState) -> Bool {
        let date = Date(timeIntervalSince1970: time)
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: date, .creationDate: date],
                ofItemAtPath: path
            )
            guard abs((mtime(for: path) ?? 0) - time) < 1 else { return false }
            appState.metadataCache.invalidate(path: path)
            return true
        } catch {
            return false
        }
    }
}
