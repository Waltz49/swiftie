import AppKit
import Foundation
import ImageIO

/// EXIF import helpers ported from `image_gen_dialog.py` and `image_gen_naming.py`.
@MainActor
enum ImageGenExifImport {
    static let exifUserCommentExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "webp",
    ]

    /// Tooltip slot size; preview pixels are inset so the thumb does not cover the tooltip border.
    static let importTooltipImageSide: CGFloat = 96
    private static let importTooltipImageContentInset: CGFloat = 4
    static let importTooltipNoDataLine = "** No data in file to import **"

    struct ImportResult {
        var values: [String: Any]
        var selectedPluginID: String?
        var sourcePaths: [String]?
    }

    enum ImportTooltipKind {
        case prompt
        case rest
    }

    static func importTooltipText(base: String, hasImportableData: Bool) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasImportableData else { return trimmed }
        guard !trimmed.isEmpty else { return importTooltipNoDataLine }
        return trimmed + "\n\n" + importTooltipNoDataLine
    }

    static func importFromFileDataAvailable(
        kind: ImportTooltipKind,
        function: String,
        sourcePath: String?,
        appState: AppState,
        plugins: [[String: Any]]
    ) -> Bool {
        guard let path = imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) else {
            return false
        }
        guard let data = ExifCommentData.readForImageGenImport(from: path) else { return false }
        switch kind {
        case .prompt:
            return ExifCommentData.imageGenImportPrompt(from: data) != nil
        case .rest:
            let gated = gatedExifParams(data.generation, plugins: plugins)
            return !gated.isEmpty
        }
    }

    static func importButtonTooltip(
        base: String,
        kind: ImportTooltipKind,
        function: String,
        sourcePath: String?,
        appState: AppState,
        plugins: [[String: Any]]
    ) -> String {
        importTooltipText(
            base: base,
            hasImportableData: importFromFileDataAvailable(
                kind: kind,
                function: function,
                sourcePath: sourcePath,
                appState: appState,
                plugins: plugins
            )
        )
    }

    /// EXIF-oriented thumb for unified-dialog Import Prompt / Import Rest graphic tooltips.
    static func importTooltipImage(
        function: String,
        sourcePath: String?,
        appState: AppState
    ) -> NSImage? {
        guard let path = imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) else {
            return nil
        }
        return loadSquareTooltipImage(path: path, side: importTooltipImageSide)
    }

    /// Pixel-dimension source thumb for custom-size and resize **Import** graphic tooltips.
    static func importSizeTooltipImage(
        function: String,
        sourcePath: String?,
        appState: AppState
    ) -> NSImage? {
        guard let path = imagePathForImportSize(
            function: function,
            sourcePath: sourcePath,
            appState: appState,
            presentWarning: false
        ) else {
            return nil
        }
        return importSizeTooltipImage(forReadablePath: path)
    }

    static func importSizeTooltipImage(forReadablePath path: String) -> NSImage? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return loadSquareTooltipImage(path: path, side: importTooltipImageSide)
    }

    static func importSizeButtonTooltip(
        base: String,
        function: String,
        sourcePath: String?,
        appState: AppState
    ) -> String {
        let hasSource = imagePathForImportSize(
            function: function,
            sourcePath: sourcePath,
            appState: appState,
            presentWarning: false
        ) != nil
        return importTooltipText(base: base, hasImportableData: hasSource)
    }

    static func importSizeButtonTooltip(base: String, sourcePath: String?) -> String {
        let hasSource = sourcePath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
        return importTooltipText(base: base, hasImportableData: hasSource)
    }

    static func imagePathForImport(
        function: String,
        sourcePath: String?,
        appState: AppState
    ) -> String? {
        switch function {
        case "edit", "expand", "infill":
            // Python edit/expand/infill panels: EXIF import from dialog ``source_path`` (canvas),
            // not the browse-list active image.
            guard let sourcePath, FileManager.default.isReadableFile(atPath: sourcePath) else { return nil }
            return exifImportablePath(sourcePath)
        default:
            guard isBrowseOrThumbnail(appState) else { return nil }
            guard let path = activeImagePath(appState) else { return nil }
            return exifImportablePath(path)
        }
    }

    /// Image path for custom-size **Import** (pixel dimensions). Port of ``_image_path_for_import_size``.
    static func imagePathForImportSize(
        function: String,
        sourcePath: String?,
        appState: AppState,
        presentWarning: Bool = true
    ) -> String? {
        switch function {
        case "edit", "expand", "infill":
            guard let sourcePath, FileManager.default.isReadableFile(atPath: sourcePath) else {
                if presentWarning {
                    Self.showWarning(title: "Import Size", message: "No image selected.")
                }
                return nil
            }
            return sourcePath
        default:
            guard isBrowseOrThumbnail(appState) else {
                if presentWarning {
                    Self.showWarning(
                        title: "Import Size",
                        message: "Select an image in browse view, or select a single thumbnail, "
                            + "before importing."
                    )
                }
                return nil
            }
            guard let path = activeImagePathForBrowseOrThumbnail(appState: appState) else {
                if presentWarning {
                    Self.showWarning(title: "Import Size", message: "No image selected.")
                }
                return nil
            }
            return path
        }
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
        guard let data = ExifCommentData.readForImageGenImport(from: path) else {
            return nil
        }
        let parsed = data.generation
        let gated = gatedExifParams(parsed, plugins: plugins)
        guard !gated.isEmpty else { return nil }
        var updated = values
        var pluginID = selectedPluginID

        let hfFromMeta = mfluxHFModelID(from: data)
        if let model = parsed["model"] as? String,
           let resolved = resolvePluginID(
               forExifModel: model,
               hfModelID: hfFromMeta,
               exifParams: parsed,
               plugins: plugins
           ) {
            pluginID = resolved
            if let plugin = plugins.first(where: { ($0["plugin_id"] as? String) == resolved }),
               let defaults = plugin["merged_defaults"] as? [String: Any] {
                updated = defaults
                updated = mergingPluginDefaults(defaults, preserving: values)
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

    /// Apply plugin ``merged_defaults`` while keeping dialog-owned fields (Python never resets copies on Import Rest).
    static func mergingPluginDefaults(_ defaults: [String: Any], preserving values: [String: Any]) -> [String: Any] {
        var updated = defaults
        if let prompt = values["prompt"] as? String, !prompt.isEmpty {
            updated["prompt"] = prompt
        }
        for key in ["width", "height", "use_custom_size", "aspect_ratio_lock", "copies"] {
            if let value = values[key] {
                updated[key] = value
            }
        }
        return updated
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

    private static func loadSquareTooltipImage(path: String, side: CGFloat) -> NSImage? {
        let maxPixel = max(1, Int(side.rounded()))
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary) else {
            return scaledSquareTooltipImage(ImageDisplayLoader.orientedImage(for: path, maxPixelSize: maxPixel), side: side)
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return scaledSquareTooltipImage(ImageDisplayLoader.orientedImage(for: path, maxPixelSize: maxPixel), side: side)
        }
        let display = ThumbnailTransparencyCompositor.compositeOntoCheckerboardIfNeeded(cgImage)
        let image = NSImage(size: NSSize(width: display.width, height: display.height))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(display, in: NSRect(origin: .zero, size: image.size))
        image.unlockFocus()
        return scaledSquareTooltipImage(image, side: side)
    }

    private static func scaledSquareTooltipImage(_ image: NSImage?, side: CGFloat) -> NSImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let square = NSSize(width: side, height: side)
        let inset = importTooltipImageContentInset
        let contentSide = max(1, side - 2 * inset)
        let scale = min(contentSide / image.size.width, contentSide / image.size.height, 1)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawOrigin = NSPoint(
            x: inset + (contentSide - drawSize.width) / 2,
            y: inset + (contentSide - drawSize.height) / 2
        )
        let preview = NSImage(size: square)
        preview.lockFocus()
        ImageDisplayLoader.draw(image, in: NSRect(origin: drawOrigin, size: drawSize))
        preview.unlockFocus()
        return preview
    }

    /// Lowercase match token; align ``FLUX 2`` (generation EXIF) with ``FLUX.2`` (HF menu labels).
    private static func normalizeExifModelToken(_ text: String) -> String {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        token = token.replacingOccurrences(of: "flux.2", with: "flux 2")
        token = token.replacingOccurrences(of: "flux.1", with: "flux 1")
        return token
    }

    private static func exifModelMatchKeys(plugin: [String: Any]) -> Set<String> {
        var keys = Set<String>()
        func insertToken(_ raw: String) {
            let token = normalizeExifModelToken(raw)
            if !token.isEmpty { keys.insert(token) }
        }
        for key in ["display_name", "plugin_id", "model_label"] {
            if let raw = plugin[key] as? String {
                insertToken(raw)
            }
        }
        if let hfID = plugin["hf_model_id"] as? String {
            insertToken(hfID)
            if let last = hfID.split(separator: "/").last {
                insertToken(String(last))
            }
            insertToken(ImageGenExifCommentFormatting.menuLabelForHFModelId(hfID))
            let pipelineID = plugin["pipeline_id"] as? String ?? ""
            if !pipelineID.isEmpty {
                insertToken(ImageGenModelDisplay.modelDisplayName(pipelineID: pipelineID, hfModelID: hfID))
            }
        }
        return keys
    }

    static func resolvePluginID(
        forExifModel modelText: String,
        hfModelID: String? = nil,
        exifParams: [String: Any] = [:],
        plugins: [[String: Any]]
    ) -> String? {
        let token = normalizeExifModelToken(modelText)
        guard !token.isEmpty else { return nil }
        if let zImage = resolveZImagePluginID(
            forExifModel: modelText,
            hfModelID: hfModelID,
            exifParams: exifParams,
            token: token,
            plugins: plugins
        ) {
            return zImage
        }
        for plugin in plugins where plugin["available"] as? Bool ?? true {
            if exifModelMatchKeys(plugin: plugin).contains(token) {
                return plugin["plugin_id"] as? String
            }
        }
        return nil
    }

    private static func resolveZImagePluginID(
        forExifModel modelText: String,
        hfModelID: String?,
        exifParams: [String: Any],
        token: String,
        plugins: [[String: Any]]
    ) -> String? {
        let pluginAvailable = { (id: String) -> Bool in
            plugins.contains { row in
                (row["plugin_id"] as? String) == id && (row["available"] as? Bool ?? true)
            }
        }
        if token.contains("z_image_turbo_sdnq") || token.contains("sdnq_int8") {
            return pluginAvailable("z_image_turbo_mflux_4bit") ? "z_image_turbo_mflux_4bit" : nil
        }
        if let hf = hfModelID?.trimmingCharacters(in: .whitespacesAndNewlines), !hf.isEmpty {
            if ImageGenExifCommentFormatting.isZImageTurbo4BitIdentity(hf) {
                return pluginAvailable("z_image_turbo_mflux_4bit") ? "z_image_turbo_mflux_4bit" : nil
            }
            if ImageGenExifCommentFormatting.isZImageTurboIdentity(hf) {
                return pluginAvailable("z_image_turbo_mflux") ? "z_image_turbo_mflux" : nil
            }
        }
        if ImageGenExifCommentFormatting.isZImageTurbo4BitIdentity(modelText) {
            return pluginAvailable("z_image_turbo_mflux_4bit") ? "z_image_turbo_mflux_4bit" : nil
        }
        if ImageGenExifCommentFormatting.isZImageTurboIdentity(modelText) {
            if exifParams["quantization"] == nil, exifParams["guidance"] != nil,
               pluginAvailable("z_image_turbo_mflux_4bit") {
                return "z_image_turbo_mflux_4bit"
            }
            return pluginAvailable("z_image_turbo_mflux") ? "z_image_turbo_mflux" : nil
        }
        return nil
    }

    private static func mfluxHFModelID(from data: ExifCommentData) -> String? {
        guard let meta = data.mflux else { return nil }
        let raw = (meta["model_config"] as? String) ?? (meta["model"] as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
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
}
