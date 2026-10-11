import Foundation

/// Reorder displayed thumbnails and persist `.prsort`. Port of `thumbnail_canvas.handle_thumbnail_reorder`.
@MainActor
enum ThumbnailReorderService {
    static func reorder(
        imagePath: String,
        insertionIndex: Int,
        appState: AppState
    ) async -> Bool {
        await reorderMultiple(imagePaths: [imagePath], insertionIndex: insertionIndex, appState: appState)
    }

    /// Port of `thumbnail_canvas.handle_multiple_thumbnail_reorder`.
    static func reorderMultiple(
        imagePaths: [String],
        insertionIndex: Int,
        appState: AppState
    ) async -> Bool {
        guard !imagePaths.isEmpty else { return false }

        for path in imagePaths {
            if PrsortIO.isFileLocked(path) {
                appState.status.show("Cannot reorder locked files")
                return false
            }
        }

        var images = appState.fileData.displayedImages
        guard !images.isEmpty else { return false }

        var validPaths: [String] = []
        var originalIndices: [Int] = []
        for path in imagePaths {
            guard let idx = images.firstIndex(of: path) else { continue }
            validPaths.append(path)
            originalIndices.append(idx)
        }
        guard !validPaths.isEmpty else { return false }

        let sortedIndices = originalIndices.sorted(by: >)
        var adjustedInsertion = insertionIndex
        for idx in sortedIndices where idx < adjustedInsertion {
            adjustedInsertion -= 1
        }

        guard adjustedInsertion >= 0, adjustedInsertion <= images.count else { return false }

        var reordered = images
        for idx in sortedIndices {
            reordered.remove(at: idx)
        }
        for (offset, path) in validPaths.enumerated() {
            let insertPos = adjustedInsertion + offset
            guard insertPos <= reordered.count else { return false }
            reordered.insert(path, at: insertPos)
        }
        guard reordered != images else { return false }

        let selectedBefore = appState.selection.selectedFiles
        let directory = (validPaths[0] as NSString).deletingLastPathComponent

        let sortMode = appState.config.rawSettings()["sort_mode"] as? String ?? "date"
        let autoDateChange = appState.config.bool(forKey: "drag_drop_auto_date_change", default: false)
        let shouldUpdateDates = sortMode == "date" && autoDateChange
        let switchingToCustom = sortMode != SortMode.custom.rawValue && !shouldUpdateDates

        images = reordered

        var datesWereUpdated = false
        if shouldUpdateDates {
            let isReversed = appState.config.bool(forKey: "sort_reversed", default: false)
            guard updateMtimesForMultipleReorder(
                movedPaths: validPaths,
                images: images,
                insertionIndex: adjustedInsertion,
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

        let currentPath = validPaths.last ?? validPaths[0]
        if let index = images.firstIndex(of: currentPath) {
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(currentPath)
            appState.selection.emitSelectionChanged(highlightIndex: index)
        }

        let count = validPaths.count
        if datesWereUpdated {
            if count == 1 {
                appState.status.show("Thumbnail reordered (dates updated)")
            } else {
                appState.status.show("\(count) thumbnails reordered (dates updated)")
            }
        } else if switchingToCustom {
            if count == 1 {
                appState.status.show("Thumbnail reordered (switched to custom sort)")
            } else {
                appState.status.show("\(count) thumbnails reordered (switched to custom sort)")
            }
        } else if count == 1 {
            appState.status.show("Thumbnail reordered")
        } else {
            appState.status.show("\(count) thumbnails reordered")
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

    private static func updateMtimesForMultipleReorder(
        movedPaths: [String],
        images: [String],
        insertionIndex: Int,
        isReversed: Bool,
        appState: AppState
    ) -> Bool {
        let directories = Set(movedPaths.map { ($0 as NSString).deletingLastPathComponent })
        for dir in directories where !FileManager.default.isWritableFile(atPath: dir) {
            appState.status.show("Unable to reorder: directory is not writable")
            return false
        }

        var prevTime: TimeInterval?
        var nextTime: TimeInterval?
        if insertionIndex > 0 {
            prevTime = mtime(for: images[insertionIndex - 1])
        }
        let afterBlock = insertionIndex + movedPaths.count
        if afterBlock < images.count {
            nextTime = mtime(for: images[afterBlock])
        }

        let count = movedPaths.count
        let baseTime: TimeInterval
        let timeSpacing: TimeInterval

        if prevTime == nil && nextTime == nil {
            baseTime = Date().timeIntervalSince1970
            timeSpacing = 1
        } else if prevTime == nil {
            baseTime = Date().timeIntervalSince1970
            timeSpacing = 1
        } else if let prevTime, nextTime == nil {
            if isReversed {
                baseTime = prevTime + 1
            } else {
                baseTime = prevTime - Double(count) - 1
            }
            timeSpacing = 1
        } else if let prevTime, let nextTime {
            if isReversed {
                let gap = nextTime - prevTime
                if gap >= Double(count) + 2 {
                    timeSpacing = gap / Double(count + 1)
                    baseTime = prevTime + timeSpacing
                } else {
                    baseTime = prevTime + 1
                    timeSpacing = 1
                }
            } else {
                let gap = prevTime - nextTime
                if gap >= Double(count) + 2 {
                    timeSpacing = gap / Double(count + 1)
                    baseTime = prevTime - timeSpacing
                } else {
                    baseTime = prevTime - Double(count) - 1
                    timeSpacing = 1
                }
            }
        } else {
            baseTime = Date().timeIntervalSince1970
            timeSpacing = 1
        }

        var lastAssigned = baseTime
        for (offset, path) in movedPaths.enumerated() {
            let newTime = isReversed
                ? baseTime + Double(offset) * timeSpacing
                : baseTime - Double(offset) * timeSpacing
            guard testAndSetMtime(path: path, newTime: newTime, appState: appState) else {
                appState.status.show("Unable to reorder: permission to change file dates denied")
                return false
            }
            lastAssigned = newTime
        }

        for index in (insertionIndex + movedPaths.count)..<images.count {
            let path = images[index]
            guard let current = mtime(for: path) else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: dir) else { continue }

            var adjusted = current
            var needsShift = false
            if isReversed {
                if current <= lastAssigned {
                    adjusted = lastAssigned + 1
                    needsShift = true
                }
            } else if current >= lastAssigned {
                adjusted = lastAssigned - 1
                needsShift = true
            }

            if needsShift {
                if setMtime(path: path, time: adjusted, appState: appState) {
                    lastAssigned = adjusted
                } else if let actual = mtime(for: path) {
                    lastAssigned = actual
                }
            } else {
                break
            }
        }

        return true
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
