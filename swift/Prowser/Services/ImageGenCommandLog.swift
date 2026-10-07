import Foundation

/// Prints image-generation subprocess invocations to the console (parity with Python worker logging).
enum ImageGenCommandLog {
    static func printInvocation(executablePath: String, arguments: [String]) {
        let line = ([executablePath] + arguments).map(shellQuote).joined(separator: " ")
        print("[imagegen] \(line)")
        fflush(stdout)
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
