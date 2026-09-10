import Foundation

/// Suggested filename-prefix filters for an empty filtered directory. Port of `utils.determine_suggested_filters`.
enum SuggestedFiltersService {
    static func determineSuggestedFilters(filenames: [String]) -> [String] {
        guard !filenames.isEmpty else { return [] }

        var prefixToFiles: [String: Set<String>] = [:]
        for filename in filenames {
            for length in 1...filename.count {
                let prefix = String(filename.prefix(length))
                prefixToFiles[prefix, default: []].insert(filename)
            }
        }

        var filesetToPrefix: [Set<String>: String] = [:]
        for (prefix, matched) in prefixToFiles where matched.count > 1 {
            let key = matched
            if let existing = filesetToPrefix[key] {
                if prefix.count > existing.count {
                    filesetToPrefix[key] = prefix
                }
            } else {
                filesetToPrefix[key] = prefix
            }
        }

        var candidates: [(prefix: String, files: Set<String>)] = filesetToPrefix.map { ($1, $0) }
        candidates.sort { lhs, rhs in
            if lhs.files.count != rhs.files.count { return lhs.files.count > rhs.files.count }
            if lhs.prefix.count != rhs.prefix.count { return lhs.prefix.count > rhs.prefix.count }
            return lhs.prefix < rhs.prefix
        }

        var selected: [(String, Int)] = []
        var matchedFilesCovered = Set<String>()
        for candidate in candidates {
            if candidate.files.isDisjoint(with: matchedFilesCovered) {
                selected.append((candidate.prefix, candidate.files.count))
                matchedFilesCovered.formUnion(candidate.files)
            }
            if selected.count == 5 { break }
        }

        var cleanedPrefixes: [String] = []
        var cleanedSet = Set<String>()
        for (prefix, _) in selected {
            let stripped = prefix.trimmingCharacters(in: CharacterSet.decimalDigits)
            if !stripped.isEmpty, stripped != prefix, !cleanedSet.contains(stripped) {
                cleanedPrefixes.append(stripped)
                cleanedSet.insert(stripped)
            } else if !cleanedSet.contains(prefix) {
                cleanedPrefixes.append(prefix)
                cleanedSet.insert(prefix)
            }
        }
        return cleanedPrefixes
    }
}
