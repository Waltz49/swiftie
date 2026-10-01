import Foundation

/// Idle background cache warming (Settings → Caches). Written to the ⌃-L session log.
enum BackgroundIdleProcessingLog {
    static func logStart(logFileURL: URL, kind: BackgroundIdleProcessingLogKind) {
        append(logFileURL: logFileURL, "Background - Start  - \(kind.logLabel)")
    }

    static func logFinish(
        logFileURL: URL,
        kind: BackgroundIdleProcessingLogKind,
        newCount: Int,
        batchSize: Int? = nil
    ) {
        let detail = kind.finishDetail(newCount: newCount, batchSize: batchSize)
        append(logFileURL: logFileURL, "Background - Finish - \(kind.logLabel), \(detail)")
    }

    static func logEvent(logFileURL: URL, _ message: String) {
        append(logFileURL: logFileURL, message)
    }

    private static func append(logFileURL: URL, _ message: String) {
        let line = "[\(SessionViewLog.debugTimestamp())] \(message)"
        SessionViewLog.appendLine(line, logFileURL: logFileURL)
    }
}

enum BackgroundIdleProcessingLogKind {
    case thumbnails
    case clip
    case cnn
    case face

    var logLabel: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .clip: return "CLIP image data"
        case .cnn: return "CNN image data"
        case .face: return "Face data"
        }
    }

    fileprivate func finishDetail(newCount: Int, batchSize: Int?) -> String {
        let batchNote = batchSize.map { " (batch \($0))" } ?? ""
        switch self {
        case .thumbnails:
            return "\(newCount) new thumbnails cached\(batchNote)"
        case .face:
            return "\(newCount) images newly face-indexed\(batchNote)"
        case .clip, .cnn:
            return "\(newCount) images newly indexed\(batchNote)"
        }
    }
}
