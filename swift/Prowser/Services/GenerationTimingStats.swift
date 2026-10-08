import Foundation

struct GenerationTimingRow: Identifiable, Hashable {
    let modelID: String
    let modelName: String
    let size: String
    let width: Int
    let height: Int
    let steps: Int
    let quant: String
    let runCount: Int
    let totalSeconds: Double
    let avgSeconds: Double

    var id: String {
        "\(modelID)|\(steps)|\(width)|\(height)|\(quant)"
    }

    var areaSortValue: Double { Double(width * height) }
}

/// Port of ``imagegen_plugins/generation_timing_stats.py`` (JSON store in profile data dir).
struct GenerationTimingKey: Equatable, Hashable {
    let modelID: String
    let steps: Int
    let width: Int
    let height: Int
    let quant: String

    init(modelID: String, steps: Int, width: Int, height: Int, quant: String) {
        self.modelID = modelID
        self.steps = steps
        self.width = width
        self.height = height
        self.quant = quant
    }

    init?(bridgeArray: [Any]) {
        guard bridgeArray.count >= 5 else { return nil }
        guard let modelID = bridgeArray[0] as? String, !modelID.isEmpty else { return nil }
        guard let steps = Self.intValue(bridgeArray[1]), steps >= 0 else { return nil }
        guard let width = Self.intValue(bridgeArray[2]), width > 0 else { return nil }
        guard let height = Self.intValue(bridgeArray[3]), height > 0 else { return nil }
        self.modelID = modelID
        self.steps = steps
        self.width = width
        self.height = height
        self.quant = bridgeArray[4] as? String ?? ""
    }

    private static func intValue(_ value: Any) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let intValue = Int(string) { return intValue }
        return nil
    }
}

enum GenerationTimingStats {
    private static let maxEntries = 3000
    private static let fileVersion = 3
    private static let areaK = 1000.0

    private struct Entry {
        var totalSeconds: Double
        var runCount: Int

        var averageSeconds: Double {
            guard runCount > 0 else { return 0 }
            return totalSeconds / Double(runCount)
        }
    }

    static func statsFileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("generation_timing_stats.json")
    }

    static func lookupAverage(key: GenerationTimingKey, dataDirectory: URL) -> Double? {
        let store = orderedEntries(from: dataDirectory)
        guard let entry = store.first(where: { $0.0 == key })?.1,
              entry.runCount > 0, entry.totalSeconds > 0 else { return nil }
        return entry.averageSeconds
    }

    static func recordRun(key: GenerationTimingKey, elapsedSeconds: Double, dataDirectory: URL) {
        guard elapsedSeconds > 0 else { return }
        var store = orderedEntries(from: dataDirectory)
        if let index = store.firstIndex(where: { $0.0 == key }) {
            var entry = store[index].1
            entry.totalSeconds += elapsedSeconds
            entry.runCount += 1
            store[index].1 = entry
        } else {
            store.append((key, Entry(totalSeconds: elapsedSeconds, runCount: 1)))
        }
        trimStore(&store)
        saveStore(store, dataDirectory: dataDirectory)
    }

    static func listTimingRows(
        dataDirectory: URL,
        modelDisplayNames: [String: String] = [:]
    ) -> [GenerationTimingRow] {
        orderedEntries(from: dataDirectory).reversed().compactMap { key, entry in
            guard entry.runCount > 0, entry.totalSeconds > 0 else { return nil }
            return GenerationTimingRow(
                modelID: key.modelID,
                modelName: modelDisplayName(for: key.modelID, names: modelDisplayNames),
                size: "\(key.width) x \(key.height)",
                width: key.width,
                height: key.height,
                steps: key.steps,
                quant: key.quant,
                runCount: entry.runCount,
                totalSeconds: entry.totalSeconds,
                avgSeconds: entry.averageSeconds
            )
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func formatAreaK(width: Int, height: Int) -> String {
        String(format: "%.1fK", Double(width * height) / areaK)
    }

    private static func modelDisplayName(for modelID: String, names: [String: String]) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let name = names[trimmed], !name.isEmpty { return name }
        if trimmed.contains("/") {
            return trimmed.split(separator: "/").last?
                .replacingOccurrences(of: "_", with: " ") ?? trimmed
        }
        return trimmed
    }

    private static func orderedEntries(from dataDirectory: URL) -> [(GenerationTimingKey, Entry)] {
        let url = statsFileURL(dataDirectory: dataDirectory)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["entries"] as? [[String: Any]] else {
            return []
        }
        var entries: [(GenerationTimingKey, Entry)] = []
        for item in items {
            guard let modelID = item["model_id"] as? String,
                  let steps = item["steps"] as? Int ?? (item["steps"] as? NSNumber)?.intValue,
                  let width = item["width"] as? Int ?? (item["width"] as? NSNumber)?.intValue,
                  let height = item["height"] as? Int ?? (item["height"] as? NSNumber)?.intValue else {
                continue
            }
            guard width > 0, height > 0, !modelID.isEmpty else { continue }
            let quant = item["quant"] as? String ?? ""
            guard let totalSeconds = item["total_seconds"] as? Double
                    ?? (item["total_seconds"] as? NSNumber)?.doubleValue,
                  let runCount = item["run_count"] as? Int
                    ?? (item["run_count"] as? NSNumber)?.intValue,
                  totalSeconds > 0, runCount > 0 else {
                continue
            }
            let key = GenerationTimingKey(
                bridgeArray: [modelID, steps, width, height, quant]
            )
            guard let key else { continue }
            entries.append((key, Entry(totalSeconds: totalSeconds, runCount: runCount)))
        }
        return entries
    }

    private static func saveStore(_ store: [(GenerationTimingKey, Entry)], dataDirectory: URL) {
        let url = statsFileURL(dataDirectory: dataDirectory)
        let entries: [[String: Any]] = store.map { key, entry in
            [
                "model_id": key.modelID,
                "steps": key.steps,
                "width": key.width,
                "height": key.height,
                "quant": key.quant,
                "total_seconds": entry.totalSeconds,
                "run_count": entry.runCount,
            ]
        }
        let payload: [String: Any] = [
            "version": fileVersion,
            "entries": entries,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func trimStore(_ store: inout [(GenerationTimingKey, Entry)]) {
        while store.count > maxEntries {
            store.removeFirst()
        }
    }
}
