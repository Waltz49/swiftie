import Foundation

/// Structured status views for job cards and the active-job progress strip.
/// Port of `imagegen_plugins/job_status_views.py`.

enum QueueStatusRowKind {
    case title(String, running: Bool)
    case labelValue(label: String, value: String)
    case prompt(label: String, value: String)
    case inline(label: String, primaryValue: String, inlineParts: [(String, String)])
    case unavailable(heading: String, copiesLine: String, promptLine: String)
    case banner(String)
}

struct QueueJobStatusView {
    var rows: [QueueStatusRowKind]
    var cooldownRemaining: Int?
    var showSkipCooldown: Bool
    var running: Bool

    init(
        rows: [QueueStatusRowKind] = [],
        cooldownRemaining: Int? = nil,
        showSkipCooldown: Bool = false,
        running: Bool = false
    ) {
        self.rows = rows
        self.cooldownRemaining = cooldownRemaining
        self.showSkipCooldown = showSkipCooldown
        self.running = running
    }

    var isEmpty: Bool { rows.isEmpty }

    func fingerprint() -> String {
        var parts: [String] = []
        for row in rows {
            switch row {
            case .title(let title, let running):
                parts.append("title:\(title):\(running)")
            case .labelValue(let label, let value):
                parts.append("lv:\(label):\(value)")
            case .prompt(let label, let value):
                parts.append("prompt:\(label):\(value)")
            case .inline(let label, let primary, let inlineParts):
                let inlineKey = inlineParts.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
                parts.append("inline:\(label):\(primary):\(inlineKey)")
            case .unavailable(let heading, let copies, let prompt):
                parts.append("unavail:\(heading):\(copies):\(prompt)")
            case .banner(let text):
                parts.append("banner:\(text)")
            }
        }
        parts.append("r:\(running)")
        parts.append("skip:\(showSkipCooldown)")
        return parts.joined(separator: ";")
    }

    static func fromBridgeDictionary(_ dict: [String: Any]) -> QueueJobStatusView {
        let rowDicts = dict["rows"] as? [[String: Any]] ?? []
        let rows = rowDicts.compactMap { rowDict -> QueueStatusRowKind? in
            let type = rowDict["type"] as? String ?? ""
            switch type {
            case "title":
                return .title(
                    rowDict["title"] as? String ?? "",
                    running: rowDict["running"] as? Bool ?? false
                )
            case "label_value":
                return .labelValue(
                    label: rowDict["label"] as? String ?? "",
                    value: rowDict["value"] as? String ?? ""
                )
            case "prompt":
                return .prompt(
                    label: rowDict["label"] as? String ?? "",
                    value: rowDict["value"] as? String ?? ""
                )
            case "inline":
                let parts = (rowDict["inline_parts"] as? [[String: Any]] ?? []).compactMap { part -> (String, String)? in
                    guard let label = part["label"] as? String,
                          let value = part["value"] as? String else { return nil }
                    return (label, value)
                }
                return .inline(
                    label: rowDict["label"] as? String ?? "",
                    primaryValue: rowDict["primary_value"] as? String ?? "",
                    inlineParts: parts
                )
            case "unavailable":
                return .unavailable(
                    heading: rowDict["heading"] as? String ?? "",
                    copiesLine: rowDict["copies_line"] as? String ?? "",
                    promptLine: rowDict["prompt_line"] as? String ?? ""
                )
            case "banner":
                return .banner(rowDict["text"] as? String ?? "")
            default:
                return nil
            }
        }
        return QueueJobStatusView(
            rows: rows,
            cooldownRemaining: dict["cooldown_remaining"] as? Int,
            showSkipCooldown: dict["show_skip_cooldown"] as? Bool ?? false,
            running: dict["running"] as? Bool ?? false
        )
    }

    /// Degraded fallback when the registry bridge is unavailable.
    static func degradedFallback(prompt: String, copiesTotal: Int) -> QueueJobStatusView {
        var rows: [QueueStatusRowKind] = [.title("Generate from text", running: false)]
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            rows.append(.prompt(label: "Prompt:", value: trimmed))
        }
        if copiesTotal > 1 {
            rows.append(.labelValue(label: "Copies:", value: "\(copiesTotal) images."))
        }
        return QueueJobStatusView(rows: rows)
    }
}

enum ActiveJobStripRowKind: Equatable {
    case bar(
        label: String,
        prefix: String,
        postfix: String,
        fillPercent: Int,
        slotText: String,
        showPendingStart: Bool
    )
    case count(label: String, count: String)
}

