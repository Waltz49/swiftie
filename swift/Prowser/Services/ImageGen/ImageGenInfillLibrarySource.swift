import Foundation

/// User library path for infill EXIF and job cards (never MFLUX/Pixelmator temp exports).
enum ImageGenInfillLibrarySource {
    static func resolveCanonicalReference(
        extraCandidates: [String] = [],
        values: [String: Any],
        tempRoot: String
    ) -> String? {
        var candidates: [String] = []
        for raw in extraCandidates {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { candidates.append(t) }
        }
        for raw in values["_canonical_source_image_paths"] as? [String] ?? [] {
            candidates.append(raw)
        }
        for raw in ImageGenExifReferences.resolveSourceImagePaths(values) {
            candidates.append(raw)
        }
        let doc = (values["pixelmator_doc_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.isEmpty { candidates.append(doc) }
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if !ImageGenInfillPathSemantics.isWorkingTempPath(path, tempRoot: tempRoot) {
                return path
            }
        }
        return nil
    }
}
