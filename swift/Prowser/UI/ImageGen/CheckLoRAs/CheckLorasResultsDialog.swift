import Foundation

enum CheckLorasResultsDialog {
    static func resolvedBody(resultsText: String, reportPaths: [String]) -> String {
        let trimmed = resultsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return resultsText
        }
        for path in reportPaths {
            let url = URL(fileURLWithPath: path)
            if let file = try? String(contentsOf: url, encoding: .utf8),
               !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return file
            }
        }
        if !reportPaths.isEmpty {
            return "Report file(s):\n" + reportPaths.map { "  \($0)" }.joined(separator: "\n")
        }
        return "Check LoRAs finished, but no results summary was returned."
    }
}
