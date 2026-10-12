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

    /// Drain late step PNGs after the CLI exits (port of ``flush_stepwise_to_output`` idle passes).
    func flushAndStop() async {
        task?.cancel()
        task = nil
        guard let pattern = stepwisePattern else { return }
        var idlePasses = 0
        while idlePasses < 4 {
            let added = collectStepwiseProgress(pattern: pattern)
            if added > 0 {
                idlePasses = 0
            } else {
                idlePasses += 1
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Port of ``finalize_stepwise_progress`` in ``mflux_stepwise_progress.py`` (after CLI output is promoted).
    func emitFinalStepProgress() {
        guard expectedSteps > 1,
              let progressiveOutputPath,
              !progressiveOutputPath.isEmpty else { return }
        onProgress(stepProgressPayload(path: progressiveOutputPath, step: expectedSteps, total: expectedSteps))
    }

    private var stepwisePattern: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"^seed_(\d+)_step(\d+)of(\d+)\.png$"#, options: .caseInsensitive)
    }

    private func pollLoop() async {
        guard let pattern = stepwisePattern else { return }
        while !Task.isCancelled {
            _ = collectStepwiseProgress(pattern: pattern)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @discardableResult
    private func collectStepwiseProgress(pattern: NSRegularExpression) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stepwiseDir) else { return 0 }
        var added = 0
        for name in entries.sorted() {
            if seen.contains(name) || name.lowercased().contains("composite") { continue }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = pattern.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges >= 4,
                  let stepRange = Range(match.range(at: 2), in: name),
                  let totalRange = Range(match.range(at: 3), in: name),
                  let step = Int(name[stepRange]),
                  let total = Int(name[totalRange]) else {
                continue
            }
            if step > total { continue }
            let path = (stepwiseDir as NSString).appendingPathComponent(name)
            guard pngLooksComplete(path) else { continue }
            seen.insert(name)
            if let progressiveOutputPath, !progressiveOutputPath.isEmpty {
                atomicCopy(from: path, to: progressiveOutputPath)
            }
            let outPath = progressiveOutputPath ?? path
            onProgress(stepProgressPayload(path: outPath, step: step, total: total))
            added += 1
        }
        return added
    }

    private func stepProgressPayload(path: String, step: Int, total: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "progress",
            "path": path,
            "step": step,
            "step_total": total,
        ]
        if let progressiveOutputPath, !progressiveOutputPath.isEmpty {
            payload["progressive_output_path"] = progressiveOutputPath
        }
        return payload
    }

    /// Port of `_png_looks_complete` in `mflux_stepwise_progress.py` (IEND at bytes size-8..size-5).
    private func pngLooksComplete(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size >= 64 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard let head = try? handle.read(upToCount: 8), head == pngMagic else { return false }
        try? handle.seek(toOffset: size - 8)
        guard let tail = try? handle.read(upToCount: 4) else { return false }
        return tail == Data("IEND".utf8)
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
