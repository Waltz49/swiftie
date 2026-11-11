import Foundation

/// Reference thumbnails for job queue cards (port of ``thumbnail_paths_for_values``).
enum JobCardThumbnailPaths {
    static func paths(pluginID: String, values: [String: Any], tempRoot: String? = nil) -> [String] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return [] }
        var paths: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            guard let normalized = existingFilePath(raw) else { return }
            guard !isExcludedWorkPath(normalized, tempRoot: tempRoot) else { return }
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            paths.append(normalized)
        }

        // Job-card clicks open the user's library image, not MFLUX/Pixelmator work files.
        for raw in values["_canonical_source_image_paths"] as? [String] ?? [] {
            append(raw)
        }

        if usesUserLibrarySourceReferences(plugin: plugin) {
            for src in ImageGenExifReferences.resolveSourceImagePaths(values) {
                append(src)
            }
        } else if ImageGenPipelineModeMetadata.jobUsesSourceImage(pipelineID: plugin.pipelineID, values: values) {
            for src in ImageGenExifReferences.resolveSourceImagePaths(values) {
                append(src)
            }
        }

        for src in aiReferenceImagePaths(values: values) {
            append(src)
        }

        if paths.isEmpty, plugin.function == "infill",
           let library = resolveInfillLibraryReference(values: values, tempRoot: tempRoot) {
            append(library)
        }
        return paths
    }

    private static func usesUserLibrarySourceReferences(plugin: ImageGenPluginDescriptor) -> Bool {
        switch plugin.function {
        case "edit", "expand", "infill":
            return true
        default:
            return false
        }
    }

    /// Original photo for infill when only Pixelmator/work paths remain in ``source_image_*``.
    private static func resolveInfillLibraryReference(values: [String: Any], tempRoot: String?) -> String? {
        for raw in values["_canonical_source_image_paths"] as? [String] ?? [] {
            guard let path = existingFilePath(raw), !isExcludedWorkPath(path, tempRoot: tempRoot) else { continue }
            return path
        }
        for raw in ImageGenExifReferences.resolveSourceImagePaths(values) {
            guard let path = existingFilePath(raw), !isExcludedWorkPath(path, tempRoot: tempRoot) else { continue }
            return path
        }
        let doc = (values["pixelmator_doc_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.isEmpty, let path = existingFilePath(doc), !isExcludedWorkPath(path, tempRoot: tempRoot) {
            return path
        }
        return nil
    }

    /// Python ``_valid_preview_paths`` (job card thumbnail clicks).
    static func validPreviewPaths(_ paths: [String]) -> [String] {
        paths.compactMap { existingFilePath($0) }
    }

    /// Trim, require a readable non-directory file, return standardized path (Python ``os.path.isfile``).
    private static func existingFilePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Paths under Prowser temp / Pixelmator work dirs are for workers only, not job-card open-in-browser.
    private static func isExcludedWorkPath(_ path: String, tempRoot: String?) -> Bool {
        if let tempRoot, !tempRoot.isEmpty {
            if ImageGenInfillPathSemantics.isWorkingTempPath(path, tempRoot: tempRoot) {
                return true
            }
        }
        let ap = URL(fileURLWithPath: path).standardizedFileURL.path
        let lower = ap.lowercased()
        if lower.contains("/temp/pixelmator") { return true }
        let parent = (ap as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent.hasPrefix("imagegen-infill-")
    }

    static func referencesInvalid(pluginID: String, values: [String: Any]) -> Bool {
        !missingReferencePaths(pluginID: pluginID, values: values).isEmpty
    }

    static func missingReferencePaths(pluginID: String, values: [String: Any]) -> [String] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return ["(model unavailable)"]
        }
        var missing: [String] = []
        let function = plugin.function

        if function == "edit" {
            let resolved = ImageGenExifReferences.resolveSourceImagePaths(values)
            for raw in resolved where !raw.isEmpty {
                if !FileManager.default.isReadableFile(atPath: raw) {
                    missing.append(raw)
                }
            }
            if !resolved.contains(where: { FileManager.default.isReadableFile(atPath: $0) }) {
                if missing.isEmpty { missing.append("(source image)") }
            }
        } else if function == "expand" {
            let resolved = ImageGenExifReferences.resolveSourceImagePaths(values)
            let canonical = (values["_canonical_source_image_paths"] as? [String] ?? [])
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                .filter { !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0) }
            let hasReadable = resolved.contains { FileManager.default.isReadableFile(atPath: $0) }
                || !canonical.isEmpty
            if !hasReadable {
                let source = (values["source_image_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                missing.append(source.isEmpty ? "(source image)" : source)
            }
        } else if function == "infill" {
            for (key, label) in [("pixelmator_base_path", "infill base image"), ("pixelmator_mask_path", "infill mask")] {
                let path = (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if path.isEmpty || !FileManager.default.isReadableFile(atPath: path) {
                    missing.append(path.isEmpty ? "(\(label))" : path)
                }
            }
        }

        if let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
           let rawPaths = meta["image_paths"] as? [String] {
            for item in rawPaths {
                let path = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, !FileManager.default.isReadableFile(atPath: path) {
                    missing.append(path)
                }
            }
        }
        return missing
    }

    private static func aiReferenceImagePaths(values: [String: Any]) -> [String] {
        guard let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
              let raw = meta["image_paths"] as? [String] else { return [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
