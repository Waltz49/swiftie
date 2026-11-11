import AppKit

/// Width-aware prompt clamping for job card display (2-line max, word-boundary elide).
/// Port of `imagegen_plugins/prompt_display_layout.py`.
enum PromptDisplayLayout {
    private static let ellipsis = "…"
    private static let maxCacheEntries = 2048

    /// Mirrors Python `_font_cache_key`; font is part of the key so a different font never
    /// reuses another font's line breaks.
    private struct FontKey: Hashable {
        let name: String
        let size: CGFloat

        init(_ font: NSFont) {
            name = font.fontName
            size = font.pointSize
        }
    }

    private struct LineKey: Hashable {
        let text: String
        let width: Int
        let font: FontKey
    }

    private struct ClampKey: Hashable {
        let text: String
        let width: Int
        let maxLines: Int
        let font: FontKey
    }

    private static var lineStartCache: [LineKey: [Int]] = [:]
    private static var clampCache: [ClampKey: String] = [:]

    static func clampPromptForDisplay(
        _ text: String,
        width: CGFloat,
        font: NSFont = .systemFont(ofSize: JobQueueLayout.fontSize),
        maxLines: Int = JobQueueLayout.promptMaxLines
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 0 else { return trimmed }
        let widthKey = Int(width.rounded())
        let cacheKey = ClampKey(text: trimmed, width: widthKey, maxLines: maxLines, font: FontKey(font))
        if let cached = clampCache[cacheKey] {
            return cached
        }
        let result = clampImpl(trimmed, width: widthKey, font: font, maxLines: maxLines)
        storeClamp(cacheKey, value: result)
        return result
    }

    private static func clampImpl(
        _ text: String,
        width: Int,
        font: NSFont,
        maxLines: Int
    ) -> String {
        if lineCount(text, width: width, font: font) <= maxLines {
            return text
        }
        let starts = lineStartIndices(text, width: width, font: font)
        guard starts.count > maxLines else { return text }
        var cut = starts[maxLines]
        cut = snapToWordBoundary(text, cut: cut)
        while cut > 0 {
            let candidate = text.prefix(cut).trimmingCharacters(in: .whitespaces) + ellipsis
            if lineCount(String(candidate), width: width, font: font) <= maxLines {
                return String(candidate)
            }
            let prevSpace = text[..<text.index(text.startIndex, offsetBy: cut)].lastIndex(of: " ")
            if let prevSpace {
                cut = text.distance(from: text.startIndex, to: prevSpace)
            } else {
                cut -= 1
            }
        }
        return ellipsis
    }

    private static func lineCount(_ text: String, width: Int, font: NSFont) -> Int {
        lineStartIndices(text, width: width, font: font).count
    }

    private static func lineStartIndices(_ text: String, width: Int, font: NSFont) -> [Int] {
        guard !text.isEmpty, width > 0 else { return [] }
        let cacheKey = LineKey(text: text, width: width, font: FontKey(font))
        if let cached = lineStartCache[cacheKey] {
            return cached
        }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat(width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            starts.append(charRange.location)
        }
        storeLineStarts(cacheKey, value: starts)
        return starts
    }

    private static func snapToWordBoundary(_ text: String, cut: Int) -> Int {
        if cut <= 0 { return 0 }
        if cut >= text.count { return text.count }
        let prefix = text.prefix(cut)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return text.distance(from: text.startIndex, to: lastSpace)
        }
        return cut
    }

    private static func storeLineStarts(_ key: LineKey, value: [Int]) {
        if lineStartCache.count >= maxCacheEntries {
            lineStartCache.removeAll(keepingCapacity: true)
        }
        lineStartCache[key] = value
    }

    private static func storeClamp(_ key: ClampKey, value: String) {
        if clampCache.count >= maxCacheEntries {
            clampCache.removeAll(keepingCapacity: true)
        }
        clampCache[key] = value
    }
}

/// Settings → Image Generation: job card hover tooltip prompt source.
enum JobCardHoverPromptMode {
    static let settingsKey = "imagegen_jobcard_hover_prompt"
    static let originalValue = "original"
    static let modifiedValue = "modified"

    case original
    case modified

