import Foundation

/// Directory face scan (port of `faces/face_scan_runner.py` / `run_scan`).
enum FaceScanRunner {
    /// Runs `runScan` off the main actor (dlib inference must not block the UI).
    static func runScanAsync(
        profile: ProfilePaths,
        faceCache: FaceCacheService,
        rootDirectory: String,
        maxDepth: Int,
        imagePaths: [String]?,
        imageExtensions: [String],
        progress: @escaping @Sendable (_ current: Int, _ total: Int, _ path: String, _ processed: Bool, _ extractionDuration: TimeInterval?) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async -> Int {
        await Task.detached(priority: .userInitiated) {
            runScan(
                profile: profile,
                faceCache: faceCache,
                rootDirectory: rootDirectory,
                maxDepth: maxDepth,
                imagePaths: imagePaths,
                imageExtensions: imageExtensions,
                progress: progress,
                shouldCancel: shouldCancel
            )
        }.value
    }

    static func runScan(
        profile: ProfilePaths,
        faceCache: FaceCacheService,
        rootDirectory: String,
        maxDepth: Int,
        imagePaths: [String]?,
        imageExtensions: [String],
        progress: (_ current: Int, _ total: Int, _ path: String, _ processed: Bool, _ extractionDuration: TimeInterval?) -> Void,
        shouldCancel: () -> Bool
    ) -> Int {
        let paths = imagePaths ?? collectImagePaths(
            root: rootDirectory,
            maxDepth: maxDepth,
            imageExtensions: imageExtensions
        )
        guard FaceEngine.loadModelsIfNeeded(profile: profile) else { return 0 }

        let total = paths.count
        var cachedCount = 0
        for (index, path) in paths.enumerated() {
            if shouldCancel() { break }
            progress(index, total, path, false, nil)
            if faceCache.hasCachedFaces(imagePath: path) {
                progress(index + 1, total, path, false, nil)
                continue
            }
            let extractStart = CFAbsoluteTimeGetCurrent()
            let detections = FaceEngine.encodeFacesFromPath(path, profile: profile)
            let extractDuration = CFAbsoluteTimeGetCurrent() - extractStart
            let encodings = detections.map(\.encoding)
            // Persist negative results too (Python `set_encodings` always writes).
            faceCache.setEncodings(imagePath: path, encodings: encodings, mtime: nil, size: nil)
            if !encodings.isEmpty {
                cachedCount += 1
            }
            progress(index + 1, total, path, true, extractDuration)
        }
        faceCache.flushIndex()
        return cachedCount
    }

    static func imagePaths(
        rootDirectory: String,
        maxDepth: Int,
        imagePaths: [String]?,
        imageExtensions: [String]
    ) -> [String] {
        if let imagePaths { return imagePaths }
        return collectImagePaths(root: rootDirectory, maxDepth: maxDepth, imageExtensions: imageExtensions)
    }

    private static func collectImagePaths(root: String, maxDepth: Int, imageExtensions: [String]) -> [String] {
        var results: [String] = []
        let exts = Set(imageExtensions.map { $0.lowercased().replacingOccurrences(of: ".", with: "") })
        func walk(_ dir: String, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in items.sorted() {
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if depth < maxDepth { walk(full, depth: depth + 1) }
                } else if exts.contains((name as NSString).pathExtension.lowercased()) {
                    results.append(full)
                }
            }
        }
        walk(root, depth: 0)
        return results
    }
}
