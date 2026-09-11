import Foundation

/// EXIF reference dependency graph. Port of `search/reference_graph.py`.
struct ReferenceGraph {
    var nodes: [String]
    var edges: [(String, String)] // (source, target) reference -> product
    var focusPath: String?
}

/// EXIF reference parsing for Find References. Port of `search/reference_graph.py` (subset).
enum ReferenceGraphService {
    private static let sectionStop = try? NSRegularExpression(
        pattern: "^(?:prompt|image model|title|description):$",
        options: [.caseInsensitive]
    )
    private static let fileDateLine = try? NSRegularExpression(pattern: "^\\d+(?:\\.\\d+)?$")
    private static let imageExtensions = [".png", ".jpg", ".webp", ".jpeg"]

    @MainActor
    static func imagesReferencing(targetPath: String, in candidates: [String]) async -> [String] {
        let targetNorm = normalizePath(targetPath)
        var matches: [String] = []
        for candidate in candidates {
            if normalizePath(candidate) == targetNorm { continue }
            if await pathIsReferencedInExif(candidatePath: candidate, targetPath: targetPath) {
                matches.append(candidate)
            }
        }
        return matches
    }

    @MainActor
    static func pathIsReferencedInExif(candidatePath: String, targetPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: candidatePath),
              FileManager.default.fileExists(atPath: targetPath) else {
            return false
        }
        let imageDir = (candidatePath as NSString).deletingLastPathComponent
        let entries = await referenceEntries(for: candidatePath)
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

    @MainActor
    private static func referenceEntries(for path: String) async -> [(String, Double?)] {
        guard let text = await ExifService.userDescription(path: path), !text.isEmpty else { return [] }
        return parseReferenceEntries(from: text)
    }

    static func parseReferenceEntries(from text: String) -> [(String, Double?)] {
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

    static func resolveReferenceEntries(
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

    @MainActor
    static func collectReferenceChainPaths(
        imageDir: String,
        rootPath: String,
        entries: [(String, Double?)]
    ) async -> (paths: [String], extensionSwapped: Bool) {
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return ([], false)
        }
        var seenPaths = Set<String>()
        var seenNames = Set<String>()
        var output: [String] = []
        let extensionSwapped = false

        func visit(path: String, directEntries: [(String, Double?)]) async {
            let normalized = normalizePath(path)
            if seenPaths.contains(normalized) { return }
            seenPaths.insert(normalized)
            output.append(path)

            let localDir = (path as NSString).deletingLastPathComponent
            let resolved = resolveReferenceEntries(imageDir: localDir.isEmpty ? imageDir : localDir, entries: directEntries)
            for (label, _) in directEntries {
                let nameKey = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if seenNames.contains(nameKey) { continue }
                guard let refPath = resolved[nameKey] else { continue }
                let refNorm = normalizePath(refPath)
                if seenPaths.contains(refNorm) {
                    seenNames.insert(nameKey)
                    continue
                }
                seenNames.insert(nameKey)
                let childEntries = await referenceEntries(for: refPath)
                await visit(path: refPath, directEntries: childEntries)
            }
        }

        await visit(path: rootPath, directEntries: entries)
        return (output, extensionSwapped)
    }

    @MainActor
    static func buildReferenceGraph(paths: [String], focusPath: String?) async -> ReferenceGraph {
        var canonical: [String] = []
        var normToPath: [String: String] = [:]
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let normalized = normalizePath(path)
            if normToPath[normalized] == nil {
                normToPath[normalized] = path
                canonical.append(path)
            }
        }

        let pathSet = Set(normToPath.keys)
        var edges: [(String, String)] = []
        var seenEdges = Set<String>()

        for targetPath in canonical {
            let targetNorm = normalizePath(targetPath)
            let imageDir = (targetPath as NSString).deletingLastPathComponent
            let entries = await referenceEntries(for: targetPath)
            let resolved = resolveReferenceEntries(imageDir: imageDir, entries: entries)
            for (label, _) in entries {
                let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let sourcePath = resolved[key] else { continue }
                let sourceNorm = normalizePath(sourcePath)
                guard pathSet.contains(sourceNorm), sourceNorm != targetNorm else { continue }
                let sourceCanon = normToPath[sourceNorm]!
                let targetCanon = normToPath[targetNorm]!
                let edgeKey = "\(sourceNorm)|\(targetNorm)"
                guard !seenEdges.contains(edgeKey) else { continue }
                seenEdges.insert(edgeKey)
                edges.append((sourceCanon, targetCanon))
            }
        }

        var focus: String?
        if let focusPath, FileManager.default.fileExists(atPath: focusPath) {
            let normalized = normalizePath(focusPath)
            if pathSet.contains(normalized) {
                focus = normToPath[normalized]
            }
        }
        if focus == nil {
            focus = canonical.first
        }
        return ReferenceGraph(nodes: canonical, edges: edges, focusPath: focus)
    }
}
