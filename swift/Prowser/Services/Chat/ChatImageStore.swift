import Foundation

/// Port of `chat_plugins/chat_image_store.py`.
@MainActor
final class ChatImageStore {
    static let maxChatImages = 4

    private var persistent: Bool
    private var sessionDirectory: URL

    init(persistent: Bool, dataDirectory: URL, temporaryFilesDirectory: URL) {
        self.persistent = persistent
        if persistent {
            sessionDirectory = ChatPersistence.sessionImagesDirectory(dataDirectory: dataDirectory)
        } else {
            let root = temporaryFilesDirectory
                .appendingPathComponent("chat_conversation", isDirectory: true)
            let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            sessionDirectory = root.appendingPathComponent(sessionID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    func resetSession(persistent: Bool, dataDirectory: URL, temporaryFilesDirectory: URL) {
        self.persistent = persistent
        if persistent {
            sessionDirectory = ChatPersistence.sessionImagesDirectory(dataDirectory: dataDirectory)
        } else {
            let root = temporaryFilesDirectory
                .appendingPathComponent("chat_conversation", isDirectory: true)
            let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            sessionDirectory = root.appendingPathComponent(sessionID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    func storeImages(
        _ paths: [String],
        messageID: String,
        referencedElsewhere: Set<String>
    ) -> [String] {
        var stored: [String] = []
        let sessionRoot = sessionDirectory.standardizedFileURL.path
        for (idx, src) in paths.prefix(Self.maxChatImages).enumerated() {
            guard !src.isEmpty, FileManager.default.isReadableFile(atPath: src) else { continue }
            let absSrc = URL(fileURLWithPath: src).standardizedFileURL.path
            if absSrc == sessionRoot || absSrc.hasPrefix(sessionRoot + "/") {
                stored.append(absSrc)
                continue
            }
            if referencedElsewhere.contains(absSrc) {
                stored.append(absSrc)
                continue
            }
            let ext = (absSrc as NSString).pathExtension.isEmpty ? "png" : (absSrc as NSString).pathExtension
            let dest = sessionDirectory.appendingPathComponent("\(messageID)_\(idx).\(ext.lowercased())")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: absSrc), to: dest)
                stored.append(dest.standardizedFileURL.path)
            } catch {
                continue
            }
        }
        return stored
    }
}
