import Foundation

/// Image-generation subprocess invocations (Tools → Debug → View log, ⌃-L).
enum ImageGenCommandLog {
    private static let lock = NSLock()
    private static var sessionLogFileURL: URL?

    static func bindSessionLog(logFileURL: URL) {
        lock.lock()
        sessionLogFileURL = logFileURL
        lock.unlock()
    }

    static func printInvocation(executablePath: String, arguments: [String]) {
        let line = ([executablePath] + arguments).map(shellQuote).joined(separator: " ")
        let message = "[imagegen] \(line)"
        lock.lock()
        let url = sessionLogFileURL
        lock.unlock()
        guard let url else { return }
        SessionViewLog.appendLine(message, logFileURL: url)
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = #"^[A-Za-z0-9_./:=@%+,~-]+$"#
        if value.range(of: safe, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
