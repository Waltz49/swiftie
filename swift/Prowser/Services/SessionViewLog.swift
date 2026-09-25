import Darwin
import Foundation

/// Combined session log under the configured temporary files directory (View log / LM Studio JSON).
@MainActor
enum SessionViewLog {
    private static let lock = NSLock()
    private static let logTag = "imagegen_plugins.lmstudio_caption"

    static func logFileURL(config: AppConfig) -> URL {
        config.temporaryFilesDirectory.appendingPathComponent("image_browser_session_\(getuid()).log")
    }

    /// Truncate and prepare the session log (primary GUI launch).
    static func install(config: AppConfig) {
        let url = logFileURL(config: config)
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

    static func appendLine(_ text: String, config: AppConfig) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        write(line, config: config)
    }

    static func appendTimestampedBlock(header: String, body: String, config: AppConfig) {
        let block = "\(debugTimestamp()) \(header)\n\(body)\n"
        write(block, config: config)
    }

    static func logModelInput(tag: String, payload: [String: Any], config: AppConfig) {
        guard let json = prettyJSONString(payload) else { return }
        appendTimestampedBlock(header: "\(tag) input", body: relaxJSONForLog(json), config: config)
    }

    static func logModelOutput(tag: String, text: String, config: AppConfig) {
        guard let json = prettyJSONString(["text": text]) else { return }
        appendTimestampedBlock(header: "\(tag) output", body: relaxJSONForLog(json), config: config)
    }

    static func logLMStudioCall(method: String, payload: [String: Any], config: AppConfig) {
        let sanitized = sanitizePayloadForLog(payload)
        guard let json = prettyJSONString(sanitized) else { return }
        let ts = debugTimestamp()
        appendLine("\n[\(ts)] \(method)\n\(relaxJSONForLog(json))\n", config: config)
    }

    static func logLMStudioError(_ message: String, detail: String? = nil, config: AppConfig) {
        var body = message
        if let detail, !detail.isEmpty {
            body += "\n\(detail)"
        }
        appendTimestampedBlock(header: "\(logTag) error", body: body, config: config)
    }

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

    static func clear(config: AppConfig) {
        let url = logFileURL(config: config)
        lock.lock()
        defer { lock.unlock() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        chmod(url.path, 0o600)
    }

    /// Read appended bytes since `offset`; updates `offset` to the new file length.
    static func readChunk(config: AppConfig, offset: inout UInt64) -> String {
        let url = logFileURL(config: config)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard offset < size else { return "" }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        return String(data: data, encoding: .utf8) ?? ""
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

    private static func write(_ text: String, config: AppConfig) {
        let url = logFileURL(config: config)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            chmod(url.path, 0o600)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
