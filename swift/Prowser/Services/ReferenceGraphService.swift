import Foundation

/// EXIF reference parsing for Find References. Port of `search/reference_graph.py` (subset).
enum ReferenceGraphService {
    private static let sectionStop = try? NSRegularExpression(
        pattern: "^(?:prompt|image model|title|description):$",
        options: [.caseInsensitive]
    )
    private static let fileDateLine = try? NSRegularExpression(pattern: "^\\d+(?:\\.\\d+)?$")
    private static let imageExtensions = [".png", ".jpg", ".webp", ".jpeg"]

    static func imagesReferencing(targetPath: String, in candidates: [String]) -> [String] {
        let targetNorm = normalizePath(targetPath)
        return candidates.filter { candidate in
            normalizePath(candidate) != targetNorm && pathIsReferencedInExif(candidatePath: candidate, targetPath: targetPath)
        }
    }

    static func pathIsReferencedInExif(candidatePath: String, targetPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: candidatePath),
              FileManager.default.fileExists(atPath: targetPath) else {
            return false
        }
        let imageDir = (candidatePath as NSString).deletingLastPathComponent
        let entries = referenceEntries(for: candidatePath)
        guard !entries.isEmpty else { return false }

        let resolved = resolveReferenceEntries(imageDir: imageDir, entries: entries)
        let targetNorm = normalizePath(targetPath)
        for (label, _) in entries {
            if let refPath = resolved[label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
               normalizePath(refPath) == targetNorm {
                return true
            }
        }
        return false
    }

    private static func referenceEntries(for path: String) -> [(String, Double?)] {
        guard let text = ExifService.userComment(path: path), !text.isEmpty else { return [] }
        return parseReferenceEntries(from: text)
    }

    private static func parseReferenceEntries(from text: String) -> [(String, Double?)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "references:" }) else {
            return []
        }
        var entries: [(String, Double?)] = []
        var index = start + 1
        while index < lines.count {
            let label = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                index += 1
                continue
            }
            if sectionStop?.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
                break
            }
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if fileDateLine?.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil,
                   let value = Double(next) {
                    entries.append((label, value))
                    index += 2
                    continue
                }
            }
            entries.append((label, nil))
            index += 1
        }
        return entries
    }

    private static func resolveReferenceEntries(
        imageDir: String,
        entries: [(String, Double?)]
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        for (label, expectedMtime) in entries {
            let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let path = resolveReferencePath(imageDir: imageDir, label: label, expectedMtime: expectedMtime) {
                resolved[key] = path
            }
        }
        return resolved
    }

    private static func resolveReferencePath(
        imageDir: String,
        label: String,
        expectedMtime: Double?
    ) -> String? {
        var candidates: [String] = []
        if label.hasPrefix("~") || label.hasPrefix("/") {
            candidates.append((label as NSString).expandingTildeInPath)
        }
        let relative = label.hasPrefix("./") ? String(label.dropFirst(2)) : label
        candidates.append((imageDir as NSString).appendingPathComponent(relative))

        for candidate in candidates {
            let normalized = normalizePath(candidate)
            if FileManager.default.fileExists(atPath: normalized), passesMtime(normalized, expected: expectedMtime) {
                return normalized
            }
            let root = (normalized as NSString).deletingPathExtension
            let ext = (normalized as NSString).pathExtension
            guard !ext.isEmpty else { continue }
            for alt in imageExtensions where alt != ".\(ext.lowercased())" {
                let altPath = root + alt
                if FileManager.default.fileExists(atPath: altPath), passesMtime(altPath, expected: expectedMtime) {
                    return altPath
                }
            }
        }
        return nil
    }

    private static func passesMtime(_ path: String, expected: Double?) -> Bool {
        guard let expected else { return true }
        guard let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return false
        }
        return abs(mtime.timeIntervalSince1970 - expected) <= 1.0
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
