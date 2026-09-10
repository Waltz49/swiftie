import Foundation

/// Locate and restore files from macOS Trash. Port of `file_operations_manager.py` trash helpers.
enum TrashRestore {
    static func trashDirectories(for originalPath: String) -> [String] {
        var dirs: [String] = []
        let homeTrash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        if FileManager.default.fileExists(atPath: homeTrash) {
            dirs.append(homeTrash)
        }
        let resolved = URL(fileURLWithPath: originalPath).standardizedFileURL.path
        if resolved.hasPrefix("/Volumes/") {
            let parts = resolved.split(separator: "/")
            if parts.count >= 2, parts[0] == "Volumes" {
                let uid = getuid()
                let volumeTrash = "/Volumes/\(parts[1])/.Trashes/\(uid)"
                if FileManager.default.fileExists(atPath: volumeTrash) {
                    dirs.append(volumeTrash)
                }
            }
        }
        return dirs
    }

    static func findTrashedFile(for entry: DeletedFileUndoEntry) -> String? {
        if let trashPath = entry.trashPath,
           FileManager.default.fileExists(atPath: trashPath),
           matchesMetadata(path: trashPath, inode: entry.fileInode, size: entry.fileSize) {
            return trashPath
        }

        let filename = (entry.originalPath as NSString).lastPathComponent
        let trashDirs = trashDirectories(for: entry.originalPath)

        if let inode = entry.fileInode {
            for dir in trashDirs {
                if let match = findByInode(inode, in: dir) {
                    return match
                }
            }
        }

        var scored: [(Int, TimeInterval, String)] = []
        for dir in trashDirs {
            for name in candidateNames(filename: filename) {
                let candidate = (dir as NSString).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                if let score = scoreCandidate(
                    path: candidate,
                    inode: entry.fileInode,
                    size: entry.fileSize,
                    mtime: entry.modificationDate
                ) {
                    if score.0 == 0 { return score.2 }
                    scored.append(score)
                }
            }
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for name in contents where nameRelated(name, to: filename) {
                    let candidate = (dir as NSString).appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    if let score = scoreCandidate(
                        path: candidate,
                        inode: entry.fileInode,
                        size: entry.fileSize,
                        mtime: entry.modificationDate
                    ) {
                        if score.0 == 0 { return score.2 }
                        scored.append(score)
                    }
                }
            }
        }

        if let best = scored.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }).first {
            return best.2
        }

        return appleScriptFindTrash(
            filename: filename,
            inode: entry.fileInode,
            size: entry.fileSize,
            mtime: entry.modificationDate
        )
    }

    static func locateJustTrashed(entry: DeletedFileUndoEntry, maxAttempts: Int = 12, intervalMs: Int = 40) -> String? {
        for attempt in 0..<maxAttempts {
            if let found = findTrashedFile(for: entry) {
                return found
            }
            if attempt < maxAttempts - 1 {
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000.0)
            }
        }
        return nil
    }

    @discardableResult
    static func restore(entry: DeletedFileUndoEntry) -> String? {
        guard let trashPath = findTrashedFile(for: entry) else { return nil }

        let trashURL = URL(fileURLWithPath: trashPath)
        let originalURL = URL(fileURLWithPath: entry.originalPath)
        let parent = originalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var destURL = originalURL
        if FileManager.default.fileExists(atPath: destURL.path) {
            let base = originalURL.deletingPathExtension().lastPathComponent
            let ext = originalURL.pathExtension
            var counter = 1
            repeat {
                let name = ext.isEmpty ? "\(base)_restored_\(counter)" : "\(base)_restored_\(counter).\(ext)"
                destURL = parent.appendingPathComponent(name)
                counter += 1
            } while FileManager.default.fileExists(atPath: destURL.path)
        }

        do {
            try FileManager.default.moveItem(at: trashURL, to: destURL)
            return destURL.path
        } catch {
            NSLog("move from trash failed: \(error)")
            return nil
        }
    }

    private static func candidateNames(filename: String) -> [String] {
        let ns = filename as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var names = [filename]
        for n in 2..<40 {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            names.append(name)
        }
        return names
    }

    private static func nameRelated(_ trashName: String, to originalFilename: String) -> Bool {
        if trashName == originalFilename { return true }
        let ns = originalFilename as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        if ext.isEmpty {
            return trashName.hasPrefix("\(stem) ")
        }
        return trashName.hasPrefix("\(stem) ") && trashName.hasSuffix(".\(ext)")
    }

    private static func matchesMetadata(path: String, inode: UInt64?, size: Int64?) -> Bool {
        guard let attrs = fileAttributes(path) else { return false }
        if let inode, let candidateInode = attrs.inode, candidateInode == inode { return true }
        if let size, attrs.size == size { return true }
        return inode == nil && size == nil
    }

    private static func scoreCandidate(
        path: String,
        inode: UInt64?,
        size: Int64?,
        mtime: Date?
    ) -> (Int, TimeInterval, String)? {
        guard let attrs = fileAttributes(path) else { return nil }
        if let inode, let candidateInode = attrs.inode, candidateInode == inode {
            return (0, 0, path)
        }
        if let size, attrs.size == size {
            let diff: TimeInterval
            if let mtime, let candidateMtime = attrs.mtime {
                diff = abs(candidateMtime.timeIntervalSince1970 - mtime.timeIntervalSince1970)
            } else {
                diff = 0
            }
            return (1, diff, path)
        }
        if inode == nil && size == nil {
            return (2, 0, path)
        }
        return nil
    }

    private static func findByInode(_ inode: UInt64, in directory: String) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        for name in contents {
            let path = (directory as NSString).appendingPathComponent(name)
            if let attrs = fileAttributes(path), attrs.inode == inode {
                return path
            }
        }
        return nil
    }

    private static func fileAttributes(_ path: String) -> (inode: UInt64?, size: Int64, mtime: Date?)? {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return nil }
        return (
            inode: UInt64(statBuf.st_ino),
            size: Int64(statBuf.st_size),
            mtime: Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
        )
    }

    private static func appleScriptFindTrash(
        filename: String,
        inode: UInt64?,
        size: Int64?,
        mtime: Date?
    ) -> String? {
        let stem = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let ext = (filename as NSString).pathExtension
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeName = filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let extClause = ext.isEmpty ? "true" : "n ends with \".\(ext)\""
        let script = """
        tell application "Finder"
            try
                set outPaths to {}
                set trashItems to items of trash
                repeat with trashItem in trashItems
                    set n to name of trashItem as text
                    if n is "\(safeName)" or n starts with "\(safeName) " or n starts with "\(stem) " then
                        if \(extClause) then
                            try
                                set p to POSIX path of (trashItem as alias)
                                set end of outPaths to p
                            end try
                        end if
                    end if
                end repeat
                set AppleScript's text item delimiters to "\\n"
                return outPaths as text
            on error
                return ""
            end try
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }

        var scored: [(Int, TimeInterval, String)] = []
        for line in output.split(separator: "\n") {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
            if let score = scoreCandidate(path: path, inode: inode, size: size, mtime: mtime) {
                if score.0 == 0 { return score.2 }
                scored.append(score)
            }
        }
        return scored.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }).first?.2
    }
}
