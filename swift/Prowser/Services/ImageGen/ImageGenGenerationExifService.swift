import Foundation

/// Generation EXIF comment formatting and reference repair (no Python registry).
enum ImageGenGenerationExifService {
    static func formatGenerationExifComment(
        pluginID: String,
        values: [String: Any],
        workerResult: [String: Any],
        elapsedSeconds: Double?,
        lora: String? = nil
    ) -> String {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return (values["prompt"] as? String) ?? ""
        }
        let hf = (values["hf_model_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = hf.contains("/") ? hf : plugin.hfModelID
        let menuFromHF = ImageGenExifCommentFormatting.menuLabelForHFModelId(modelID)
        let modelName = menuFromHF.isEmpty ? plugin.displayName : menuFromHF
        let seed = extractUsedSeed(workerResult: workerResult, values: values)
        let quant: Int? = {
            guard plugin.reportsQuantization else { return nil }
            return intValue(values[plugin.quantizeStatusKey])
        }()
        return ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: modelName.isEmpty ? plugin.displayName : modelName,
            promptText: promptTextForExif(values),
            elapsedSeconds: elapsedSeconds,
            seed: seed,
            steps: intValue(values["steps"]),
            quantization: quant,
            lora: resolvedLoraForExif(plugin: plugin, values: values, override: lora),
            guidance: doubleValue(values["guidance_scale"])
        )
    }

    private static func resolvedLoraForExif(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        override: String?
    ) -> String? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return ImageGenExifCommentFormatting.loraNameForExifFromValues(
            values: values,
            pipelineID: plugin.pipelineID,
            loraHostID: plugin.loraHostID
        )
    }

    @discardableResult
    static func repairCancelledOutputExifReferences(
        pluginID: String,
        outputPath: String,
        values: [String: Any],
        fallbackSourcePaths: [String],
        tempRoot: String
    ) async throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: outputPath),
              let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return false }
        guard let existing = ExifService.userComment(path: outputPath),
              existing.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).hasPrefix("Image Model:") else {
            return false
        }
        let entries = referenceEntries(
            plugin: plugin,
            values: values,
            outputPath: outputPath,
            fallbackSourcePaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
        guard !entries.isEmpty else { return false }
        let comment = ImageGenExifReferences.inject(
            baseComment: existing,
            outputPath: outputPath,
            entries: entries,
            allowCrossDirectory: true,
            tempRoot: tempRoot
        )
        try await ExifService.writeUserComment(path: outputPath, text: comment)
        return true
    }

    @discardableResult
    static func makeReadableUserCommentBeforeBrowse(
        pluginID: String,
        outputPath: String,
        values: [String: Any],
        elapsedSeconds: Double?,
        completedStep: Int,
        totalSteps: Int,
        fallbackSourcePaths: [String],
        tempRoot: String
    ) async throws -> Bool {
        guard completedStep < totalSteps,
              FileManager.default.isReadableFile(atPath: outputPath),
              let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return false }

        let comment = formatGenerationExifComment(
            pluginID: pluginID,
            values: values,
            workerResult: [:],
            elapsedSeconds: elapsedSeconds
        )
        var finalComment = comment
        let entries = referenceEntries(
            plugin: plugin,
            values: values,
            outputPath: outputPath,
            fallbackSourcePaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
        if !entries.isEmpty {
            finalComment = ImageGenExifReferences.inject(
                baseComment: comment,
                outputPath: outputPath,
                entries: entries,
                allowCrossDirectory: true,
                tempRoot: tempRoot
            )
        }
        try await ExifService.writeUserComment(path: outputPath, text: finalComment)
        return true
    }

    static func referenceEntriesForOutput(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        fallbackSourcePaths: [String],
        tempRoot: String
    ) -> [ImageGenExifReferences.Entry] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return [] }
        return referenceEntries(
            plugin: plugin,
            values: values,
            outputPath: outputPath,
            fallbackSourcePaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
    }

    static func injectReferences(
        baseComment: String,
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        fallbackSourcePaths: [String],
        tempRoot: String
    ) -> String {
        let entries = referenceEntriesForOutput(
            pluginID: pluginID,
            values: values,
            outputPath: outputPath,
            fallbackSourcePaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
        guard !entries.isEmpty else { return baseComment }
        return ImageGenExifReferences.inject(
            baseComment: baseComment,
            outputPath: outputPath,
            entries: entries,
            allowCrossDirectory: true,
            tempRoot: tempRoot
        )
    }

    private static func referenceEntries(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        outputPath: String,
        fallbackSourcePaths: [String],
        tempRoot: String
    ) -> [ImageGenExifReferences.Entry] {
        if plugin.pipelineID == "mflux_fill_infill",
           let infillRef = ImageGenExifReferences.resolveInfillReferencePath(
               outputPath: outputPath,
               values: values,
               fallbackSourcePaths: fallbackSourcePaths,
               tempRoot: tempRoot
           ) {
            return ImageGenExifReferences.referenceEntries(
                sourcePaths: [infillRef],
                outputPath: outputPath,
                tempRoot: tempRoot
            )
        }
        let sourcePaths = ImageGenExifReferences.sourcePathsForGenerationExif(
            values: values,
            extraPaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
        return ImageGenExifReferences.referenceEntries(
            sourcePaths: sourcePaths,
            outputPath: outputPath,
            tempRoot: tempRoot
        )
    }

    private static func promptTextForExif(_ values: [String: Any]) -> String {
        (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractUsedSeed(workerResult: [String: Any], values: [String: Any]) -> Int? {
        if let seed = intValue(workerResult["seed"]) { return seed }
        if let seed = intValue(workerResult["used_seed"]) { return seed }
        if values["random_seed"] as? Bool == true { return nil }
        return intValue(values["seed"])
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
