import Foundation

/// Copy dropped images into the chat session folder so context stays stable.
/// Port of `chat_plugins/chat_image_store.py`.
enum ChatImageStore {
    static let maxImages = 4
    static let imagesDirectoryName = "chat_session_images"

    static func sessionImagesDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(imagesDirectoryName, isDirectory: true)
    }

    static func storeImages(
        _ sourcePaths: [String],
        messageID: UUID,
        dataDirectory: URL
    ) -> [String] {
        let destDir = sessionImagesDirectory(dataDirectory: dataDirectory)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        var stored: [String] = []
        for (index, source) in sourcePaths.prefix(maxImages).enumerated() {
            guard !source.isEmpty, FileManager.default.fileExists(atPath: source) else { continue }
            let ext = URL(fileURLWithPath: source).pathExtension.isEmpty
                ? "png"
                : URL(fileURLWithPath: source).pathExtension.lowercased()
            let dest = destDir.appendingPathComponent("\(messageID.uuidString)_\(index).\(ext)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(atPath: source, toPath: dest.path)
                stored.append(dest.path)
            } catch {
                continue
            }
        }
        return stored
    }

    static func alignSourcePaths(storedPaths: [String], sourcePaths: [String]) -> [String] {
        guard storedPaths.count == sourcePaths.count else { return storedPaths }
        return zip(storedPaths, sourcePaths).map { stored, source in
            source.isEmpty ? stored : source
        }
    }

    static func removeMessageImages(
        _ paths: [String],
        stillReferenced: Set<String>,
        dataDirectory: URL
    ) {
        let managedRoot = sessionImagesDirectory(dataDirectory: dataDirectory).path + "/"
        for path in paths where !stillReferenced.contains(path) {
            guard path.hasPrefix(managedRoot) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func referencedPaths(in messages: [ChatMessage]) -> Set<String> {
        Set(messages.flatMap { $0.imagePaths })
    }

    static func clearSessionImages(dataDirectory: URL) {
        let dir = sessionImagesDirectory(dataDirectory: dataDirectory)
        try? FileManager.default.removeItem(at: dir)
    }
}
