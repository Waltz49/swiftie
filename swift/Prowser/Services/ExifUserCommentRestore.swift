import Foundation

/// Restore EXIF UserComment with piexif-compatible binary encoding (Python ``restore_usercomment_to_file``).
enum ExifUserCommentRestore {
    /// Preserves other EXIF tags when bundled Python + piexif are available; otherwise replaces/inserts a minimal EXIF block.
    static func restore(path: String, text: String, mtime: Date?, atime: Date?) throws {
        if text.isEmpty {
            throw ExifService.ExifError.writeFailed
        }
        try restore(path: path, userCommentPayload: ExifService.encodeUserCommentData(text), mtime: mtime, atime: atime)
    }

    /// Restore using on-disk UserComment bytes captured before editing (matches Python external editor session).
    static func restore(path: String, userCommentPayload: Data, mtime: Date?, atime: Date?) throws {
        if userCommentPayload.isEmpty {
            throw ExifService.ExifError.writeFailed
        }
        if try restoreViaBundledPython(path: path, userCommentPayload: userCommentPayload, mtime: mtime, atime: atime) {
            return
        }
        try restoreNative(path: path, userCommentPayload: userCommentPayload, mtime: mtime, atime: atime)
    }

    private static func restoreViaBundledPython(
        path: String,
        userCommentPayload: Data,
        mtime: Date?,
        atime: Date?
    ) throws -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        guard let env = exifPythonEnvironment() else { return false }
        guard canImportPiexif(executable: env.executable, bundleRoot: env.bundleRoot) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: env.executable)
        process.currentDirectoryURL = env.bundleRoot
        process.environment = PythonLocator.processEnvironment(for: env)
        process.arguments = [
            "-c",
            """
            import base64
            import sys
            from exif.exif_utils import restore_usercomment_to_file
            path = sys.argv[1]
            payload = base64.b64decode(sys.stdin.buffer.read())
            ok = restore_usercomment_to_file(path, payload)
            sys.exit(0 if ok else 2)
            """,
            path,
        ]
        let stdin = Pipe()
        process.standardInput = stdin
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(userCommentPayload.base64EncodedData())
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        restoreFileTimes(path: path, mtime: mtime, atime: atime)
        return true
    }

    /// Subprocess Python for EXIF restore (no ``AppConfig`` / profile; avoids MainActor-only ``PythonLocator.resolve``).
    private static func exifPythonEnvironment() -> PythonLocator.Environment? {
        guard let bundleRoot = ImageGenPythonBundle.rootURL() else { return nil }
        let fallbacks = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let executable = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return PythonLocator.Environment(executable: executable, bundleRoot: bundleRoot, profilePath: nil)
    }

    private static func canImportPiexif(executable: String, bundleRoot: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = bundleRoot
        var env = ProcessInfo.processInfo.environment
        ImageGenPythonBundle.applyPythonEnvironment(&env, bundleRoot: bundleRoot, profilePath: nil)
        process.environment = env
        process.arguments = ["-c", "import piexif"]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func restoreNative(path: String, userCommentPayload: Data, mtime: Date?, atime: Date?) throws {
        guard ExifService.canWriteExif(path: path) else { throw ExifService.ExifError.unsupportedFormat }
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: userCommentPayload)
        let output = try ExifSegmentInserter.insert(exifSegment: segment, intoFileAt: path)
        let url = URL(fileURLWithPath: path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser-exif-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try output.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        restoreFileTimes(path: path, mtime: mtime, atime: atime)
    }

    private static func restoreFileTimes(path: String, mtime: Date?, atime: Date?) {
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        if let atime {
            try? FileManager.default.setAttributes([.creationDate: atime], ofItemAtPath: path)
        }
    }
}
