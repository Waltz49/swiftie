import AppKit
import Foundation

/// EXIF import helpers ported from `image_gen_dialog.py` and `image_gen_naming.py`.
@MainActor
enum ImageGenExifImport {
    static let exifUserCommentExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "webp",
    ]

    struct ImportResult {
        var values: [String: Any]
        var selectedPluginID: String?
        var sourcePaths: [String]?
    }

    static func imagePathForImport(
        function: String,
        sourcePath: String?,
        appState: AppState
    ) -> String? {
        if isBrowseOrThumbnail(appState) {
            guard let path = activeImagePath(appState) else { return nil }
            return exifImportablePath(path)
        }
        if function == "edit" || function == "expand" || function == "infill" {
            guard let sourcePath, FileManager.default.isReadableFile(atPath: sourcePath) else { return nil }
            return exifImportablePath(sourcePath)
        }
        return nil
    }

    @MainActor
    static func importPrompt(
        function: String,
        sourcePath: String?,
        appState: AppState
    ) async -> String? {
        guard let path = imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) else {
            return nil
        }
        return await ExifService.importPromptFromPath(path)
    }

    @MainActor
    static func applyImportRest(
        function: String,
        sourcePath: String?,
        values: [String: Any],
        selectedPluginID: String,
        plugins: [[String: Any]],
        appState: AppState,
        existingSourcePaths: [String] = []
    ) async -> ImportResult? {
        guard let path = imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) else {
            return nil
        }
        guard let comment = await ExifService.userDescription(path: path), !comment.isEmpty else {
            return nil
        }
        let parsed = parseExifGenerationMetadata(comment)
        let gated = gatedExifParams(parsed, plugins: plugins)
        guard !gated.isEmpty else { return nil }
        var updated = values
        var pluginID = selectedPluginID

        if let model = parsed["model"] as? String,
           let resolved = resolvePluginID(forExifModel: model, plugins: plugins) {
            pluginID = resolved
            if let plugin = plugins.first(where: { ($0["plugin_id"] as? String) == resolved }),
               let defaults = plugin["merged_defaults"] as? [String: Any] {
                updated = defaults
                if let prompt = values["prompt"] as? String, !prompt.isEmpty {
                    updated["prompt"] = prompt
                }
                // Size controls stay as the user left them (Python plugin-switch preserve).
                for key in ["width", "height", "use_custom_size", "aspect_ratio_lock"] {
                    if let value = values[key] {
                        updated[key] = value
                    }
                }
            }
        }

        if let seed = gated["seed"] as? Int {
            updated["seed"] = seed
        }
        if let steps = gated["steps"] as? Int {
            updated["steps"] = steps
        }
        if let quantization = gated["quantization"] as? Int {
            updated["mflux_quantize"] = quantization
        }
        if let guidance = gated["guidance"] as? Double {
            updated["guidance_scale"] = guidance
        } else if let guidance = gated["guidance"] as? Int {
            updated["guidance_scale"] = Double(guidance)
        }
        if let lora = gated["lora"] as? String, !lora.isEmpty, appState.workers.lora.isAvailable {
            if let matched = try? await appState.workers.lora.matchExif(
                pluginID: pluginID,
                exifLoraName: lora
            ),
               let ids = matched["ids"] as? [String],
               !ids.isEmpty {
                let host = plugins.first(where: { ($0["plugin_id"] as? String) == pluginID })?["lora_host_id"] as? String ?? ""
                if host == "sd15" {
                    updated["mflux_lora"] = ids[0]
                    updated.removeValue(forKey: "mflux_lora_stack")
                } else {
                    updated["mflux_lora_stack"] = ids
                    updated.removeValue(forKey: "mflux_lora")
                }
                if let scales = matched["scales_by_id"] as? [String: Any], !scales.isEmpty {
                    updated["mflux_lora_scales_by_id"] = scales
                }
            }
        }

        var sourcePaths: [String]?
        if function == "edit", let sourcePath {
            let references = await ReferenceGraphService.validExifReferencePathsForImage(sourcePath)
            sourcePaths = ImageGenEditSourcePaths.mergeImportedPaths(
                existing: existingSourcePaths,
                imported: references
            )
        }

        return ImportResult(values: updated, selectedPluginID: pluginID, sourcePaths: sourcePaths)
    }

    static func showWarning(title: String, message: String) {
        StyledMessageDialog.showWarning(title: title, message: message)
    }

    // MARK: - Private

    private static func isBrowseOrThumbnail(_ appState: AppState) -> Bool {
        switch appState.fileData.currentViewMode {
        case .browse, .thumbnail:
            return true
        default:
            return false
        }
    }

    /// Active image for EXIF import in browse/thumbnail views.
    /// Uses `currentImagePath` as the single source of truth (Python `current_image_path`;
    /// thumbnail selection is cleared on arrow navigation before highlight moves).
    static func activeImagePathForBrowseOrThumbnail(appState: AppState) -> String? {
        switch appState.fileData.currentViewMode {
        case .browse, .thumbnail:
            guard let path = appState.fileData.currentImagePath,
                  FileManager.default.isReadableFile(atPath: path) else { return nil }
            return path
        default:
            return nil
        }
    }

    private static func activeImagePath(_ appState: AppState) -> String? {
        activeImagePathForBrowseOrThumbnail(appState: appState)
    }

    private static func exifImportablePath(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard exifUserCommentExtensions.contains(ext) else { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    private static func normalizeExifModelToken(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func exifModelMatchKeys(plugin: [String: Any]) -> Set<String> {
        var keys = Set<String>()
        for key in ["display_name", "plugin_id", "model_label"] {
            if let raw = plugin[key] as? String {
                let token = normalizeExifModelToken(raw)
                if !token.isEmpty { keys.insert(token) }
            }
        }
        if let hfID = plugin["hf_model_id"] as? String {
            let token = normalizeExifModelToken(hfID)
            if !token.isEmpty {
                keys.insert(token)
                if let last = hfID.split(separator: "/").last {
                    keys.insert(normalizeExifModelToken(String(last)))
                }
            }
        }
        return keys
    }

    private static func resolvePluginID(forExifModel modelText: String, plugins: [[String: Any]]) -> String? {
        let token = normalizeExifModelToken(modelText)
        guard !token.isEmpty else { return nil }
        for plugin in plugins where plugin["available"] as? Bool ?? true {
            if exifModelMatchKeys(plugin: plugin).contains(token) {
                return plugin["plugin_id"] as? String
            }
        }
        return nil
    }

    private static func gatedExifParams(_ params: [String: Any], plugins: [[String: Any]]) -> [String: Any] {
        guard let model = params["model"] as? String, !model.isEmpty else { return [:] }
        var out = params
        let resolved = resolvePluginID(forExifModel: model, plugins: plugins)
        if out["lora"] == nil {
            out["lora"] = "none"
        } else if resolved == nil {
            out.removeValue(forKey: "lora")
        }
        out.removeValue(forKey: "model")
        return out
    }

    private static func parseExifGenerationMetadata(_ fullComment: String) -> [String: Any] {
        var out: [String: Any] = [:]
        let trimmed = fullComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return out }

        if let modelName = parseExifModelName(trimmed) {
            out["model"] = ImageGenExifCommentFormatting.presentedModelName(modelName)
        }

        var inModelBlock = false
        let intPattern = try? NSRegularExpression(
            pattern: #"^\s*(Seed|Steps|Quantization)\s*:\s*(\d+)\s*$"#,
            options: [.caseInsensitive]
        )
        let guidancePattern = try? NSRegularExpression(
            pattern: #"^\s*Guidance\s*:\s*([\d.]+)\s*$"#,
            options: [.caseInsensitive]
        )
        let loraPattern = try? NSRegularExpression(
            pattern: #"^\s*LoRA\s*:\s*(.+?)\s*$"#,
            options: [.caseInsensitive]
        )
        let stepsSuffixPattern = try? NSRegularExpression(pattern: #"\[(\d+)\]\s*$"#)

        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let lower = stripped.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if lower == "image model" {
                inModelBlock = true
                continue
            }
            if lower.hasPrefix("prompt") || lower.hasPrefix("references") {
                inModelBlock = false
            }

            if inModelBlock, out["steps"] == nil,
               let match = stepsSuffixPattern?.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let range = Range(match.range(at: 1), in: stripped),
               let steps = Int(stripped[range]) {
                out["steps"] = steps
            }

            if let match = intPattern?.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let labelRange = Range(match.range(at: 1), in: stripped),
               let valueRange = Range(match.range(at: 2), in: stripped),
               let value = Int(stripped[valueRange]) {
                let label = stripped[labelRange].lowercased()
                if label == "quantization" {
                    out["quantization"] = value
                } else {
                    out[label] = value
                }
                continue
            }

            if let match = guidancePattern?.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let valueRange = Range(match.range(at: 1), in: stripped),
               let guidance = Double(stripped[valueRange]) {
                out["guidance"] = guidance
                continue
            }

            if let match = loraPattern?.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let valueRange = Range(match.range(at: 1), in: stripped) {
                let name = String(stripped[valueRange]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if let prev = out["lora"] as? String, !prev.isEmpty {
                    out["lora"] = "\(prev) + \(name)"
                } else {
                    out["lora"] = name
                }
            }
        }
        return out
    }

    private static func parseExifModelName(_ fullComment: String) -> String? {
        if let meta = ImageGenExifCommentFormatting.parseMfluxMetadataJSON(fullComment) {
            let raw = (meta["model_config"] as? String) ?? (meta["model"] as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.lowercased() != "none" {
                return ImageGenExifCommentFormatting.presentedModelName(trimmed)
            }
        }
        var inModelBlock = false
        for line in fullComment.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let lower = stripped.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if lower == "image model" {
                inModelBlock = true
                continue
            }
            if lower.hasPrefix("prompt") || lower.hasPrefix("references") {
                inModelBlock = false
            }
            guard inModelBlock else { continue }
            if stripped.range(of: #"^\s*(Seed|Steps|Quantization|Guidance|LoRA|Elapsed)\s*:"#, options: .regularExpression) != nil {
                continue
            }
            if stripped.hasPrefix("\u{00a0}") { continue }
            return ImageGenExifCommentFormatting.presentedModelName(stripped)
        }
        return nil
    }
}
