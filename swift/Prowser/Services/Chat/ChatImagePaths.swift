import Foundation

/// Port of `chat_plugins/chat_image_paths.py`.
enum ChatImagePaths {
    static func alignSourceImagePaths(storedPaths: [String], sourcePaths: [String]) -> [String] {
        storedPaths.enumerated().map { idx, stored in
            let src = idx < sourcePaths.count ? sourcePaths[idx] : stored
            return preferExistingSource(source: src, storedCopy: stored)
        }
    }

    static func sourcesForNewAttachments(
        newPaths: [String],
        oldStoredPaths: [String]? = nil,
        oldSourcePaths: [String]? = nil
    ) -> [String] {
        guard let oldStored = oldStoredPaths, !oldStored.isEmpty else {
            return newPaths.compactMap { path -> String? in
                guard !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
        }
        var copyToSource: [String: String] = [:]
        let oldSources = oldSourcePaths ?? []
        for (stored, source) in zip(oldStored, oldSources) {
            guard !stored.isEmpty else { continue }
            let absStored = URL(fileURLWithPath: stored).standardizedFileURL.path
            copyToSource[absStored] = preferExistingSource(source: source, storedCopy: stored)
        }
        return newPaths.map { path in
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            if let src = copyToSource[abs] { return src }
            if FileManager.default.isReadableFile(atPath: abs) { return abs }
            return abs
        }
    }

    static func pathsForVisionModel(_ message: ChatMessage) -> [String] {
        resolvedPaths(message)
    }

    static func pathsForImageGen(_ message: ChatMessage) -> [String] {
        resolvedPaths(message)
    }

    static func pathsReferencedByMessages(_ messages: [ChatMessage], exceptMessageID: String? = nil) -> Set<String> {
        var refs = Set<String>()
        for msg in messages {
            if msg.messageID == exceptMessageID { continue }
            for path in msg.imagePaths where !path.isEmpty {
                refs.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        return refs
    }

    private static func resolvedPaths(_ message: ChatMessage) -> [String] {
        let copies = message.imagePaths
        let sources = message.sourceImagePaths
        guard !copies.isEmpty else { return [] }
        if sources.count != copies.count {
            return copies.filter { FileManager.default.isReadableFile(atPath: $0) }
        }
        return zip(sources, copies).compactMap { src, copy in
            let path = preferExistingSource(source: src, storedCopy: copy)
            return FileManager.default.isReadableFile(atPath: path) ? path : nil
        }
    }

    private static func preferExistingSource(source: String, storedCopy: String) -> String {
        if !source.isEmpty {
            let abs = URL(fileURLWithPath: source).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: abs) { return abs }
        }
        if !storedCopy.isEmpty {
            return URL(fileURLWithPath: storedCopy).standardizedFileURL.path
        }
        return source.isEmpty ? storedCopy : source
    }
}
