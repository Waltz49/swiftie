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
        appendImageGenLine("[imagegen] \(line)")
    }

    static func appendWorkerLine(_ text: String) {
        appendImageGenLine(text)
    }

    private static func appendImageGenLine(_ message: String) {
        lock.lock()
        let url = sessionLogFileURL
        lock.unlock()
        guard let url else { return }
        SessionViewLog.appendLine(message, logFileURL: url)
    }

    static func printPythonModuleInvocation(executablePath: String, module: String) {
        printInvocation(executablePath: executablePath, arguments: PythonLocator.moduleArguments(module))
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