struct ActiveJobStripStatusView: Equatable {
    var rows: [ActiveJobStripRowKind]
    var mode: String
    var cooldownText: String
    var cooldownCountText: String
    var showSkipIcon: Bool
    var showCancelIcon: Bool

    init(
        rows: [ActiveJobStripRowKind] = [],
        mode: String = "",
        cooldownText: String = "",
        cooldownCountText: String = "",
        showSkipIcon: Bool = false,
        showCancelIcon: Bool = false
    ) {
        self.rows = rows
        self.mode = mode
        self.cooldownText = cooldownText
        self.cooldownCountText = cooldownCountText
        self.showSkipIcon = showSkipIcon
        self.showCancelIcon = showCancelIcon
    }

    var isEmpty: Bool { rows.isEmpty && cooldownText.isEmpty }

    /// Row layout identity only (live prefix/fill/slot values update in place).
    func structureKey() -> String {
        let rowKeys = rows.map { row -> String in
            switch row {
            case .bar(let label, _, _, _, _, _):
                return "bar:\(label)"
            case .count(let label, _):
                return "count:\(label)"
            }
        }
        return ([
            rowKeys.joined(separator: ";"),
            "mode:\(mode)",
            "skip:\(showSkipIcon)",
            "cancel:\(showCancelIcon)",
            "cooldown:\(!cooldownText.isEmpty)",
        ] as [String]).joined(separator: "|")
    }

    func fingerprint() -> String {
        var parts = rows.map { row -> String in
            switch row {
            case .bar(let label, let prefix, let postfix, let fillPercent, let slot, let showPending):
                return "bar:\(label):\(prefix):\(postfix):\(fillPercent):\(slot):\(showPending)"
            case .count(let label, let count):
                return "count:\(label):\(count)"
            }
        }
        parts.append("mode:\(mode)")
        parts.append("skip:\(showSkipIcon)")
        parts.append("cancel:\(showCancelIcon)")
        return parts.joined(separator: ";")
    }

    static func fromBridgeDictionary(_ dict: [String: Any]) -> ActiveJobStripStatusView {
        let rowDicts = dict["rows"] as? [[String: Any]] ?? []
        let rows = rowDicts.compactMap { rowDict -> ActiveJobStripRowKind? in
            let type = rowDict["type"] as? String ?? ""
            switch type {
            case "bar":
                return .bar(
                    label: rowDict["label"] as? String ?? "",
                    prefix: rowDict["prefix"] as? String ?? "",
                    postfix: rowDict["postfix"] as? String ?? "",
                    fillPercent: rowDict["fill_percent"] as? Int ?? 0,
                    slotText: rowDict["slot_text"] as? String ?? "",
                    showPendingStart: rowDict["show_pending_start"] as? Bool ?? false
                )
            case "count":
                return .count(
                    label: rowDict["label"] as? String ?? "",
                    count: rowDict["count"] as? String ?? ""
                )
            default:
                return nil
            }
        }
        return ActiveJobStripStatusView(
            rows: rows,
            mode: dict["mode"] as? String ?? "",
            cooldownText: dict["cooldown_text"] as? String ?? "",
            cooldownCountText: dict["cooldown_count_text"] as? String ?? "",
            showSkipIcon: dict["show_skip_icon"] as? Bool ?? false,
            showCancelIcon: dict["show_cancel_icon"] as? Bool ?? false
        )
    }
}

enum JobQueueLayout {
    static let labelWidth: CGFloat = 52
    static let fontSize: CGFloat = 12
    static let thumbSize: CGFloat = 55
    static let thumbGap: CGFloat = 14
    static let cardCornerRadius: CGFloat = 4
    static let cardOuterMargin: CGFloat = 2
    static let cardContentMargin: CGFloat = 12
    static let cardInnerSpacing: CGFloat = 2
    static let listSpacing: CGFloat = 8
    static let inlineRefsMinScrollWidth: CGFloat = 350
    static let inlineRefsRightPadding: CGFloat = 2
    static let inlineTextRefsSpacing: CGFloat = 4
    static let promptMaxLines = 2
    static let promptMarginPx: CGFloat = 4
    static let inlineGapPx: CGFloat = 3
    static let actionBarHeight: CGFloat = 28
    static let actionButtonSize: CGFloat = 22
    static let stripBarHeight: CGFloat = 10
    static let stripBarMinWidth: CGFloat = 48
    static let progressBarFillHex = "#3478F6"
    static let paneFitBottomSlack: CGFloat = 5
}
