import Foundation

/// Atomic JSON persistence for image generation jobs (`imagegen_plugins/job_step_persistence.py`).
@MainActor
enum JobStepPersistence {
    private static let queueVersion = 1

    static func prowserHome(config: AppConfig) -> URL {
        config.prowserHome
    }

    static func jobQueueURL(config: AppConfig) -> URL {
        prowserHome(config: config).appendingPathComponent("job_queue.json")
    }

    static func jobActiveRunningURL(config: AppConfig) -> URL {
        prowserHome(config: config).appendingPathComponent("job_active_running.json")
    }

    static func jobActivePendingURL(config: AppConfig) -> URL {
        prowserHome(config: config).appendingPathComponent("job_active_pending.json")
    }

    static func loadQueue(config: AppConfig) -> ImageGenQueueFile {
        guard let data = try? Data(contentsOf: jobQueueURL(config: config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ImageGenQueueFile()
        }
        let jobs = (json["jobs"] as? [[String: Any]])?.map { ImageGenQueuedJob(document: $0) } ?? []
        let index = json["active_display_index"] as? Int ?? 0
        return ImageGenQueueFile(jobs: jobs, activeDisplayIndex: max(0, index))
    }

    static func saveQueue(_ file: ImageGenQueueFile, config: AppConfig) {
        let payload: [String: Any] = [
            "version": queueVersion,
            "jobs": file.jobs.map { $0.document },
            "active_display_index": file.activeDisplayIndex,
        ]
        atomicWriteJSON(payload, to: jobQueueURL(config: config))
    }

    static func loadActiveRunning(config: AppConfig) -> [String: Any]? {
        readJSONDictionary(jobActiveRunningURL(config: config))
    }

    static func saveActiveRunning(_ doc: [String: Any]?, config: AppConfig) {
        if let doc {
            atomicWriteJSON(doc, to: jobActiveRunningURL(config: config))
        } else {
            try? FileManager.default.removeItem(at: jobActiveRunningURL(config: config))
        }
    }

    private static func readJSONDictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func atomicWriteJSON(_ payload: Any, to url: URL) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

struct ImageGenQueueFile {
    var jobs: [ImageGenQueuedJob]
    var activeDisplayIndex: Int

    init(jobs: [ImageGenQueuedJob] = [], activeDisplayIndex: Int = 0) {
        self.jobs = jobs
        self.activeDisplayIndex = activeDisplayIndex
    }
}

struct ImageGenQueuedJob: Identifiable {
    let jobID: String
    var pluginID: String
    var function: String
    var values: [String: Any]
    var copiesTotal: Int
    var statusLabel: String
    var fullPrompt: String

    var id: String { jobID }

    init(
        jobID: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int = 1,
        statusLabel: String = "Queued",
        fullPrompt: String = ""
    ) {
        self.jobID = jobID
        self.pluginID = pluginID
        self.function = function
        self.values = values
        self.copiesTotal = copiesTotal
        self.statusLabel = statusLabel
        self.fullPrompt = fullPrompt.isEmpty ? (values["prompt"] as? String ?? "") : fullPrompt
    }

    init(document: [String: Any]) {
        jobID = document["job_id"] as? String ?? UUID().uuidString
        pluginID = document["plugin_id"] as? String ?? ""
        function = document["function"] as? String ?? "create"
        values = document["values"] as? [String: Any] ?? [:]
        copiesTotal = document["copies_total"] as? Int ?? 1
        statusLabel = document["status_html"] as? String ?? "Queued"
        fullPrompt = document["full_prompt"] as? String ?? (values["prompt"] as? String ?? "")
    }

    var document: [String: Any] {
        [
            "job_id": jobID,
            "plugin_id": pluginID,
            "function": function,
            "values": values,
            "copies_total": copiesTotal,
            "status_html": statusLabel,
            "full_prompt": fullPrompt,
        ]
    }
}
