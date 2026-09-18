import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Pixel MSE “find similar image files” (port of `file_operations_manager.py` similar-image mode).
@MainActor
enum SimilarImageFilesService {
    private final class CancelBox: @unchecked Sendable {
        var value = false
    }
    static let compareWidth = 128
    static let mseThreshold: Float = 0.0026

    static func findInDisplayed(appState: AppState) async {
        exitSlideshowIfNeeded(appState: appState)
        let paths = filteredDisplayedPaths(appState: appState)
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No images displayed", message: "")
            return
        }
        await run(paths: paths, appState: appState, title: "Find Similar Image Files")
    }

    static func findRecursive(appState: AppState) async {
        exitSlideshowIfNeeded(appState: appState)
        guard let root = DuplicateFinderService.resolveRecursiveScanRoot(appState: appState) else {
            StyledMessageDialog.showWarning(title: "No directory open", message: "Open a folder first.")
            return
        }
        if FileTreePathRestrictions.isRootOrSystemVolume(root) {
            StyledMessageDialog.showWarning(title: "Action Not Available", message: "This action is not available on this volume.")
            return
        }
        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let paths = DirectoryScanner.scanDirectoryRecursive(
            at: root,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern,
            excludedPaths: excluded,
            includeHidden: showHidden
        )
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No Images Found", message: "No image files found in directory and subdirectories.")
            return
        }
        let saved = appState.fileData.currentImagePath
        await run(paths: paths, appState: appState, title: "Find Similar Image Files", pinDirectory: root, currentPath: saved)
    }

    private static func run(
        paths: [String],
        appState: AppState,
        title: String,
        pinDirectory: String? = nil,
        currentPath: String? = nil
    ) async {
        let panel = CancellableProgressPanelController(title: title, labelText: "Analyzing images…", maximum: paths.count)
        panel.show()
        let cancelBox = CancelBox()
        let cancelled = await Task.detached {
            Self.buildGroupPairs(paths: paths, shouldCancel: { cancelBox.value }, progress: { cur, max, label in
                Task { @MainActor in
                    cancelBox.value = panel.cancelRequested
                    panel.setMaximum(max)
                    panel.update(value: cur, label: label)
                }
            })
        }.value
        panel.close()
        if cancelled.cancelled {
            appState.status.show("Find similar images cancelled")
            return
        }
        guard !cancelled.pairs.isEmpty else {
            StyledMessageDialog.showInformation(
                title: "No Similar Images Found",
                message: "No groups of visually similar images were found (same oriented dimensions; compared at 128px width)."
            )
            return
        }
        if let pinDirectory {
            appState.fileData.setCurrentDirectory(pinDirectory)
            appState.config.updateSetting("last_directory", value: pinDirectory)
        }
        let saved = currentPath ?? appState.fileData.currentImagePath
        DuplicateGroupPresentation.present(
            appState: appState,
            groupPathPairs: cancelled.pairs,
            currentImagePath: saved,
            statusMessage: "Browse mode: Similar images (\(cancelled.pairs.count) files)"
        )
    }

    private static func filteredDisplayedPaths(appState: AppState) -> [String] {
        let displayed = appState.fileData.displayedImages
        let pattern = appState.filterSettings.filterPattern
        if pattern == "*" || pattern.isEmpty { return displayed }
        return displayed.filter {
            DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern)
        }
    }

    nonisolated private static func buildGroupPairs(
        paths: [String],
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (Int, Int, String) -> Void
    ) -> (pairs: [(hash: String, path: String)], cancelled: Bool) {
        var dimBuckets: [String: [String]] = [:]
        for path in paths {
            guard let dims = orientedDimensions(path: path) else { continue }
            let key = "\(dims.width)x\(dims.height)"
            dimBuckets[key, default: []].append(path)
        }
        var allGroups: [[String]] = []
        let buckets = Array(dimBuckets.values)
        for (bi, bucket) in buckets.enumerated() {
            if shouldCancel() { return ([], true) }
            progress(bi, buckets.count, "Comparing bucket \(bi + 1)/\(buckets.count)")
            if let groups = clusterBucket(bucket, shouldCancel: shouldCancel) {
                allGroups.append(contentsOf: groups)
            } else {
                return ([], true)
            }
        }
        var pairs: [(String, String)] = []
        for (gi, group) in allGroups.enumerated() {
            let key = "similar-\(gi)"
            for path in group.sorted() {
                pairs.append((key, path))
            }
        }
        pairs.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        return (pairs, false)
    }

    nonisolated private static func clusterBucket(_ paths: [String], shouldCancel: () -> Bool) -> [[String]]? {
        guard paths.count >= 2 else { return [] }
        var loaded: [(String, [Float])] = []
        for path in paths {
            if shouldCancel() { return nil }
            guard let arr = compareArray(path: path) else { continue }
            loaded.append((path, arr))
        }
        guard loaded.count >= 2 else { return [] }
        let n = loaded.count
        var parent = Array(0 ..< n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        for i in 0 ..< n {
            if shouldCancel() { return nil }
            let ai = loaded[i].1
            for j in (i + 1) ..< n {
                let bj = loaded[j].1
                guard ai.count == bj.count else { continue }
                if mse(ai, bj) <= mseThreshold {
                    union(i, j)
                }
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0 ..< n {
            groups[find(i), default: []].append(loaded[i].0)
        }
        return groups.values.filter { $0.count > 1 }
    }

    nonisolated private static func mse(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0 ..< a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum / Float(a.count)
    }

    nonisolated private static func compareArray(path: String) -> [Float]? {
        guard let cg = loadCGImage(path: path) else { return nil }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let newW = compareWidth
        let newH = max(1, Int(round(Double(h) * Double(newW) / Double(w))))
        let resized = ImageNetPreprocessor.resizePublic(cg, shortSide: newW)
        guard let cropped = resized.cropping(to: CGRect(x: 0, y: 0, width: min(newW, resized.width), height: min(newH, resized.height))) else {
            return nil
        }
        return rgbNormalizedFlat(cropped)
    }

    nonisolated private static func rgbNormalizedFlat(_ image: CGImage) -> [Float]? {
        let w = image.width
        let h = image.height
        let bpp = 4
        let row = w * bpp
        var raw = [UInt8](repeating: 0, count: h * row)
        guard let ctx = CGContext(
            data: &raw,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: row,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Float]()
        out.reserveCapacity(w * h * 3)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * bpp
                out.append(Float(raw[i]) / 255)
                out.append(Float(raw[i + 1]) / 255)
                out.append(Float(raw[i + 2]) / 255)
            }
        }
        return out
    }

    nonisolated private static func loadCGImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func orientedDimensions(path: String) -> (width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private static func exitSlideshowIfNeeded(appState: AppState) {
        switch appState.fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            appState.fileData.setViewMode(.thumbnail)
        default:
            break
        }
    }
}
