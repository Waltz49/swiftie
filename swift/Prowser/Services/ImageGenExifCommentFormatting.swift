import Foundation

/// EXIF UserComment layout for MFLUX JSON and Prowser image-gen metadata.
/// Port of `imagegen_plugins/image_gen_naming.py` (display paths only; no generation).
enum ImageGenExifCommentFormatting {
    private static let loraContinuationPrefix = String(repeating: "\u{00a0}", count: 6)

    private static let hfModelDisplayNames: [String: String] = [
        "black-forest-labs/FLUX.1-schnell": "FLUX.1 Schnell",
        "black-forest-labs/FLUX.1-dev": "FLUX.1 Dev",
        "black-forest-labs/FLUX.1-Fill-dev": "FLUX.1 Fill",
        "black-forest-labs/FLUX.2-klein-4B": "FLUX.2 Klein 4B",
        "black-forest-labs/FLUX.2-klein-9B": "FLUX.2 Klein 9B",
        "black-forest-labs/FLUX.2-klein-9b-kv": "FLUX.2 Klein 9B KV",
        "SceneWorks/flux2-klein-9b-kv-mlx": "FLUX.2 Klein 9B KV MLX",
        "SG161222/Realistic_Vision_V4.0_noVAE": "Realistic Vision V4.0",
        "stablediffusionapi/anythingfurry": "Anything Furry",
        "stabilityai/stable-diffusion-xl-base-1.0": "SDXL 1.0 Base",
        "Disty0/Z-Image-Turbo-SDNQ-int8": "Z-Image Turbo",
        "filipstrand/Z-Image-Turbo-mflux-4bit": "Z-Image Turbo",
    ]

    private static let promptSectionSkipHeadings: Set<String> = [
        "prompt", "prompt:", "description", "description:",
    ]

    // MARK: - Parse

    private static let mfluxMetadataKeyHints: Set<String> = [
        "mflux_version", "model", "model_config", "seed", "steps", "quantize",
        "generation_time_seconds", "generation_time", "prompt",
    ]

