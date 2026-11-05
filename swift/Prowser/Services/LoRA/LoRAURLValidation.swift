import Foundation

enum LoRAURLValidation {
    static func normalizedHTTPURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return nil
        }
        return trimmed
    }

    static func isValidOrEmpty(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return normalizedHTTPURL(trimmed) != nil
    }
}

enum LoRALegacyURLPrefill {
    private static let civitaiModel = try? NSRegularExpression(
        pattern: #"https?://(?:www\.)?(?:civitai\.com|civit\.red)/models/\d+"#,
        options: [.caseInsensitive]
    )

    /// When new fields are empty, infer origin/page from legacy `source_path` http URLs.
    static func suggestions(fromLegacySourcePath sourcePath: String?) -> (safetensorsOrigin: String?, webPageURL: String?) {
        let text = (sourcePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") else {
            return (nil, nil)
        }
        guard LoRAURLValidation.normalizedHTTPURL(text) != nil else { return (nil, nil) }

        if LoRAURLClassification.isDownloadLikeURL(text) {
            return (text, nil)
        }
        if matches(civitaiModel, text) || LoRAURLClassification.isPageLikeURL(text) {
            return (nil, text)
        }
        return (nil, text)
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

enum LoRAURLClassification {
    static func isDownloadLikeURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.contains("/api/download/models/") { return true }
        if lower.contains("/resolve/"), lower.contains(".safetensors") { return true }
        if URL(string: raw)?.path.lowercased().hasSuffix(".safetensors") == true { return true }
        return false
    }

    static func isPageLikeURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.contains("/models/"), !lower.contains("/api/download/") { return true }
        if lower.contains("huggingface.co/") || lower.contains("hf.co/") {
            if lower.contains("/resolve/") || lower.contains("/blob/") { return false }
            return true
        }
        return false
    }

    /// Map Spotlight WhereFroms (ordered) to origin and page URLs.
    static func provenanceSuggestions(from whereFroms: [String]) -> (safetensorsOrigin: String?, webPageURL: String?) {
        let urls = whereFroms.compactMap { LoRAURLValidation.normalizedHTTPURL($0) }
        guard !urls.isEmpty else { return (nil, nil) }

        var origin: String?
        var page: String?
        for url in urls {
            if origin == nil, isDownloadLikeURL(url) {
                origin = url
            } else if page == nil, isPageLikeURL(url) {
                page = url
            }
        }
        if origin == nil, let first = urls.first, isDownloadLikeURL(first) {
            origin = first
        }
        if page == nil, urls.count >= 2 {
            let second = urls[1]
            if !isDownloadLikeURL(second) || isPageLikeURL(second) {
                page = second
            }
        }
        if page == nil {
            for url in urls where url != origin && isPageLikeURL(url) {
                page = url
                break
            }
        }
        return (origin, page)
    }
}
