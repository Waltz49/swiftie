import Foundation

/// Native port of the EXIF ``References:`` block helpers in ``image_gen_naming.py``
/// (``source_paths_for_generation_exif``, ``reference_entries_for_source_paths``,
/// ``inject_references_exif_section``). Used when the Python registry bridge cannot
/// write generation EXIF so fallback writes still carry the same References section.
enum ImageGenExifReferences {
    typealias Entry = (line: String, path: String)

    private static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Python ``is_path_under_prowser_temp_dir``.
    private static func isTempWorkPath(_ path: String, tempRoot: String?) -> Bool {
        guard let tempRoot, !tempRoot.isEmpty else { return false }
        let root = URL(fileURLWithPath: tempRoot).standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// Python ``_dedupe_existing_file_paths``.
    private static func dedupeExisting(_ paths: [String], tempRoot: String?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in paths {
            let ap = normalized(raw)
            guard !ap.isEmpty, isFile(ap), !seen.contains(ap) else { continue }
            if isTempWorkPath(ap, tempRoot: tempRoot) { continue }
            seen.insert(ap)
            out.append(ap)
        }
        return out
    }

    /// Python ``resolve_source_image_paths``: ordered unique paths, primary first.
    static func resolveSourceImagePaths(_ values: [String: Any]) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        if let multi = values["source_image_paths"] as? [String] {
            for raw in multi {
                let ap = normalized(raw)
                if !ap.isEmpty, isFile(ap), !seen.contains(ap) {
                    seen.insert(ap)
                    paths.append(ap)
                }
            }
        }
        if let primary = values["source_image_path"] as? String {
            let ap = normalized(primary)
            if !ap.isEmpty, isFile(ap), !seen.contains(ap) {
                paths.insert(ap, at: 0)
            }
        }
        return paths
    }

    /// Python ``resolve_infill_reference`` / infill EXIF source selection.
    static func resolveInfillReferencePath(
        outputPath: String,
        values: [String: Any],
        fallbackSourcePaths: [String],
        tempRoot: String?
    ) -> String? {
        if let pixelPath = values["pixelmator_doc_path"] as? String {
            let ap = normalized(pixelPath)
            if !ap.isEmpty, isFile(ap), !isTempWorkPath(ap, tempRoot: tempRoot) {
                return ap
            }
        }
        let docName = (values["pixelmator_doc_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !docName.isEmpty {
            let outDir = URL(fileURLWithPath: normalized(outputPath)).deletingLastPathComponent().path
            let candidate = URL(fileURLWithPath: outDir).appendingPathComponent(docName).standardizedFileURL.path
            if isFile(candidate), !isTempWorkPath(candidate, tempRoot: tempRoot) {
                return candidate
            }
            let stem = (docName as NSString).deletingPathExtension
            for ext in [".webp", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".tif"] {
                let alt = URL(fileURLWithPath: outDir).appendingPathComponent(stem + ext).standardizedFileURL.path
                if isFile(alt), !isTempWorkPath(alt, tempRoot: tempRoot) {
                    return alt
                }
            }
        }
        let fallbacks = sourcePathsForGenerationExif(values: values, extraPaths: fallbackSourcePaths, tempRoot: tempRoot)
        return fallbacks.first
    }

    /// Python ``source_paths_for_generation_exif``: canonical originals, then values, then fallbacks.
    static func sourcePathsForGenerationExif(
        values: [String: Any],
        extraPaths: [String] = [],
        tempRoot: String?
    ) -> [String] {
        if let canonical = values["_canonical_source_image_paths"] as? [String], !canonical.isEmpty {
            let paths = dedupeExisting(canonical, tempRoot: tempRoot)
            if !paths.isEmpty { return paths }
        }
        let paths = dedupeExisting(resolveSourceImagePaths(values), tempRoot: tempRoot)
        if !paths.isEmpty { return paths }
        guard !extraPaths.isEmpty else { return [] }
        return dedupeExisting(extraPaths, tempRoot: tempRoot)
    }

    /// Python ``exif_reference_line_for_path``: ``./basename`` in the output dir, else ``~``-relative.
    static func referenceLine(for sourcePath: String, outputPath: String) -> String {
        let ap = normalized(sourcePath)
        let outDir = URL(fileURLWithPath: normalized(outputPath)).deletingLastPathComponent().path
        if URL(fileURLWithPath: ap).deletingLastPathComponent().path == outDir {
            return "./" + (ap as NSString).lastPathComponent
        }
        return InformationFormatting.normalizePathForDisplay(ap)
    }

    /// Python ``reference_entries_for_source_paths``.
    static func referenceEntries(
        sourcePaths: [String],
        outputPath: String,
        tempRoot: String?
    ) -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for source in sourcePaths {
            let ap = normalized(source)
            guard !ap.isEmpty, isFile(ap), !isTempWorkPath(ap, tempRoot: tempRoot) else { continue }
            guard !seen.contains(ap) else { continue }
            seen.insert(ap)
            entries.append((line: referenceLine(for: ap, outputPath: outputPath), path: ap))
        }
        return entries
    }