    /// Strip BOM / EXIF charset prefix and isolate a JSON object when ImageIO returns a raw blob.
    static func normalizedUserCommentTextForParsing(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed = String(trimmed.dropFirst())
        }
        if let data = trimmed.data(using: .utf8), !trimmed.isEmpty {
            let decoded = ExifService.decodeUserComment(data).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty, decoded != trimmed {
                trimmed = decoded
            }
        }
        if trimmed.first != "{", trimmed.first != "[" {
            if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
                trimmed = String(trimmed[start...end])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Port of `parse_mflux_metadata_json`.
    static func parseMfluxMetadataJSON(_ text: String) -> [String: Any]? {
        let trimmed = normalizedUserCommentTextForParsing(text)
        guard !trimmed.isEmpty else { return nil }
        guard let payload = jsonObjectPayload(from: trimmed) else { return nil }
        guard let dict = payload as? [String: Any] else { return nil }
        if dict["mflux_version"] != nil { return dict }
        if dict["prompt"] != nil,
           dict.keys.contains(where: { ["seed", "steps", "model", "quantize"].contains($0) }) {
            return dict
        }
        if dict.keys.contains(where: { mfluxMetadataKeyHints.contains($0) }) {
            return dict
        }
        return nil
    }

    private static func jsonObjectPayload(from trimmed: String) -> Any? {
        guard let data = trimmed.data(using: .utf8) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let nested = json as? String,
               let nestedData = nested.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: nestedData) {
                return inner
            }
            return json
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") , start < end {
            let slice = String(trimmed[start...end])
            if let sliceData = slice.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: sliceData) {
                return json
            }
        }
        return nil
    }

    // MARK: - Display

    /// Port of `format_user_comment_text_for_display`.
    static func formatUserCommentTextForDisplay(_ text: String) -> String {
        let trimmed = normalizedUserCommentTextForParsing(text)
        guard !trimmed.isEmpty else { return text }
        if let meta = parseMfluxMetadataJSON(trimmed) {
            return normalizeExifLoraDisplayLines(formatExifCommentFromMfluxMetadata(meta))
        }
        return normalizeExifLoraDisplayLines(canonicalizeDisplayedZImageTurboModel(trimmed))
    }

    /// Prompt text from MFLUX JSON or formatted/plain comment (port of import / clipboard rules).
    static func extractedPromptText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let meta = parseMfluxMetadataJSON(trimmed),
           let prompt = stringValue(meta["prompt"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return prompt
        }
        return truncateBeforePromptSection(trimmed)
    }

    // MARK: - MFLUX → EXIF body

    /// Port of `format_exif_comment_from_mflux_metadata` (values / pipeline omitted in Swift browser).
    static func formatExifCommentFromMfluxMetadata(_ meta: [String: Any], modelName: String = "") -> String {
        var resolvedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedModel.isEmpty {
            let rawModel = stringValue(meta["model_config"]) ?? stringValue(meta["model"]) ?? ""
            resolvedModel = menuLabelForHFModelId(rawModel)
        }
        let promptText = stringValue(meta["prompt"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let steps = intValue(meta["steps"])
        let quant = intValue(meta["quantize"])
        let guidance = doubleValue(meta["guidance"])
        let seed = intValue(meta["seed"])
        var elapsed = parseElapsedSeconds(meta["generation_time_seconds"])
        if elapsed == nil {
            elapsed = parseElapsedSeconds(meta["generation_time"])
        }
        let lora = loraNameForExifFromPathsAndScales(
            paths: meta["lora_paths"],
            scales: meta["lora_scales"]
        )
        return formatImageExifPrompt(
            modelName: resolvedModel,
            promptText: promptText,
            elapsedSeconds: elapsed,
            seed: seed,
            steps: steps,
            quantization: quant,
            lora: lora,
            guidance: guidance
        )
    }

    /// Port of `format_image_exif_prompt`.
    static func formatImageExifPrompt(
        modelName: String,
        promptText: String,
        elapsedSeconds: Double? = nil,
        seed: Int? = nil,
        steps: Int? = nil,
        quantization: Int? = nil,
        lora: String? = nil,
        guidance: Double? = nil
    ) -> String {
        let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        var paramLines: [String] = []
        if let seed {
            paramLines.append("Seed: \(seed)")
        }
        if let steps {
            paramLines.append("Steps: \(steps)")
        }
        if let quantization {
            paramLines.append("Quantization: \(quantization)")
        }
        paramLines.append(contentsOf: loraParamLinesForExif(lora))
        if let guidance {
            paramLines.append("Guidance: \(formatGuidance(guidance))")
        }

        let name = presentedModelName(modelName)
        if !name.isEmpty {
            var modelBlock = "Image Model:\n\(name)"
            if !paramLines.isEmpty {
                modelBlock += "\n" + paramLines.joined(separator: "\n")
            }
            if let elapsedSeconds {
                modelBlock += "\nElapsed: \(formatElapsedHMS(elapsedSeconds))"
            }
            return "\(modelBlock)\n\nPrompt:\n\(prompt)"
        }

        if !paramLines.isEmpty {
            let header = paramLines.joined(separator: "\n")
            if !prompt.isEmpty {
                return "\(header)\n\nPrompt:\n\(prompt)"
            }
            return header
        }
        return "Prompt:\n\(prompt)"
    }

    // MARK: - Elapsed

    /// Port of `format_elapsed_hms`.
    static func formatElapsedHMS(_ seconds: Double) -> String {
        let total = Int(round(max(0, seconds)))
        let h = total / 3600
        let rem = total % 3600
        let m = rem / 60
        let s = rem % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        }
        return String(s)
    }

    // MARK: - Model / LoRA labels

    /// Any Z-Image Turbo variant, including “(4 bit)” / 4-bit / 8-bit labels, is “Z-Image Turbo”.
    static func presentedModelName(_ modelName: String) -> String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isZImageTurboIdentity(trimmed) {
            return "Z-Image Turbo"
        }
        return trimmed
    }

    static func menuLabelForHFModelId(_ modelId: String) -> String {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.lowercased() != "none" else { return "" }
        if isZImageTurboIdentity(id) {
            return "Z-Image Turbo"
        }
        if let label = hfModelDisplayNames[id] {
            return label
        }
        if let slash = id.lastIndex(of: "/") {
            return presentedModelName(String(id[id.index(after: slash)...]))
        }
        return id
    }

    private static func isZImageTurboIdentity(_ raw: String) -> Bool {
        let folded = raw.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let compact = folded.split { character in
            character.isWhitespace || character == "(" || character == ")" || character == "/" || character == "."
        }.joined(separator: " ")
        return compact.contains("z image turbo")
    }

    /// Rewrite the Image Model line when an older comment still says Z-Image Turbo (4 bit) or similar.
    private static func canonicalizeDisplayedZImageTurboModel(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inModelBlock = false
        var replaced = false
        for index in lines.indices {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            let lower = stripped.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if lower == "image model" {
                inModelBlock = true
                continue
            }
            if lower.hasPrefix("prompt") || lower.hasPrefix("references") {
                inModelBlock = false
            }
            guard inModelBlock, !replaced, !stripped.isEmpty else { continue }
            if stripped.range(
                of: #"^\s*(Seed|Steps|Quantization|Guidance|LoRA|Elapsed)\s*:"#,
                options: .regularExpression
            ) != nil {
                continue
            }
            if stripped.hasPrefix("\u{00a0}") { continue }
            let presented = presentedModelName(stripped)
            if presented != stripped {
                let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
                lines[index] = String(indent) + presented
            }
            replaced = true
        }
        return lines.joined(separator: "\n")
    }

    /// Port of ``lora_name_for_exif_from_values`` (catalog names via Python bridge when needed).
    static func loraNameForExifFromValues(
        values: [String: Any],
        pipelineID: String,
        loraHostID: String?
    ) -> String? {
        guard loraHostID != nil else { return nil }
        let stack = effectiveLoraIDsFromValues(values: values, pipelineID: pipelineID, loraHostID: loraHostID)
        if !stack.isEmpty {
            for (pathsKey, scalesKey) in loraPathScaleKeys {
                if let paths = values[pathsKey] as? [Any], paths.count == stack.count,
                   let label = loraNameForExifFromPathsAndScales(
                       paths: paths,
                       scales: values[scalesKey]
                   ) {
                    return label
                }
            }
            var labels: [String] = []
            for (index, presetID) in stack.enumerated() {
                let scale = loraScaleForExif(values: values, presetID: presetID, index: index)
                labels.append("\(presetID) [\(formatExifLoraWeight(scale))]")
            }
            if labels.count == 1 {
                return labels[0]
            }
            return labels.joined(separator: " + ")
        }
        for (pathsKey, scalesKey) in loraPathScaleKeys {
            if let label = loraNameForExifFromPathsAndScales(
                paths: values[pathsKey],
                scales: values[scalesKey]
            ) {
                return label
            }
        }
        return nil
    }

    private static let loraPathScaleKeys: [(String, String)] = [
        ("mflux_lora_paths", "mflux_lora_scales"),
        ("sdxl_lora_paths", "sdxl_lora_scales"),
        ("sd15_lora_paths", "sd15_lora_scales"),
    ]

    /// Port of ``effective_lora_ids_from_values`` / ``normalize_lora_stack_from_values``.
    static func effectiveLoraIDsFromValues(
        values: [String: Any],
        pipelineID: String,
        loraHostID: String?
    ) -> [String] {
        if loraHostID == "sd15" {
            let legacy = coerceLoraPresetID(values["mflux_lora"])
            return legacy.isEmpty ? [] : [legacy]
        }
        return normalizeLoraStackFromValues(values)
    }

    private static func normalizeLoraStackFromValues(_ values: [String: Any]) -> [String] {
        let stackRaw = values["mflux_lora_stack"]
        let legacy = values["mflux_lora"]
        let explicitStack = values.keys.contains("mflux_lora_stack")

        var ids: [String] = []
        if let stack = stackRaw as? [Any] {
            for item in stack {
                let pid = coerceLoraPresetID(item)
                if !pid.isEmpty, !ids.contains(pid) {
                    ids.append(pid)
                }
            }
        } else if let single = stackRaw as? String {
            let pid = coerceLoraPresetID(single)
            if !pid.isEmpty, !ids.contains(pid) {
                ids.append(pid)
            }
        }

        if explicitStack {
            return ids
        }

        if ids.isEmpty, legacy != nil {
            let pid = coerceLoraPresetID(legacy)
            if !pid.isEmpty {
                ids.append(pid)
            }
        }
        return ids
    }

    private static func coerceLoraPresetID(_ raw: Any?) -> String {
        let text = String(describing: raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.lowercased() == "none" { return "" }
        return text
    }

    /// Port of ``_lora_scale_for_exif`` / ``_lora_scale_for_preset``.
    static func loraScaleForExif(values: [String: Any], presetID: String, index: Int) -> Double {
        for key in ["mflux_lora_scales", "sdxl_lora_scales", "sd15_lora_scales"] {
            if let scales = values[key] as? [Any], index < scales.count {
                if let scale = doubleValue(scales[index]) {
                    return scale
                }
            }
        }
        if let scalesByID = values["mflux_lora_scales_by_id"] as? [String: Any],
           let raw = scalesByID[presetID] {
            return doubleValue(raw) ?? 1.0
        }
        return 1.0
    }

    static func loraNameForExifFromPathsAndScales(paths: Any?, scales: Any?) -> String? {
        guard let pathList = paths as? [Any], !pathList.isEmpty else { return nil }
        let scaleList = scales as? [Any] ?? []
        var labels: [String] = []
        for (index, item) in pathList.enumerated() {
            let path = String(describing: item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let fileName = (path as NSString).lastPathComponent
            let stem = (fileName as NSString).deletingPathExtension
            let name = stem.isEmpty ? fileName : stem
            guard !name.isEmpty else { continue }
            var scale = 1.0
            if index < scaleList.count {
                scale = doubleValue(scaleList[index]) ?? 1.0
            }
            labels.append("\(name) [\(formatExifLoraWeight(scale))]")
        }
        guard !labels.isEmpty else { return nil }
        if labels.count == 1 {
            return labels[0]
        }
        return labels.joined(separator: " + ")
    }

    static func formatExifLoraWeight(_ scale: Double) -> String {
        let formatted = String(format: "%g", scale)
        return formatted
    }

    // MARK: - Private helpers

    private static func truncateBeforePromptSection(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if promptSectionSkipHeadings.contains(line.trimmingCharacters(in: .whitespaces).lowercased()) {
                return lines.dropFirst(index + 1).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private static func parseElapsedSeconds(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        let value: Double?
        if let d = raw as? Double {
            value = d
        } else if let n = raw as? NSNumber {
            value = n.doubleValue
        } else if let s = raw as? String, let d = Double(s) {
            value = d
        } else {
            return nil
        }
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func intValue(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let i = Int(s) { return i }
        if let d = raw as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if raw is NSNull { return nil }
        let s = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.lowercased() == "none" { return nil }
        return s
    }

    private static func formatGuidance(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }

    private static func loraNamesFromExifValue(_ lora: String) -> [String] {
        let text = lora.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let parts = text.components(separatedBy: " + ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private static func formatLoraLinesForExif(names: [String], linePrefix: String = "") -> [String] {
        var lines: [String] = []
        for (index, name) in names.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if index == 0 {
                lines.append("\(linePrefix)LoRA: \(trimmed)")
            } else {
                lines.append("\(linePrefix)\(loraContinuationPrefix)\(trimmed)")
            }
        }
        return lines
    }

    private static func loraParamLinesForExif(_ lora: String?) -> [String] {
        guard let lora, !lora.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return formatLoraLinesForExif(names: loraNamesFromExifValue(lora))
    }

    /// Split a combined EXIF LoRA parameter (`a + b`) into display tokens.
    static func exifLoraNames(from combinedValue: String) -> [String] {
        loraNamesFromExifValue(combinedValue)
    }

    /// Port of `_normalize_exif_lora_display_lines`.
    static func normalizeExifLoraDisplayLines(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var pendingNames: [String] = []
        var pendingPrefix = ""

        func flushPending() {
            guard !pendingNames.isEmpty else { return }
            out.append(contentsOf: formatLoraLinesForExif(names: pendingNames, linePrefix: pendingPrefix))
            pendingNames = []
            pendingPrefix = ""
        }

        let loraLinePattern = try? NSRegularExpression(
            pattern: "^\\s*LoRA\\s*:\\s*(.+?)\\s*$",
            options: [.caseInsensitive]
        )
        let loraContPattern = try? NSRegularExpression(
            pattern: "^\(loraContinuationPrefix)(.+?)\\s*$",
            options: []
        )

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let loraLinePattern,
               let match = loraLinePattern.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let valueRange = Range(match.range(at: 1), in: stripped) {
                let prefix = stripped.isEmpty ? "" : String(line.prefix(line.count - stripped.count))
                let value = String(stripped[valueRange])
                let names = loraNamesFromExifValue(value)
                if names.count > 1 {
                    flushPending()
                    out.append(contentsOf: formatLoraLinesForExif(names: names, linePrefix: prefix))
                    continue
                }
                if !pendingNames.isEmpty, prefix != pendingPrefix {
                    flushPending()
                }
                if pendingNames.isEmpty {
                    pendingPrefix = prefix
                }
                pendingNames.append(names.first ?? value.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            if let loraContPattern,
               let match = loraContPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let nameRange = Range(match.range(at: 1), in: line) {
                let name = String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    pendingNames.append(name)
                }
                continue
            }
            flushPending()
            out.append(line)
        }
        flushPending()
        return out.joined(separator: "\n")
    }
}
