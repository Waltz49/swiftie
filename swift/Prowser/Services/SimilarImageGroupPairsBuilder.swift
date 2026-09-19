import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

/// Pixel MSE grouping for “Find Similar Image Files” (port of `file_operations_manager.py` similar-image helpers).
enum SimilarImageGroupPairsBuilder {
    static let compareWidth = 128
    static let mseThreshold: Float = 0.0026
    static let workerThreadMinPaths = 2000
    static let binnedClusterMin = 350
    static let maxCandidatesPerIndex = 650
    static let decodeParallelMin = 40
    static let decodeMaxWorkers = 8

    typealias GroupPair = (groupKey: String, path: String)
    typealias ProgressHandler = @Sendable (Int, Int, String) -> Void
    typealias CancelHandler = @Sendable () -> Bool
    typealias TickHandler = @Sendable () -> Void

    /// Build sorted `(group_key, path)` pairs for images with at least one similar neighbor.
    static func buildGroupPairs(
        imagePaths: [String],
        shouldCancel: CancelHandler = { false },
        progress: ProgressHandler = { _, _, _ in },
        progressTick: TickHandler = {}
    ) -> (pairs: [GroupPair], cancelled: Bool) {
        var dimBucket: [String: [String]] = [:]
        let n = imagePaths.count

        for (idx, imagePath) in imagePaths.enumerated() {
            if idx % 64 == 0 {
                progressTick()
            }
            if shouldCancel() { return ([], true) }
            if n > 0 {
                let name = (imagePath as NSString).lastPathComponent
                progress(
                    idx,
                    max(1, n),
                    "Sizing \(RenamePrefixPlanner.elideProgressFilename(name))... (\(idx + 1)/\(n))"
                )
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: imagePath, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            guard let dims = orientedDimensions(path: imagePath) else { continue }
            let key = "\(dims.width)x\(dims.height)"
            dimBucket[key, default: []].append(imagePath)
        }

        if shouldCancel() { return ([], true) }

        progress(n, max(1, n), "Grouping by size...")

        let bucketList = dimBucket
            .filter { $0.value.count >= 2 }
            .sorted { $0.key < $1.key }
            .map(\.value)
        let totalBuckets = bucketList.count
        var rawPairs: [GroupPair] = []

        for (bidx, plist) in bucketList.enumerated() {
            progressTick()
            if shouldCancel() { return ([], true) }
            if let dims = orientedDimensions(path: plist[0]) {
                progress(
                    bidx,
                    max(1, totalBuckets),
                    "Comparing similar images (\(dims.width)×\(dims.height), \(plist.count) files)... "
                        + "bucket \(bidx + 1)/\(totalBuckets)"
                )
            }
            guard let groups = clusterPathsBySimilarityMSE(
                paths: plist,
                shouldCancel: shouldCancel,
                progressTick: progressTick
            ) else {
                return ([], true)
            }
            for group in groups {
                let groupKey = group.min() ?? ""
                for path in group.sorted() {
                    rawPairs.append((groupKey, path))
                }
            }
        }

        rawPairs.sort { $0.groupKey < $1.groupKey || ($0.groupKey == $1.groupKey && $0.path < $1.path) }
        return (rawPairs, false)
    }

    // MARK: - Clustering (testable)

    /// Cluster decoded compare arrays; used by tests with synthetic pixels.
    static func clusterLoaded(
        loaded: [(path: String, rgb: [Float])],
        shouldCancel: CancelHandler = { false },
        progressTick: TickHandler = {}
    ) -> [[String]]? {
        clusterByMSE(loaded: loaded, shouldCancel: shouldCancel, progressTick: progressTick)
    }

    private static func clusterPathsBySimilarityMSE(
        paths: [String],
        shouldCancel: CancelHandler,
        progressTick: TickHandler
    ) -> [[String]]? {
        guard paths.count >= 2 else { return [] }
        guard let loaded = loadCompareArrays(
            paths: paths,
            shouldCancel: shouldCancel,
            progressTick: progressTick
        ) else { return nil }
        guard loaded.count >= 2 else { return [] }
        return clusterByMSE(loaded: loaded, shouldCancel: shouldCancel, progressTick: progressTick)
    }

    private static func clusterByMSE(
        loaded: [(path: String, rgb: [Float])],
        shouldCancel: CancelHandler,
        progressTick: TickHandler
    ) -> [[String]]? {
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

        var digestToIndices: [Data: [Int]] = [:]
        let useBins = n >= binnedClusterMin
        var meanKeys: [(Int, Int, Int)] = []
        var binToIndices: [String: [Int]] = [:]

        for idx in 0 ..< n {
            if idx % 64 == 0 {
                if shouldCancel() { return nil }
                progressTick()
            }
            let arr = loaded[idx].rgb
            let digest = compareDigest(arr)
            digestToIndices[digest, default: []].append(idx)
            if useBins {
                let mk = meanColorCell(arr)
                meanKeys.append(mk)
                let binKey = "\(mk.0),\(mk.1),\(mk.2)"
                binToIndices[binKey, default: []].append(idx)
            }
        }

        for ids in digestToIndices.values where ids.count >= 2 {
            let head = ids[0]
            for other in ids.dropFirst() {
                union(head, other)
            }
        }

        var ops = 0
        if useBins {
            for i in 0 ..< n {
                if i % 12 == 0 {
                    if shouldCancel() { return nil }
                    progressTick()
                }
                let ki = meanKeys[i]
                var cand = Set<Int>()
                for dr in -1 ... 1 {
                    for dg in -1 ... 1 {
                        for db in -1 ... 1 {
                            let nk = (
                                max(0, min(7, ki.0 + dr)),
                                max(0, min(7, ki.1 + dg)),
                                max(0, min(7, ki.2 + db))
                            )
                            let binKey = "\(nk.0),\(nk.1),\(nk.2)"
                            for j in binToIndices[binKey] ?? [] where j > i {
                                cand.insert(j)
                            }
                        }
                    }
                }
                if cand.count > maxCandidatesPerIndex {
                    cand = Set(cand.sorted().prefix(maxCandidatesPerIndex))
                }
                let ai = loaded[i].rgb
                for j in cand {
                    if find(i) == find(j) { continue }
                    let bj = loaded[j].rgb
                    guard ai.count == bj.count else { continue }
                    ops += 1
                    if ops % 400 == 0 { progressTick() }
                    if shouldCancel() { return nil }
                    if mse(ai, bj) <= mseThreshold {
                        union(i, j)
                    }
                }
            }
        } else {
            for i in 0 ..< n {
                if i % 8 == 0 {
                    if shouldCancel() { return nil }
                    progressTick()
                }
                let ai = loaded[i].rgb
                for j in (i + 1) ..< n {
                    if find(i) == find(j) { continue }
                    let bj = loaded[j].rgb
                    guard ai.count == bj.count else { continue }
                    ops += 1
                    if ops % 300 == 0 { progressTick() }
                    if shouldCancel() { return nil }
                    if mse(ai, bj) <= mseThreshold {
                        union(i, j)
                    }
                }
            }
        }

        var rootToPaths: [Int: [String]] = [:]
        for idx in 0 ..< n {
            let r = find(idx)
            rootToPaths[r, default: []].append(loaded[idx].path)
        }
        return rootToPaths.values.filter { $0.count > 1 }
    }

    private static func loadCompareArrays(
        paths: [String],
        shouldCancel: CancelHandler,
        progressTick: TickHandler
    ) -> [(path: String, rgb: [Float])]? {
        let n = paths.count
        if n < decodeParallelMin {
            var loaded: [(String, [Float])] = []
            for (bi, path) in paths.enumerated() {
                if bi % 24 == 0 {
                    if shouldCancel() { return nil }
                    progressTick()
                }
                if let arr = compareArray(path: path) {
                    loaded.append((path, arr))
                }
            }
            return loaded
        }

        let lock = NSLock()
        var arrays: [[Float]?] = Array(repeating: nil, count: n)
        var cancelled = false

        DispatchQueue.concurrentPerform(iterations: n) { bi in
            if bi % 24 == 0 {
                if shouldCancel() {
                    lock.lock()
                    cancelled = true
                    lock.unlock()
                }
                progressTick()
            }
            lock.lock()
            let stop = cancelled
            lock.unlock()
            if stop { return }
            arrays[bi] = compareArray(path: paths[bi])
        }

        if cancelled || shouldCancel() { return nil }

        var loaded: [(String, [Float])] = []
        for bi in 0 ..< n {
            if let arr = arrays[bi] {
                loaded.append((paths[bi], arr))
            }
        }
        return loaded
    }

    static func mse(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in 0 ..< a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum / Float(a.count)
    }

    private static func meanColorCell(_ rgb: [Float]) -> (Int, Int, Int) {
        let pixelCount = rgb.count / 3
        guard pixelCount > 0 else { return (0, 0, 0) }
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        for i in 0 ..< pixelCount {
            let o = i * 3
            r += rgb[o]
            g += rgb[o + 1]
            b += rgb[o + 2]
        }
        let inv = 1 / Float(pixelCount)
        r *= inv
        g *= inv
        b *= inv
        return (
            Int(min(7.999, max(0, r * 7.999))),
            Int(min(7.999, max(0, g * 7.999))),
            Int(min(7.999, max(0, b * 7.999)))
        )
    }

    private static func compareDigest(_ rgb: [Float]) -> Data {
        let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        let hash = SHA256.hash(data: data)
        return Data(hash.prefix(16))
    }

    static func compareArray(path: String) -> [Float]? {
        guard let cg = ImageRecognitionImageLoader.loadCGImage(path: path) else { return nil }
        let resized = resizeToCompareWidth(cg, width: compareWidth)
        return rgbNormalizedFlat(resized)
    }

    static func resizeToCompareWidth(_ image: CGImage, width: Int) -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return image }
        let newW = width
        let newH = max(1, Int(round(Double(h) * Double(newW) / Double(w))))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    private static func rgbNormalizedFlat(_ image: CGImage) -> [Float]? {
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

    static func orientedDimensions(path: String) -> (width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return dimensionsFromLoadedImage(path: path)
        }
        let rawW = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawH = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if rawW > 0, rawH > 0 {
            if (5 ... 8).contains(orientation) {
                return (rawH, rawW)
            }
            return (rawW, rawH)
        }
        return dimensionsFromLoadedImage(path: path)
    }

    private static func dimensionsFromLoadedImage(path: String) -> (width: Int, height: Int)? {
        guard let cg = ImageRecognitionImageLoader.loadCGImage(path: path) else { return nil }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
