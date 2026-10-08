import Foundation

/// Reference thumbnails for job queue cards (port of ``thumbnail_paths_for_values``).
enum JobCardThumbnailPaths {
    static func paths(pluginID: String, values: [String: Any]) -> [String] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return [] }
        var paths: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let normalized = (raw as NSString).standardizingPath
            guard !normalized.isEmpty else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), !isDir.boolValue else {
                return
            }
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            paths.append(normalized)
        }

        if ImageGenPipelineModeMetadata.jobUsesSourceImage(pipelineID: plugin.pipelineID, values: values) {
            for src in ImageGenExifReferences.resolveSourceImagePaths(values) {
                append(src)
            }
        }
        if plugin.pipelineID == "mflux_fill_infill",
           let px = values["pixelmator_doc_path"] as? String {
            append(px)
        }
        for src in aiReferenceImagePaths(values: values) {
            append(src)
        }
        return paths
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
            let source = (values["source_image_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty || !FileManager.default.isReadableFile(atPath: source) {
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
