import Darwin
import Foundation

extension Notification.Name {
    /// Posted on the main queue after a line is appended to the session log file (`userInfo`: `SessionViewLog.appendNotificationURLKey`, `SessionViewLog.appendNotificationTextKey`).
    static let sessionViewLogDidAppend = Notification.Name("prowser.sessionViewLogDidAppend")
}

/// Combined session log under the profile `logs/` directory (View log / LM Studio JSON).
enum SessionViewLog {
    static let appendNotificationURLKey = "url"
    static let appendNotificationTextKey = "text"

    private static let logTag = "imagegen_plugins.lmstudio_caption"
    private static let sessionLogFileName = "image_browser_session"

    @MainActor
    static func logFileURL(config: AppConfig) -> URL {
        config.profilePaths.logsDirectory
            .appendingPathComponent("\(sessionLogFileName)_\(getuid()).log")
    }

    static func install(logFileURL url: URL) {
        prepareEmptyLog(at: url)
    }

    /// Truncate and prepare the session log (primary GUI launch).
    @MainActor
    static func install(config: AppConfig) {
        install(logFileURL: logFileURL(config: config))
    }

    private static let lock = NSLock()

    private static func prepareEmptyLog(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        chmod(url.path, 0o600)
    }

    static func debugTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    static func appendLine(_ text: String, logFileURL url: URL) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        write(line, to: url)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .sessionViewLogDidAppend,
                object: nil,
                userInfo: [
                    appendNotificationURLKey: url,
                    appendNotificationTextKey: line,
                ]
            )
        }
    }

    @MainActor
    static func appendLine(_ text: String, config: AppConfig) {
        appendLine(text, logFileURL: logFileURL(config: config))
    }

    @MainActor
    static func appendTimestampedBlock(header: String, body: String, config: AppConfig) {
        let block = "\(debugTimestamp()) \(header)\n\(body)\n"
        appendLine(block, logFileURL: logFileURL(config: config))
    }

    @MainActor
    static func logModelInput(tag: String, payload: [String: Any], config: AppConfig) {
        guard let json = prettyJSONString(payload) else { return }
        appendTimestampedBlock(header: "\(tag) input", body: relaxJSONForLog(json), config: config)
    }

    @MainActor
    static func logModelOutput(tag: String, text: String, config: AppConfig) {
        guard let json = prettyJSONString(["text": text]) else { return }
        appendTimestampedBlock(header: "\(tag) output", body: relaxJSONForLog(json), config: config)
    }

    @MainActor
    static func logLMStudioCall(method: String, payload: [String: Any], config: AppConfig) {
        let sanitized = sanitizePayloadForLog(payload)
        guard let json = prettyJSONString(sanitized) else { return }
        let ts = debugTimestamp()
        appendLine("\n[\(ts)] \(method)\n\(relaxJSONForLog(json))\n", config: config)
    }

    /// Compact ``GET /v1/models`` and ``GET /api/v1/models`` bodies instead of dumping full catalog JSON.
    @MainActor
    static func logLMStudioHTTPResponse(status: Int, payload: [String: Any], config: AppConfig) {
        let ts = debugTimestamp()
        if let compact = compactModelsListLogLine(payload) {
            appendLine("\n[\(ts)] response HTTP \(status)\n\(compact)\n", config: config)
            return
        }
        logLMStudioCall(method: "response HTTP \(status)", payload: payload, config: config)
    }

    private static func compactModelsListLogLine(_ payload: [String: Any]) -> String? {
        if isOpenAIModelsListResponse(payload) || isNativeModelsListResponse(payload) {
            return "models: { ... }"
        }
        return nil
    }

    private static func isOpenAIModelsListResponse(_ payload: [String: Any]) -> Bool {
        guard payload["object"] as? String == "list",
              let data = payload["data"] as? [[String: Any]] else {
            return false
        }
        if data.isEmpty { return true }
        return data.contains { ($0["object"] as? String) == "model" || $0["id"] != nil }
    }

    private static func isNativeModelsListResponse(_ payload: [String: Any]) -> Bool {
        payload["models"] is [[String: Any]]
    }

    @MainActor
    static func logLMStudioError(_ message: String, detail: String? = nil, config: AppConfig) {
        var body = message
        if let detail, !detail.isEmpty {
            body += "\n\(detail)"
        }
        appendTimestampedBlock(header: "\(logTag) error", body: body, config: config)
    }

    @MainActor
    static func logLMStudioSSELine(_ line: String, config: AppConfig) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return }
        guard shouldLogLMStudioStreamPayload(trimmed) else { return }
        appendTimestampedBlock(header: "\(logTag) stream", body: trimmed, config: config)
    }

    /// Omit streaming `chat.completion.chunk` lines (caption still assembled from them in code).
    private static func shouldLogLMStudioStreamPayload(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if json["object"] as? String == "chat.completion.chunk" {
            return false
        }
        return true
    }

    static func clear(logFileURL url: URL) {
        prepareEmptyLog(at: url)
    }

    @MainActor
    static func clear(config: AppConfig) {
        clear(logFileURL: logFileURL(config: config))
    }

    /// Read appended bytes since `offset`; updates `offset` to the new file length.
    static func readChunk(logFileURL url: URL, offset: inout UInt64) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if offset > size {
            offset = size
        }
        guard offset < size else { return "" }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        return String(data: data, encoding: .utf8) ?? ""
    }

    @MainActor
    static func readChunk(config: AppConfig, offset: inout UInt64) -> String {
        readChunk(logFileURL: logFileURL(config: config), offset: &offset)
    }

    // MARK: - JSON helpers (port of print_call_decorator.relax_json_for_log)

    static func relaxJSONForLog(_ jsonString: String) -> String {
        var output = ""
        output.reserveCapacity(jsonString.count)
        let chars = Array(jsonString)
        var index = 0
        var insideString = false

        let escapeSequences: [Character: Character] = [
            "n": "\n", "r": "\r", "t": "\t", "\"": "\"", "\\": "\\", "/": "/",
            "b": "\u{8}", "f": "\u{c}",
        ]

        while index < chars.count {
            let char = chars[index]
            if !insideString {
                if char == "\"" { insideString = true }
                output.append(char)
                index += 1
            } else {
                if char == "\\", index + 1 < chars.count {
                    let esc = chars[index + 1]
                    if let mapped = escapeSequences[esc] {
                        output.append(mapped)
                        index += 2
                    } else if esc == "u", index + 5 < chars.count {
                        let hex = String(chars[(index + 2)...(index + 5)])
                        if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                            output.append(Character(scalar))
                            index += 6
                        } else {
                            output.append(char)
                            index += 1
                        }
                    } else {
                        output.append(char)
                        index += 1
                    }
                } else if char == "\"" {
                    insideString = false
                    output.append(char)
                    index += 1
                } else {
                    output.append(char)
                    index += 1
                }
            }
        }
        return output
    }

    static func sanitizePayloadForLog(_ payload: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in payload {
            out[key] = sanitizeValueForLog(value)
        }
        return out
    }

    private static func sanitizeValueForLog(_ value: Any) -> Any {
        if let str = value as? String {
            return sanitizeStringForLog(str)
        }
        if let dict = value as? [String: Any] {
            return sanitizePayloadForLog(dict)
        }
        if let array = value as? [Any] {
            return array.map { sanitizeValueForLog($0) }
        }
        return value
    }

    static func sanitizeStringForLog(_ text: String) -> String {
        guard text.lowercased().contains("base64,") else { return text }
        let pattern = #"data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return shortenInlineBase64(text)
        }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, options: [], range: range).reversed()
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let matched = String(text[swiftRange])
            let mime = matched.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "data:image"
            let base64Part = matched.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let replacement = "<base64:\(mime); \(base64Part.count) chars>"
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }

    private static func shortenInlineBase64(_ text: String) -> String {
        if text.count > 200, text.contains("base64,") {
            return String(text.prefix(120)) + "…<\(text.count) chars>"
        }
        return text
    }

    private static func prettyJSONString(_ object: Any) -> String? {
        let sanitized = sanitizeValueForLog(object)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func write(_ text: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = text.data(using: .utf8) else { return }
        _ = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var ok = true
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    ok = false
                    return
                }
                var remaining = raw.count
                var pointer = base
                while remaining > 0 {
                    let n = Darwin.write(fd, pointer, remaining)
                    if n <= 0 {
                        ok = false
                        break
                    }
                    remaining -= n
                    pointer = pointer.advanced(by: n)
                }
            }
            _ = fsync(fd)
            return ok
        }
    }
}