    /// Python ``_strip_references_section``.
    private static func stripReferencesSection(_ comment: String) -> String {
        guard !comment.isEmpty else { return comment }
        let lines = comment.components(separatedBy: .newlines)
        let stopHeaders: Set<String> = ["prompt:", "image model:", "title:", "description:"]
        let mtimePattern = try? NSRegularExpression(pattern: #"^\d+(?:\.\d+)?$"#)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).lowercased() == "references:" {
                i += 1
                while i < lines.count {
                    let label = lines[i].trimmingCharacters(in: .whitespaces)
                    if label.isEmpty {
                        i += 1
                        continue
                    }
                    if stopHeaders.contains(label.lowercased()) { break }
                    if i + 1 < lines.count {
                        let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        let range = NSRange(next.startIndex..., in: next)
                        if mtimePattern?.firstMatch(in: next, range: range) != nil {
                            i += 2
                            continue
                        }
                    }
                    i += 1
                }
                continue
            }
            out.append(lines[i])
            i += 1
        }
        var text = out.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Python ``inject_references_exif_section``: References block (label + mtime per file)
    /// after Image Model / before Prompt.
    static func inject(
        baseComment: String,
        outputPath: String,
        entries: [Entry],
        allowCrossDirectory: Bool,
        tempRoot: String?
    ) -> String {
        let outDir = URL(fileURLWithPath: normalized(outputPath)).deletingLastPathComponent().path
        var pairs: [(String, String)] = []
        var seen = Set<String>()
        for entry in entries {
            let exifLine = entry.line
            guard !exifLine.isEmpty else { continue }
            var path = entry.path
            if path.isEmpty || !isFile(path) {
                let rel = String(exifLine.drop(while: { $0 == "." || $0 == "/" }))
                if !rel.isEmpty {
                    let candidate = URL(fileURLWithPath: outDir).appendingPathComponent(rel).standardizedFileURL.path
                    if isFile(candidate) { path = candidate }
                }
            }
            guard !path.isEmpty, isFile(path) else { continue }
            let ap = normalized(path)
            if !allowCrossDirectory, URL(fileURLWithPath: ap).deletingLastPathComponent().path != outDir {
                continue
            }
            guard !seen.contains(ap) else { continue }
            seen.insert(ap)
            if isTempWorkPath(ap, tempRoot: tempRoot) { continue }
            var line = exifLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("/") {
                line = referenceLine(for: ap, outputPath: outputPath)
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: ap),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            pairs.append((line, String(format: "%.6f", mtime.timeIntervalSince1970)))
        }
        guard !pairs.isEmpty else { return baseComment }

        let base = stripReferencesSection(baseComment)
        var refLines = ["References:"]
        for (line, stamp) in pairs {
            refLines.append(line)
            refLines.append(stamp)
        }
        let block = refLines.joined(separator: "\n")
        let marker = "\n\nPrompt:\n"
        if let range = base.range(of: marker) {
            return base.replacingCharacters(in: range, with: "\n\n" + block + "\n\nPrompt:\n")
        }
        if base.hasPrefix("Prompt:\n") {
            return block + "\n\n" + base
        }
        return base + "\n\n" + block
    }
}
