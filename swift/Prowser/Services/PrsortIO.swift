import Foundation

/// Read/write `.prsort` custom order files. Port of `files/prsort_io.py`.
enum PrsortIO {
    static let lockPrefix = "*"
    private static let warningPrefixes = [
        "# THIS FILE IS ONLY FOR",
        "# THIS FILE MUST NOT BE USED",
    ]
    private static let doNotUsePrefix = "# DO NOT USE"
    private static let warningHeaderLines = [
        "# THIS FILE IS ONLY FOR CUSTOM SORT ORDERING AND FILE LOCKING",
        "# DO NOT USE .prsort TO ORDER UNLOCKED FILES",
    ]

    private static let cacheLock = NSLock()
    private static var customSortCache: [String: (mtime: TimeInterval, custom: CustomSort?)] = [:]

    static func invalidateCache(in directory: String) {
        cacheLock.lock()
        customSortCache.removeValue(forKey: directory)
        cacheLock.unlock()
    }

    struct CustomSort {
        var orderedFilenames: [String]
        var isReversed: Bool
        var lockedFilenames: Set<String>
    }

    static func prsortPath(in directory: String) -> String {
        URL(fileURLWithPath: directory).appendingPathComponent(".prsort").path
    }

    static func readLines(at path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if lines.first?.hasPrefix(warningPrefixes[0]) == true {
            lines.removeFirst()
            if lines.first?.hasPrefix(doNotUsePrefix) == true {
                lines.removeFirst()
            }
        }
        return lines.isEmpty ? nil : lines
    }

    static func parseCustomSort(lines: [String]) -> CustomSort? {
        guard let first = lines.first, first.hasPrefix("#reversed:") else { return nil }
        let isReversed = first.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces).lowercased() == "true"
        var ordered: [String] = []
        var locked: Set<String> = []
        for line in lines.dropFirst() {
            if line.hasPrefix(lockPrefix) {
                let name = String(line.dropFirst())
                ordered.append(name)
                locked.insert(name)
            } else {
                ordered.append(line)
            }
        }
        return CustomSort(orderedFilenames: ordered, isReversed: isReversed, lockedFilenames: locked)
    }

    static func readCustomSort(in directory: String) -> CustomSort? {
        let path = prsortPath(in: directory)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        cacheLock.lock()
        if let cached = customSortCache[directory], cached.mtime == mtime {
            let custom = cached.custom
            cacheLock.unlock()
            return custom
        }
        cacheLock.unlock()
        guard let lines = readLines(at: path) else {
            cacheLock.lock()
            customSortCache[directory] = (mtime, nil)
            cacheLock.unlock()
            return nil
        }
        let custom = parseCustomSort(lines: lines)
        cacheLock.lock()
        customSortCache[directory] = (mtime, custom)
        cacheLock.unlock()
        return custom
    }

    /// Apply custom `.prsort` order to full paths in a directory.
    static func applyCustomOrder(paths: [String], directory: String) -> [String] {
        guard let custom = readCustomSort(in: directory) else { return paths }
        let basenameToPath = Dictionary(uniqueKeysWithValues: paths.map { (($0 as NSString).lastPathComponent, $0) })
        var result: [String] = []
        var seen: Set<String> = []
        for name in custom.orderedFilenames {
            if let path = basenameToPath[name], !seen.contains(path) {
                result.append(path)
                seen.insert(path)
            }
        }
        for path in paths where !seen.contains(path) {
            result.append(path)
        }
        return custom.isReversed ? result.reversed() : result
    }

    static func lockedFilenames(in directory: String) -> Set<String> {
        readCustomSort(in: directory)?.lockedFilenames ?? []
    }

    static func isFileLocked(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        return lockedFilenames(in: directory).contains(filename)
    }

    /// Port of `sorting_manager._separate_locked_unlocked`.
    /// Locked files come first in their saved `.prsort` order; unlocked files keep the input order.
    /// `.prsort` is never used to order unlocked files.
    static func separateLockedUnlocked(_ paths: [String]) -> (locked: [String], unlocked: [String]) {
        guard let first = paths.first else { return ([], []) }
        let directory = (first as NSString).deletingLastPathComponent
        let custom = readCustomSort(in: directory)
        let lockedNames = custom?.lockedFilenames ?? []
        guard !lockedNames.isEmpty else { return ([], paths) }

        let nameToPath = Dictionary(paths.map { (($0 as NSString).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        var locked: [String] = []
        var lockedSet = Set<String>()
        for name in custom?.orderedFilenames ?? [] where lockedNames.contains(name) {
            if let path = nameToPath[name], lockedSet.insert(path).inserted {
                locked.append(path)
            }
        }
        for path in paths where lockedNames.contains((path as NSString).lastPathComponent) {
            if lockedSet.insert(path).inserted {
                locked.append(path)
            }
        }
        let unlocked = paths.filter { !lockedSet.contains($0) }
        return (locked, unlocked)
    }

    /// Port of `sorting_manager._apply_custom_sort_unlocked` (unlocked files only).
    static func applyCustomSortUnlocked(_ paths: [String], directory: String) -> [String] {
        guard let custom = readCustomSort(in: directory) else { return paths }
        let lockedNames = custom.lockedFilenames
        let nameToPath = Dictionary(paths.map { (($0 as NSString).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        var unlockedInPrsort: [String] = []
        var seen = Set<String>()
        for name in custom.orderedFilenames where !lockedNames.contains(name) {
            if let path = nameToPath[name], seen.insert(path).inserted {
                unlockedInPrsort.append(path)
            }
        }
        var result = unlockedInPrsort
        for path in paths where !seen.contains(path) {
            result.append(path)
        }
        return result
    }

    /// Update lock markers for files in `directory`, preserving displayed order when possible.
    static func writeLocks(
        in directory: String,
        displayedPaths: [String],
        lockedFilenames: Set<String>
    ) throws {
        let dirPaths = displayedPaths.filter { ($0 as NSString).deletingLastPathComponent == directory }
        let filenames = dirPaths.map { ($0 as NSString).lastPathComponent }
        let isReversed = readCustomSort(in: directory)?.isReversed ?? false
        if filenames.isEmpty, lockedFilenames.isEmpty { return }
        let ordered = filenames.isEmpty
            ? (readCustomSort(in: directory)?.orderedFilenames ?? Array(lockedFilenames))
            : filenames
        try writeCustomSort(in: directory, filenames: ordered, isReversed: isReversed, locked: lockedFilenames)
    }

    static func writeCustomSort(
        in directory: String,
        filenames: [String],
        isReversed: Bool,
        locked: Set<String> = []
    ) throws {
        var lines = warningHeaderLines + ["#reversed:\(isReversed ? "true" : "false")"]
        for name in filenames {
            if locked.contains(name) {
                lines.append("\(lockPrefix)\(name)")
            } else {
                lines.append(name)
            }
        }
        let path = prsortPath(in: directory)
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        invalidateCache(in: directory)
    }
}