    @MainActor
    static func from(config: AppConfig) -> JobCardHoverPromptMode {
        let raw = config.string(forKey: settingsKey, default: originalValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == modifiedValue ? .modified : .original
    }
}

/// Resolves full prompt text for job card hover tooltips (original vs exit-modified).
enum JobCardHoverFullPrompt {
    static func original(rowFullPrompt: String, jobValues: [String: Any]?) -> String {
        let fromRow = rowFullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromRow.isEmpty { return fromRow }
        if let jobValues {
            return FluxPromptJobValues.effectiveJobPromptForTooltip(jobValues)
        }
        return ""
    }

    /// Mirrors ``ImageGenController.resolvedActiveWorkerPrompt`` for tests and shared logic.
    static func activeWorkerPrompt(
        workerPrompt: String,
        refinedPrompt: String,
        valuesPrompt: String,
        displayFullPrompt: String
    ) -> String {
        let worker = workerPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !worker.isEmpty { return worker }
        let refined = refinedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refined.isEmpty { return refined }
        let fromValues = valuesPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromValues.isEmpty { return fromValues }
        return displayFullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Shared hover tooltip for job cards and active-job progress bars (model, size, steps, quant, LoRAs, prompt).
enum JobGenerationTooltipText {
    private static let headerFieldSeparator = " "
    private static let quantPrefix = "Q:"
    private static let stepsPrefix = "Steps:"

    static func make(
        plugin: ImageGenPluginDescriptor?,
        values: [String: Any],
        fullPrompt: String,
        displayedPrompt: String? = nil,
        loraLabel: String? = nil,
        loraCatalogLC: [String: Any] = [:]
    ) -> String {
        var lines: [String] = []
        if let plugin {
            let modelID = ImageGenModelDisplay.generationModelID(plugin: plugin, effective: values)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var headerParts: [String] = []
            if !modelID.isEmpty {
                headerParts.append(modelID)
            }
            if let width = intValue(values["width"]),
               let height = intValue(values["height"]),
               width > 0, height > 0 {
                headerParts.append("\(width)x\(height)")
            }
            if let steps = intValue(values["steps"]), steps > 0 {
                headerParts.append("\(stepsPrefix)\(steps)")
            }
            if let quant = ImageGenExifPluginFields.quantizeStatusLabel(plugin: plugin, values: values)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !quant.isEmpty {
                headerParts.append("\(quantPrefix)\(quant)")
            }
            if !headerParts.isEmpty {
                lines.append(headerParts.joined(separator: headerFieldSeparator))
            }
        }
        lines.append(contentsOf: loraTooltipLines(
            values: values,
            pipelineID: plugin?.pipelineID ?? "",
            loraHostID: plugin?.loraHostID,
            loraCatalogLC: loraCatalogLC,
            resolvedLabel: loraLabel
        ))
        let prompt = fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var includePrompt = !prompt.isEmpty
        if includePrompt, let displayedPrompt {
            let shown = normalizePromptForDisplay(displayedPrompt)
            if shown == prompt || shown.isEmpty {
                includePrompt = false
            }
        }
        if includePrompt {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(prompt)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    static func normalizePromptForDisplay(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func loraTooltipLines(
        values: [String: Any],
        pipelineID: String,
        loraHostID: String?,
        loraCatalogLC: [String: Any],
        resolvedLabel: String?
    ) -> [String] {
        if let resolvedLabel {
            let trimmed = resolvedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let parts = trimmed
                    .split(separator: "+", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.map { "• \($0)" }
                }
            }
        }
        guard let loraHostID else { return [] }
        let stack = ImageGenExifCommentFormatting.effectiveLoraIDsFromValues(
            values: values,
            pipelineID: pipelineID,
            loraHostID: loraHostID
        )
        if !stack.isEmpty {
            return stack.enumerated().map { index, presetID in
                let name = LoRACatalog.getEntry(loraID: presetID, lc: loraCatalogLC)?.displayName ?? presetID
                let scale = ImageGenExifCommentFormatting.loraScaleForExif(
                    values: values,
                    presetID: presetID,
                    index: index
                )
                let weight = ImageGenExifCommentFormatting.formatExifLoraWeight(scale)
                return "• \(name) [\(weight)]"
            }
        }
        for (pathsKey, scalesKey) in [
            ("mflux_lora_paths", "mflux_lora_scales"),
            ("sdxl_lora_paths", "sdxl_lora_scales"),
            ("sd15_lora_paths", "sd15_lora_scales"),
        ] {
            if let combined = ImageGenExifCommentFormatting.loraNameForExifFromPathsAndScales(
                paths: values[pathsKey],
                scales: values[scalesKey]
            ) {
                return combined
                    .split(separator: "+", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { "• \($0)" }
            }
        }
        return []
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
