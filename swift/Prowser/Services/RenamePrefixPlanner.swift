import Foundation

/// Pure (UI-free) algorithms behind "Rename with Custom Prefix".
/// Port of the planning helpers in `files/file_operations_manager.py`:
/// `_validate_unix_filename`, `_find_available_temp_prefix`, `_calculate_target_names`,
/// `_build_efficient_rename_plan`, `_minimize_date_changes`.
enum RenamePrefixPlanner {
    /// Python `sort_mode` values.
    enum SortMode: String {
        case date
        case order
    }

    /// Python `date_change_mode` values.
    enum DateChangeMode: String {
        case none
        case oldest
        case newest

        var changesDates: Bool { self != .none }
    }

    /// Python `order_direction` values.
    enum OrderDirection: String {
        case top
        case bottom
    }

    struct Options {
        var prefixTemplate: String
        var incrementLength: Int
        var startingNumber: Int
        var sortMode: SortMode
        var dateChangeMode: DateChangeMode
        var orderDirection: OrderDirection
    }

    struct Mapping: Equatable {
        var source: String
        var target: String
    }

    struct Plan {
        /// Existing (non-source) files that collide with a target name → temp name.
        var phase0: [Mapping]
        /// Source → temp name.
        var phase1: [Mapping]
        /// Temp name → final name.
        var phase2: [Mapping]

        var operationCount: Int { phase0.count + phase1.count + phase2.count }
    }

    struct SequenceOverflowError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias ProgressCallback = (_ current: Int, _ total: Int, _ message: String) -> Void

    // Python does not wrap at 10**increment_length - 1; digit width grows instead (9999 -> 10000).
    static let maxSequenceCeiling = 1_000_000_000

    // MARK: - Small helpers (utils.py ports)

