import Foundation

/// Edit-dialog source list helpers (Python ``image_gen_edit_dialog``).
enum ImageGenEditSourcePaths {
    static let maxSourceImages = 4
    static let internalDragType = "com.prowser.imagegen-edit-source-path"

    static func normalizedPaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for path in paths where !path.isEmpty {
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.isReadableFile(atPath: abs) else { continue }
            guard !seen.contains(abs) else { continue }
            seen.insert(abs)
            result.append(abs)
            if result.count >= maxSourceImages { break }
        }
        return result
    }

    static func isSupportedImage(path: String, extensions: [String]) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let normalized = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return normalized.contains(ext)
    }

    static func mergeExternalPaths(
        existing: [String],
        incoming: [String],
        insertIndex: Int? = nil,
        extensions: [String],
        maxTotal: Int = maxSourceImages
    ) -> (paths: [String], warnings: [String]) {
        var warnings: [String] = []
        let existingAbs = normalizedPaths(existing)
        let existingSet = Set(existingAbs)

        var validNew: [String] = []
        var invalidNames: [String] = []
        var duplicateNames: [String] = []

        for path in incoming where !path.isEmpty {
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            let base = URL(fileURLWithPath: abs).lastPathComponent
            guard FileManager.default.isReadableFile(atPath: abs) else { continue }
            guard isSupportedImage(path: abs, extensions: extensions) else {
                invalidNames.append(base)
                continue
            }
            if existingSet.contains(abs) || validNew.contains(abs) {
                duplicateNames.append(base)
                continue
            }
            validNew.append(abs)
        }

        let slots = max(0, maxTotal - existingAbs.count)
        let added = Array(validNew.prefix(slots))
        let skippedCapacity = Array(validNew.dropFirst(slots))

        if added.isEmpty, invalidNames.isEmpty, duplicateNames.isEmpty, skippedCapacity.isEmpty {
            if !incoming.isEmpty {
                warnings.append("No supported image files were dropped.")
            }
            return (existingAbs, warnings)
        }

        if slots == 0, !validNew.isEmpty {
            warnings.append(
                "Already at the maximum of \(maxTotal) source images. Remove an image before adding more."
            )
        }

        var newPaths = existingAbs
        if !added.isEmpty {
            var index = insertIndex ?? newPaths.count
            index = max(0, min(index, newPaths.count))
            for path in added {
                newPaths.insert(path, at: index)
                index += 1
            }
            newPaths = Array(newPaths.prefix(maxTotal))
        }

        let hasProblems = !skippedCapacity.isEmpty || !invalidNames.isEmpty || !duplicateNames.isEmpty
        if !added.isEmpty, hasProblems {
            let noun = added.count == 1 ? "image" : "images"
            warnings.append("Added \(added.count) \(noun).")
        }
        if !skippedCapacity.isEmpty {
            let noun = skippedCapacity.count == 1 ? "image was" : "images were"
            warnings.append("\(skippedCapacity.count) \(noun) not added (maximum is \(maxTotal)).")
        }
        if !invalidNames.isEmpty {
            warnings.append("Skipped unsupported file type: \(joinedNames(invalidNames)).")
        }
        if !duplicateNames.isEmpty {
            warnings.append("Already in the source list: \(joinedNames(duplicateNames)).")
        }

        return (newPaths, warnings)
    }

    /// Preserve sources not in the imported set (Python ``_merge_imported_edit_source_paths``).
    static func mergeImportedPaths(
        existing: [String],
        imported: [String],
        maxTotal: Int = maxSourceImages
    ) -> [String] {
        let importedAbs = normalizedPaths(imported)
        let importedSet = Set(importedAbs)
        var merged = importedAbs
        var mergedSet = Set(merged)
        for path in existing {
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            if importedSet.contains(abs) || mergedSet.contains(abs) { continue }
            guard FileManager.default.isReadableFile(atPath: abs) else { continue }
            if merged.count >= maxTotal { break }
            merged.append(abs)
            mergedSet.insert(abs)
        }
        return Array(merged.prefix(maxTotal))
    }

    static func reorder(paths: [String], moving path: String, to insertIndex: Int) -> [String] {
        var result = paths
        guard let fromIndex = result.firstIndex(of: path) else { return paths }
        var target = insertIndex
        if fromIndex < target { target -= 1 }
        guard target != fromIndex, target >= 0, target <= result.count else { return paths }
        result.remove(at: fromIndex)
        result.insert(path, at: target)
        return result
    }

    /// Browse: current image; thumbnail: selection (up to 4).
    @MainActor
    static func activeImagePathsForEdit(appState: AppState) -> [String] {
        switch appState.fileData.currentViewMode {
        case .browse:
            if let path = appState.fileData.currentImagePath {
                return normalizedPaths([path])
            }
        case .thumbnail:
            let selected = appState.selection.selectedFiles
            if appState.selection.multiSelectMode, !selected.isEmpty {
                var paths: [String] = []
                for path in appState.fileData.displayedImages where selected.contains(path) {
                    paths.append(path)
                    if paths.count >= maxSourceImages { break }
                }
                return normalizedPaths(paths)
            }
            if let path = appState.fileData.currentImagePath {
                return normalizedPaths([path])
            }
        default:
            break
        }
        return []
    }

    private static func joinedNames(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let extra = names.count - 5
        if extra > 0 {
            return "\(shown), and \(extra) more"
        }
        return shown
    }
}
