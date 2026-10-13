import Foundation

/// Monotonic job numbers (J0001–J9999) in imagegen settings (Python ``job_number.py``).
enum ImageGenJobNumber {
    static let jobNumberMax = 9999
    private static let settingsKey = "next_job_number"

    static func format(_ n: Int) -> String {
        String(format: "J%04d", n)
    }

    static func cancelConfirmMessage(isActive: Bool, jobNumber: Int?) -> String {
        if let jobNumber {
            let label = format(jobNumber)
            if isActive {
                return "Do you want to cancel job \(label)?"
            }
            return "Do you want to delete job \(label)?"
        }
        if isActive {
            return "Cancel the running job?"
        }
        return "Remove this job from the queue?"
    }

    private static func clamp(_ n: Int) -> Int {
        Swift.max(1, Swift.min(jobNumberMax, n))
    }

    static func nextAfter(_ n: Int) -> Int {
        let c = clamp(n)
        return c >= jobNumberMax ? 1 : c + 1
    }

    @MainActor
    static func loadNext(config: AppConfig) -> Int {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        let raw = imagegen[settingsKey]
        let n = (raw as? Int) ?? Int("\(raw ?? "")") ?? 1
        return clamp(n)
    }

    @MainActor
    static func saveNext(_ n: Int, config: AppConfig) {
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen[settingsKey] = clamp(n)
        config.updateSetting("imagegen", value: imagegen)
    }

    @MainActor
    static func allocate(config: AppConfig) -> Int {
        let assigned = loadNext(config: config)
        saveNext(nextAfter(assigned), config: config)
        return assigned
    }

    static func parse(from document: [String: Any]) -> Int? {
        guard let raw = document["job_number"] else { return nil }
        let n = (raw as? Int) ?? Int("\(raw)") ?? 0
        guard (1...jobNumberMax).contains(n) else { return nil }
        return n
    }

    @MainActor
    static func reconcile(knownNumbers: [Int], config: AppConfig) {
        let nums = knownNumbers.filter { (1...jobNumberMax).contains($0) }
        guard let highest = nums.max() else { return }
        let need = nextAfter(highest)
        let stored = loadNext(config: config)
        if stored <= highest || (highest >= jobNumberMax && stored != need) {
            saveNext(need, config: config)
        }
    }
}
