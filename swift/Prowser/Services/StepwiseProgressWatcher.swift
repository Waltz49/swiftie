import Foundation

/// Watches MFLUX stepwise PNG output (port of `mflux_stepwise_progress.py`).
@MainActor
final class StepwiseProgressWatcher {
    private var task: Task<Void, Never>?
    private let stepwiseDir: String
    private let progressiveOutputPath: String?
    private let expectedSteps: Int
    private let onProgress: ([String: Any]) -> Void
    private var seen: Set<String> = []

    init(
        stepwiseDir: String,
        progressiveOutputPath: String?,
        expectedSteps: Int,
        onProgress: @escaping ([String: Any]) -> Void
    ) {
        self.stepwiseDir = stepwiseDir
        self.progressiveOutputPath = progressiveOutputPath
        self.expectedSteps = max(1, expectedSteps)
        self.onProgress = onProgress
    }

    func start() {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pollLoop() async {
        let pattern = try? NSRegularExpression(pattern: #"^seed_(\d+)_step(\d+)of(\d+)\.png$"#, options: .caseInsensitive)
        while !Task.isCancelled {
            if let pattern {
                scanDirectory(pattern: pattern)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func scanDirectory(pattern: NSRegularExpression) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stepwiseDir) else { return }
        for name in entries.sorted() {
            let path = (stepwiseDir as NSString).appendingPathComponent(name)
            if seen.contains(path) { continue }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = pattern.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges >= 4,
                  let stepRange = Range(match.range(at: 2), in: name),
                  let totalRange = Range(match.range(at: 3), in: name),
                  let step = Int(name[stepRange]),
                  let total = Int(name[totalRange]) else {
                continue
            }
            guard pngLooksComplete(path) else { continue }
            seen.insert(path)
            if let progressiveOutputPath, !progressiveOutputPath.isEmpty {
                atomicCopy(from: path, to: progressiveOutputPath)
            }
            onProgress([
                "type": "progress",
                "path": progressiveOutputPath ?? path,
                "step": step,
                "step_total": total,
            ])
        }
    }

    private func pngLooksComplete(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
              data.count >= 64 else { return false }
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.prefix(8).elementsEqual(pngMagic) == false { return false }
        return data.suffix(8).elementsEqual([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    }

    private func atomicCopy(from src: String, to dst: String) {
        let dstURL = URL(fileURLWithPath: dst)
        let dir = dstURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".imagegen-progress-\(UUID().uuidString).png")
        do {
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: tmp)
            if FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.moveItem(at: tmp, to: dstURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
