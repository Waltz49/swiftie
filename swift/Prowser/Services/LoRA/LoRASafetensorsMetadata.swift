import Foundation

enum LoRASafetensorsMetadata {
    private static let triggerKeys = [
        "trigger_word",
        "activation_text",
        "ss_trigger_words",
        "trained_words",
        "modelspec.trigger_word",
    ]

    static func triggerWord(fromFile path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        guard url.pathExtension.lowercased() == "safetensors" else { return nil }
        guard let metadata = readMetadataDictionary(url: url) else { return nil }
        for key in triggerKeys {
            if let value = metadata[key] {
                if let cleaned = cleanTrigger(String(describing: value)) {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func readMetadataDictionary(url: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return nil }
        let headerSize = lengthData.withUnsafeBytes { ptr in
            UInt64(littleEndian: ptr.load(as: UInt64.self))
        }
        guard headerSize > 0, headerSize < 100_000_000 else { return nil }
        guard let headerData = try? handle.read(upToCount: Int(headerSize)),
              headerData.count == Int(headerSize)
        else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return nil
        }
        guard let meta = json["__metadata__"] as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in meta {
            out[key] = String(describing: value)
        }
        return out
    }

    private static func cleanTrigger(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let lowered = value.lowercased()
        if value.isEmpty || lowered == "none" || lowered == "n/a" || lowered == "null" {
            return nil
        }
        if value.count > 120 {
            value = String(value.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
