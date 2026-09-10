import Foundation

/// Port of `imagegen_plugins/model_task_queue.py` `QueueRowSnapshot`.
struct QueueRowSnapshot: Identifiable {
    let jobID: String
    let isActive: Bool
    var statusHTML: String
    var statusView: QueueJobStatusView?
    var thumbnailPaths: [String]
    var fullPrompt: String
    var referencesInvalid: Bool
    var pluginUnavailable: Bool
    var statusLabel: String
    var copiesTotal: Int

    var id: String { jobID }

    init(
        jobID: String,
        isActive: Bool,
        statusHTML: String = "",
        statusView: QueueJobStatusView? = nil,
        thumbnailPaths: [String] = [],
        fullPrompt: String = "",
        referencesInvalid: Bool = false,
        pluginUnavailable: Bool = false,
        statusLabel: String = "",
        copiesTotal: Int = 1
    ) {
        self.jobID = jobID
        self.isActive = isActive
        self.statusHTML = statusHTML
        self.statusView = statusView
        self.thumbnailPaths = thumbnailPaths
        self.fullPrompt = fullPrompt
        self.referencesInvalid = referencesInvalid
        self.pluginUnavailable = pluginUnavailable
        self.statusLabel = statusLabel.isEmpty ? Self.plainText(from: statusHTML) : statusLabel
        self.copiesTotal = copiesTotal
    }

    static func plainText(from html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