    /// `utils.get_file_extension`: lowercase extension including the dot, or "".
    static func fileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext.lowercased()
    }

    /// `utils.file_string`.
    static func fileString(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    /// `utils.elide_middle`.
    static func elideMiddle(_ text: String, maxLen: Int) -> String {
        if maxLen <= 0 { return "" }
        let chars = Array(text)
        if chars.count <= maxLen { return text }
        if maxLen <= 3 { return String(chars.prefix(maxLen)) }
        let keep = maxLen - 3
        let front = (keep + 1) / 2
        let back = keep / 2
        return String(chars.prefix(front)) + "..." + String(chars.suffix(back))
    }

    /// `utils.elide_progress_filename` (PROGRESS_FILENAME_MAX_CHARS = 44).
    static func elideProgressFilename(_ filename: String) -> String {
        elideMiddle(filename, maxLen: 44)
    }

    /// `utils.is_inside_photos_library`.
    static func isInsidePhotosLibrary(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let absolute = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        for component in (absolute as NSString).pathComponents {
            if component.hasSuffix(".photoslibrary") || component.contains(".photoslibrary") {
                return true
            }
        }
        return false
    }

    /// `os.path.normpath(os.path.realpath(p))` equivalent used for source-path identity checks.
    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Regular files in `directory` keyed by UPPER-CASED filename (Python `existing_files_map`).
    static func existingFilesMap(in directory: String) -> [String: String] {
        var map: [String: String] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return map }
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                map[name.uppercased()] = path
            }
        }
        return map
    }

    // MARK: - _validate_unix_filename

    /// Returns `nil` when valid, otherwise the Python error message.
    static func validateUnixFilename(_ prefix: String) -> String? {
        if prefix.isEmpty { return "Prefix cannot be empty" }
        for char in ["/", "\u{0}"] where prefix.contains(char) {
            return "Prefix cannot contain '\(char)'"
        }
        if prefix.hasPrefix(".") { return "Prefix cannot start with a dot (hidden files)" }
        if prefix.count > 240 { return "Prefix is too long (max 240 characters)" }
        return nil
    }

    // MARK: - _find_available_temp_prefix

    static func findAvailableTempPrefix(in directory: String) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for _ in 0..<100 {
            let suffix = String((0..<4).map { _ in letters.randomElement()! })
            let tempPrefix = "temp\(suffix)"
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            let conflict = names.contains { $0.hasPrefix(tempPrefix + "-") || $0 == tempPrefix }
            if !conflict { return tempPrefix }
        }
        return "temp\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    // MARK: - Sequence number helpers

    /// `format_seq`: zero-pad to `incrementLength`, growing when the number is wider.
    static func formatSequence(_ number: Int, incrementLength: Int) -> String {
        let digits = String(number)
        let width = max(incrementLength, digits.count)
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// Number from the *final* filename `prefix-NNNN.ext` (Python `get_sequence_number`), 999999 when absent.
    static func sequenceNumber(of path: String, prefix: String) -> Int {
        let basename = (path as NSString).lastPathComponent
        let pattern = "\(NSRegularExpression.escapedPattern(for: prefix))-(\\d+)(\\.[^.]+)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 999_999 }
        let range = NSRange(basename.startIndex..., in: basename)
        guard let match = regex.firstMatch(in: basename, range: range),
              let numberRange = Range(match.range(at: 1), in: basename),
              let value = Int(basename[numberRange]) else {
            return 999_999
        }
        return value
    }

    // MARK: - _calculate_target_names

    /// Sequential target names, never reusing occupied numbers and never wrapping.
    static func calculateTargetNames(
        images: [String],
        prefix: String,
        directory: String,
        incrementLength: Int,
        startingNumber: Int,
        progress: ProgressCallback? = nil,
        effectiveStartOverride: Int? = nil,
        preferSourceNumber: Bool = false,
        appendAfterOccupied: Bool = false
    ) throws -> [Mapping] {
        // 1. Index all files in target dir (case insensitive)
        progress?(0, 100, "Scanning directory...")
        let existingFiles = existingFilesMap(in: directory)
        progress?(existingFiles.count, existingFiles.count, "Scanning directory... (\(existingFiles.count)/\(existingFiles.count))")

        // 2. Source identity set
        let sourcePaths = Set(images.map(realPath))

        // Accept digit length >= increment_length so overflow names (10000 when digits=4) count as occupied.
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        let dashPattern = try? NSRegularExpression(pattern: "^\(escaped)-(\\d+)$", options: .caseInsensitive)
        let noDashPattern = try? NSRegularExpression(pattern: "^\(escaped)(\\d+)$", options: .caseInsensitive)

        func extractNumber(_ filename: String) -> Int? {
            let stem = (filename as NSString).deletingPathExtension
            let range = NSRange(stem.startIndex..., in: stem)
            for regex in [dashPattern, noDashPattern] {
                guard let regex, let match = regex.firstMatch(in: stem, range: range),
                      let numberRange = Range(match.range(at: 1), in: stem) else { continue }
                let digits = stem[numberRange]
                if digits.count >= incrementLength {
                    return Int(digits)
                }
            }
            return nil
        }

        func formatSeq(_ n: Int) -> String { formatSequence(n, incrementLength: incrementLength) }

        // 3. Occupied (non-source) and vacated (source) numbers
        var occupiedNumbers = Set<Int>()
        var vacatedNumbers = Set<Int>()
        for (upperName, path) in existingFiles {
            guard let number = extractNumber(upperName) else { continue }
            if sourcePaths.contains(realPath(path)) {
                vacatedNumbers.insert(number)
            } else {
                occupiedNumbers.insert(number)
            }
        }
        _ = vacatedNumbers

        // Stem → path map for O(1) pattern conflict checks
        var stemToPath: [String: String] = [:]
        for (upperName, path) in existingFiles {
            stemToPath[(upperName as NSString).deletingPathExtension] = path
        }

        func pathOccupiedByNonSource(_ stem: String) -> Bool {
            guard let path = stemToPath[stem] else { return false }
            return !sourcePaths.contains(realPath(path))
        }

        let totalImages = images.count
        var assignedTargets = Set<String>()
        var assignedNumbers = Set<Int>()
        var mappings: [Mapping] = []
        var effectiveStart = effectiveStartOverride ?? startingNumber
        if appendAfterOccupied, let maxOccupied = occupiedNumbers.max() {
            effectiveStart = max(effectiveStart, maxOccupied + 1)
        }

        // 4. For each file, find next available sequence number (never wrap, never overwrite)
        for (idx, oldPath) in images.enumerated() {
            if idx % 10 == 0 {
                progress?(idx, totalImages, "Calculating names... (\(idx)/\(totalImages))")
            }
            let ext = fileExtension(oldPath)
            var nextSeq: Int?

            // Subset+order: prefer source file's number when available (percolate to top, stay together)
            if preferSourceNumber,
               let srcNum = extractNumber((oldPath as NSString).lastPathComponent),
               srcNum >= effectiveStart {
                if !assignedNumbers.contains(srcNum), !occupiedNumbers.contains(srcNum) {
                    let newBasenameUpper = "\(prefix)-\(formatSeq(srcNum))\(ext)".uppercased()
                    if !assignedTargets.contains(newBasenameUpper) {
                        if let existing = existingFiles[newBasenameUpper] {
                            if sourcePaths.contains(realPath(existing)) {
                                nextSeq = srcNum
                            }
                        } else {
                            nextSeq = srcNum
                        }
                    }
                    if nextSeq != nil {
                        let dash = "\(prefix)-\(formatSeq(srcNum))".uppercased()
                        let noDash = "\(prefix)\(formatSeq(srcNum))".uppercased()
                        if pathOccupiedByNonSource(dash) || pathOccupiedByNonSource(noDash) {
                            nextSeq = nil
                        }
                    }
                }
            }

            if nextSeq == nil {
                var candidate = effectiveStart
                while candidate <= maxSequenceCeiling {
                    if assignedNumbers.contains(candidate) || occupiedNumbers.contains(candidate) {
                        candidate += 1
                        continue
                    }
                    let newBasenameUpper = "\(prefix)-\(formatSeq(candidate))\(ext)".uppercased()
                    if assignedTargets.contains(newBasenameUpper) {
                        candidate += 1
                        continue
                    }
                    if let existing = existingFiles[newBasenameUpper],
                       !sourcePaths.contains(realPath(existing)) {
                        occupiedNumbers.insert(candidate)
                        candidate += 1
                        continue
                    }
                    let dash = "\(prefix)-\(formatSeq(candidate))".uppercased()
                    let noDash = "\(prefix)\(formatSeq(candidate))".uppercased()
                    if pathOccupiedByNonSource(dash) || pathOccupiedByNonSource(noDash) {
                        occupiedNumbers.insert(candidate)
                        candidate += 1
                        continue
                    }
                    nextSeq = candidate
                    break
                }
            }

            guard let seq = nextSeq else {
                throw SequenceOverflowError(message:
                    "Cannot rename files: no available sequence numbers starting from \(effectiveStart).\n\n"
                    + "Rename was aborted to avoid overwriting existing files.\n"
                    + "Please use a different prefix or reduce the number of files.")
            }

            let newFilename = "\(prefix)-\(formatSeq(seq))\(ext)"
            let newPath = (directory as NSString).appendingPathComponent(newFilename)
            mappings.append(Mapping(source: oldPath, target: newPath))
            assignedTargets.insert(newFilename.uppercased())
            assignedNumbers.insert(seq)
        }

        if totalImages > 0 {
            progress?(totalImages, totalImages, "Calculating names... (\(totalImages)/\(totalImages))")
        }
        return mappings
    }

    // MARK: - _build_efficient_rename_plan

    /// Three-phase, order-preserving plan (phase 0 moves conflicting non-source files aside).
    static func buildEfficientRenamePlan(
        mappings: [Mapping],
        directory: String,
        tempPrefix: String,
        progress: ProgressCallback? = nil
    ) -> Plan {
        var phase0: [Mapping] = []
        var phase1: [Mapping] = []
        var phase2: [Mapping] = []
        var nextTempID = 0

        progress?(0, mappings.count, "Scanning directory...")
        let existingFiles = existingFilesMap(in: directory)
        progress?(mappings.count, mappings.count, "Scanning directory...")

        let sourcePaths = Set(mappings.map { realPath($0.source) })

        // Phase 0: existing files (not being renamed) whose name collides with a target
        var seenConflicts = Set<String>()
        for mapping in mappings {
            let targetUpper = (mapping.target as NSString).lastPathComponent.uppercased()
            guard let existing = existingFiles[targetUpper] else { continue }
            let normalized = realPath(existing)
            guard !sourcePaths.contains(normalized) else { continue }
            guard seenConflicts.insert(normalized).inserted else { continue }
            let tempName = "\(tempPrefix)-\(formatSequence(nextTempID, incrementLength: 5))\(fileExtension(existing))"
            nextTempID += 1
            phase0.append(Mapping(source: existing, target: (directory as NSString).appendingPathComponent(tempName)))
        }

        let total = mappings.count
        for (idx, mapping) in mappings.enumerated() {
            if idx % 50 == 0 {
                progress?(idx, total, "Building rename plan... (\(idx)/\(total))")
            }
            if mapping.source == mapping.target { continue }
            let sourceUpper = (mapping.source as NSString).lastPathComponent.uppercased()
            let targetUpper = (mapping.target as NSString).lastPathComponent.uppercased()
            // Skip if filename already matches (case-insensitive)
            if sourceUpper == targetUpper { continue }

            let tempName = "\(tempPrefix)-\(formatSequence(nextTempID, incrementLength: 5))\(fileExtension(mapping.source))"
            let tempPath = (directory as NSString).appendingPathComponent(tempName)
            nextTempID += 1
            phase1.append(Mapping(source: mapping.source, target: tempPath))
            phase2.append(Mapping(source: tempPath, target: mapping.target))
        }
        if total > 0 {
            progress?(total, total, "Building rename plan... (\(total)/\(total))")
        }
        return Plan(phase0: phase0, phase1: phase1, phase2: phase2)
    }

    // MARK: - _minimize_date_changes

    static func currentMtime(_ path: String) -> Int? {
        guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        return Int(date.timeIntervalSince1970)
    }

    /// Minimal set of `(path, newMtime)` changes so that mtimes follow the sequence order.
    static func minimizeDateChanges(
        filesWithIndices: [(path: String, index: Int)],
        mode: DateChangeMode,
        now: Int,
        totalFiles: Int
    ) -> [(path: String, mtime: Int)] {
        guard !filesWithIndices.isEmpty, mode.changesDates else { return [] }

        let sortedFiles = filesWithIndices.sorted { $0.index < $1.index }
        var fileData: [(path: String, current: Int?)] = []
        for entry in sortedFiles {
            if FileManager.default.fileExists(atPath: entry.path) {
                fileData.append((entry.path, currentMtime(entry.path)))
            } else {
                fileData.append((entry.path, nil))
            }
        }

        var changes: [(path: String, mtime: Int)] = []
        var prevDate: Int?
        for (idx, entry) in fileData.enumerated() {
            let targetDate = mode == .oldest ? now - (totalFiles - 1 - idx) : now - idx
            guard let current = entry.current, current <= now else {
                // Unreadable or future dates must be set/clamped
                changes.append((entry.path, targetDate))
                prevDate = targetDate
                continue
            }
            if let prev = prevDate {
                let violates = mode == .oldest
                    ? (current < prev || current > targetDate)
                    : (current > prev || current < targetDate)
                if violates {
                    changes.append((entry.path, targetDate))
                    prevDate = targetDate
                } else {
                    prevDate = current
                }
            } else {
                let keep = mode == .oldest ? current <= targetDate : current >= targetDate
                if keep {
                    prevDate = current
                } else {
                    changes.append((entry.path, targetDate))
                    prevDate = targetDate
                }
            }
        }
        return changes
    }

    /// `os.utime(path, (t, t))`.
    @discardableResult
    static func setModificationTime(_ path: String, to mtime: Int) -> Bool {
        let date = Date(timeIntervalSince1970: TimeInterval(mtime))
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
