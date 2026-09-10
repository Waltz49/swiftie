import Foundation

/// Port of `imagegen_plugins/model_task_queue.py` `QueueRowSnapshot`.
struct QueueRowSnapshot: Identifiable {
    let jobID: String
    let isActive: Bool
    var statusHTML: String
    var thumbnailPaths: [String]
    var fullPrompt: String
    var referencesInvalid: Bool
    var statusLabel: String

    var id: String { jobID }

    init(
        jobID: String,
        isActive: Bool,
        statusHTML: String = "",
        thumbnailPaths: [String] = [],
        fullPrompt: String = "",
        referencesInvalid: Bool = false,
        statusLabel: String = ""
    ) {
        self.jobID = jobID
        self.isActive = isActive
        self.statusHTML = statusHTML
        self.thumbnailPaths = thumbnailPaths
        self.fullPrompt = fullPrompt
        self.referencesInvalid = referencesInvalid
        self.statusLabel = statusLabel.isEmpty ? Self.plainText(from: statusHTML) : statusLabel
    }

    static func plainText(from html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
