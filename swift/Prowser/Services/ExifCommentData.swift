import Foundation

/// Parsed EXIF UserComment payload (read) or text to write. No import/UI/speech behavior.
struct ExifCommentData {
    enum Kind: Equatable {
        case mflux
        case prowserFormatted
        case plain

        var debugLabel: String {
            switch self {
            case .mflux: return "mflux"
            case .prowserFormatted: return "prowserFormatted"
            case .plain: return "plain"
            }
        }
    }

    struct Reference: Equatable {
        var label: String
        var mtime: Double?
    }

    let rawText: String
    let kind: Kind
    /// MFLUX / worker JSON object when present.
    let mflux: [String: Any]?
    /// Image Model block fields: model, seed, steps, quantization, guidance, lora, …
    let generation: [String: Any]
    /// Prompt body when stored as JSON ``prompt`` or a ``Prompt:`` section (nil if absent).
    let prompt: String?
    /// ``References:`` block entries.
    let references: [Reference]

    var trimmedText: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Read / write

    /// Parsed comment for sidebar, list, progressive EXIF, reference graph, etc.
    static func read(from path: String) -> ExifCommentData? {
        guard let text = ExifService.canonicalCommentText(path: path) else { return nil }
        return ExifCommentData(text: text)
    }

    /// Import prompt/rest only — EXIF UserComment payload (`get_usercomment_from_path`), not other description fields.
    static func readForImageGenImport(from path: String) -> ExifCommentData? {
        guard let text = ExifService.imageGenImportCommentText(path: path) else { return nil }
        return ExifCommentData(text: text)
    }

    @MainActor
    static func write(_ data: ExifCommentData, to path: String) async throws {
        try await ExifService.writeUserComment(path: path, text: data.rawText)
    }

    init(text: String) {
        rawText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMflux = ImageGenExifCommentFormatting.parseMfluxMetadataJSON(trimmed)
        mflux = parsedMflux
        generation = Self.parseGenerationFields(fullComment: text, mfluxMeta: parsedMflux)
        prompt = Self.parsePromptBody(mflux: parsedMflux, rawText: text, trimmed: trimmed)
        references = Self.parseReferences(from: text)
        if parsedMflux != nil {
            kind = .mflux
        } else if Self.hasImageModelSection(trimmed), Self.hasPromptSection(trimmed) {
            kind = .prowserFormatted
        } else {
            kind = .plain
        }
    }

    // MARK: - Section helpers (for consumers that gate on layout)

    static func hasImageModelSection(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower == "image model" || lower == "image model:" {
                return true
            }
        }
        return false
    }

    static func hasPromptSection(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower == "prompt" || lower == "prompt:" {
                return true
            }
        }
        return false
    }

    /// Prompt string when image-gen import rules allow (MFLUX JSON or a ``Prompt:`` section with body).
    static func imageGenImportPrompt(from data: ExifCommentData) -> String? {
        if data.kind == .mflux { return data.prompt }
        guard hasPromptSection(data.trimmedText) else { return nil }
        return data.prompt
    }

    static func bodyAfterPromptHeading(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let skip: Set<String> = ["prompt", "prompt:", "description", "description:"]
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if skip.contains(line.trimmingCharacters(in: .whitespaces).lowercased()) {
                return lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    // MARK: - Debug (Tools → Debug → Show EXIF API structure)

    func debugJSONObject() -> [String: Any] {
        var out: [String: Any] = [
            "kind": kind.debugLabel,
            "rawText": rawText,
            "generation": Self.jsonSanitized(generation),
            "prompt": Self.jsonValue(prompt),
            "references": references.map { ref in
                ["label": ref.label, "mtime": Self.jsonValue(ref.mtime)] as [String: Any]
            },
        ]
        if let mflux {
            out["mflux"] = Self.jsonSanitized(mflux)
        } else {
            out["mflux"] = NSNull()
        }
        return out
    }

    static func debugReport(for path: String) -> [String: Any] {
        [
            "api": "ExifCommentData",
            "imagePath": path,
            "data": read(from: path)?.debugJSONObject() ?? NSNull(),
        ]
    }

    static func debugReportJSONString(for path: String, options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]) -> String {
        let report = debugReport(for: path)
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode EXIF API debug report\"}"
        }
        return text
    }

    private static func parsePromptBody(mflux: [String: Any]?, rawText: String, trimmed: String) -> String? {
        if let mflux {
            let fromJSON = (mflux["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromJSON.isEmpty ? nil : fromJSON
        }
        guard hasPromptSection(trimmed) else { return nil }
        let body = bodyAfterPromptHeading(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func parseReferences(from text: String) -> [Reference] {
        ReferenceGraphService.parseReferenceEntries(from: text).map {
            Reference(label: $0.0, mtime: $0.1)
        }
    }

    private static func jsonSanitized(_ value: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, raw) in value {
            out[key] = jsonValue(raw)
        }
        return out
    }

    private static func jsonValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        switch value {
        case let number as NSNumber: return number
        case let string as String: return string
        case let bool as Bool: return bool
        case let int as Int: return int
        case let double as Double: return double
        case let array as [Any]: return array.map { jsonValue($0) }
        case let dict as [String: Any]: return jsonSanitized(dict)
        default: return String(describing: value)
        }
    }

    // MARK: - Formatted generation parse (port of ``parse_exif_generation_metadata``)

    private static func parseGenerationFields(fullComment: String, mfluxMeta: [String: Any]?) -> [String: Any] {
        var out: [String: Any] = [:]
        let trimmed = fullComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return out }

        if let modelName = parseExifModelName(trimmed, mfluxMeta: mfluxMeta) {
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
                out["lora"] = ImageGenExifCommentFormatting.appendExifLoraImportToken(
                    existing: out["lora"] as? String,
                    name: name
                )
                continue
            }

            if let contName = ImageGenExifCommentFormatting.exifLoraContinuationName(from: String(line)) {
                out["lora"] = ImageGenExifCommentFormatting.appendExifLoraImportToken(
                    existing: out["lora"] as? String,
                    name: contName
                )
            }
        }
        return out
    }

    private static func parseExifModelName(_ fullComment: String, mfluxMeta: [String: Any]?) -> String? {
        if hasImageModelSection(fullComment),
           let block = imageModelNameFromFormattedBlock(fullComment) {
            return ImageGenExifCommentFormatting.presentedModelName(block)
        }
        if let meta = mfluxMeta {
            let hf = (meta["model_config"] as? String) ?? (meta["model"] as? String) ?? ""
            let trimmed = hf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.lowercased() != "none" {
                return ImageGenExifCommentFormatting.presentedModelName(trimmed)
            }
        }
        return imageModelNameFromFormattedBlock(fullComment)
            .map { ImageGenExifCommentFormatting.presentedModelName($0) }
    }

    private static func imageModelNameFromFormattedBlock(_ fullComment: String) -> String? {
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
            if ImageGenExifCommentFormatting.isExifLoraContinuationLine(String(line)) { continue }
            return stripped
        }
        return nil
    }
}
