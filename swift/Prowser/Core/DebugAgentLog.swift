import Foundation

// #region agent log
enum DebugAgentLog {
    private static let logPath = "/Users/douglasnadel/dev/swiftie/.cursor/debug-655bb0.log"

    static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: CustomStringConvertible] = [:]
    ) {
        var payload: [String: Any] = [
            "sessionId": "655bb0",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if !data.isEmpty {
            payload["data"] = data.mapValues(\.description)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: jsonData, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? (line + "\n").write(to: url, atomically: false, encoding: .utf8)
        }
    }
}
// #endregion