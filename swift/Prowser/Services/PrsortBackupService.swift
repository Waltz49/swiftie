import CryptoKit
import Foundation

/// Backup/restore `.prsort` with MD5 hash matching. Port of `menu_manager._backup_custom_sort` / `_restore_custom_sort`.
@MainActor
enum PrsortBackupService {
    private static let backupHeader = "# THIS FILE IS A BACKUP WITH MD5 HASHES FOR FILE IDENTIFICATION"
    private static let formatHeader = "# Format: *filename.jpg:hash (locked) or filename.jpg:hash (unlocked)"

    struct BackupEntry {
        var filename: String
        var hash: String?
        var isLocked: Bool
    }

    static func backupPath(for directory: String) -> String {
        PrsortIO.prsortPath(in: directory) + ".bak"
    }

    static func backup(in directory: String) throws -> String {
        let prsortPath = PrsortIO.prsortPath(in: directory)
        guard FileManager.default.fileExists(atPath: prsortPath) else {
            throw BackupError.prsortNotFound
        }
        guard let custom = PrsortIO.readCustomSort(in: directory) else {
            throw BackupError.readFailed
        }

        var lines = [backupHeader, formatHeader, "#reversed:\(custom.isReversed ? "true" : "false")"]
        for filename in custom.orderedFilenames {
            let filePath = (directory as NSString).appendingPathComponent(filename)
            let lockPrefix = custom.lockedFilenames.contains(filename) ? PrsortIO.lockPrefix : ""
            if FileManager.default.fileExists(atPath: filePath),
               let hash = md5Hex(of: filePath) {
                lines.append("\(lockPrefix)\(filename):\(hash)")
            } else {
                lines.append("\(lockPrefix)\(filename)")
            }
        }

        let backupPath = self.backupPath(for: directory)
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: backupPath, atomically: true, encoding: .utf8)
        return backupPath
    }

    static func restore(in directory: String, extensions: [String]) throws {
        let backupPath = self.backupPath(for: directory)
        guard FileManager.default.fileExists(atPath: backupPath) else {
            throw BackupError.backupNotFound
        }

        let (entries, isReversed) = try parseBackup(at: backupPath)
        guard !entries.isEmpty else {
            throw BackupError.readFailed
        }

        let currentFiles = DirectoryScanner.scanDirectory(
            at: directory,
            extensions: extensions,
            filterPattern: "*"
        )
        var hashToPaths: [String: [String]] = [:]
        var filenameToPath: [String: String] = [:]
        for path in currentFiles {
            let filename = (path as NSString).lastPathComponent
            filenameToPath[filename] = path
            if let hash = md5Hex(of: path) {
                hashToPaths[hash, default: []].append(path)
            }
        }

        var restoredPaths: [String] = []
        var restoredFilenames = Set<String>()
        var lockedFilenames = Set<String>()

        for entry in entries {
            var matched: [String] = []
            if let hash = entry.hash, let paths = hashToPaths[hash] {
                matched = paths
            } else if let path = filenameToPath[entry.filename] {
                matched = [path]
            }
            for path in matched where !restoredPaths.contains(path) {
                restoredPaths.append(path)
                restoredFilenames.insert((path as NSString).lastPathComponent)
                if entry.isLocked {
                    lockedFilenames.insert((path as NSString).lastPathComponent)
                }
            }
        }

        for path in currentFiles {
            let filename = (path as NSString).lastPathComponent
            if !restoredFilenames.contains(filename) {
                restoredPaths.append(path)
            }
        }

        let filenames = restoredPaths.map { ($0 as NSString).lastPathComponent }
        try PrsortIO.writeCustomSort(
            in: directory,
            filenames: filenames,
            isReversed: isReversed,
            locked: lockedFilenames
        )
    }

    static func parseBackup(at path: String) throws -> ([BackupEntry], Bool) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BackupError.readFailed
        }
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var isReversed = false

        while let first = lines.first, first.hasPrefix("#") {
            if first.hasPrefix("#reversed:") {
                isReversed = first.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "true"
            }
            lines.removeFirst()
        }

        var entries: [BackupEntry] = []
        for line in lines {
            var content = line
            let isLocked = content.hasPrefix(PrsortIO.lockPrefix)
            if isLocked {
                content = String(content.dropFirst())
            }
            if let colon = content.lastIndex(of: ":") {
                let filename = String(content[..<colon])
                let hash = String(content[content.index(after: colon)...])
                entries.append(BackupEntry(filename: filename, hash: hash, isLocked: isLocked))
            } else {
                entries.append(BackupEntry(filename: content, hash: nil, isLocked: isLocked))
            }
        }
        return (entries, isReversed)
    }

    private static func md5Hex(of path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum BackupError: LocalizedError {
    case prsortNotFound
    case backupNotFound
    case readFailed

    var errorDescription: String? {
        switch self {
        case .prsortNotFound: return "Custom sort file not found."
        case .backupNotFound: return "Backup file not found."
        case .readFailed: return "Could not read sort file."
        }
    }
}
