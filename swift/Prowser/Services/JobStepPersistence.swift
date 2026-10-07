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

    static func loadActivePending(config: AppConfig) -> [String: Any]? {
        readJSONDictionary(jobActivePendingURL(config: config))
    }

    static func saveActivePending(_ doc: [String: Any]?, config: AppConfig) {
        if let doc {
            atomicWriteJSON(doc, to: jobActivePendingURL(config: config))
        } else {
            try? FileManager.default.removeItem(at: jobActivePendingURL(config: config))
        }
    }

    static func persistStepJobFiles(
        running: [String: Any]?,
        pending: [String: Any]?,
        queue: ImageGenQueueFile,
        config: AppConfig
    ) {
        saveActiveRunning(running, config: config)
        saveActivePending(pending, config: config)
        saveQueue(queue, config: config)
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
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
    var statusHTML: String
    var fullPrompt: String
    var thumbnailPaths: [String]
    var referencesInvalid: Bool
    var steps: [[String: Any]]
    var pluginUnavailable: Bool
    var statusView: QueueJobStatusView?
    var jobNumber: Int?
    var held: Bool
    var inError: Bool
    var errorMessage: String

    var id: String { jobID }
    var statusLabel: String { QueueRowSnapshot.plainText(from: statusHTML) }

    init(
        jobID: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int = 1,
        statusHTML: String = "Queued",
        fullPrompt: String = "",
        thumbnailPaths: [String] = [],
        referencesInvalid: Bool = false,
        steps: [[String: Any]] = [],
        pluginUnavailable: Bool = false,
        statusView: QueueJobStatusView? = nil,
        jobNumber: Int? = nil,
        held: Bool = false,
        inError: Bool = false,
        errorMessage: String = ""
    ) {
        self.jobID = jobID
        self.pluginID = pluginID
        self.function = function
        self.values = values
        self.copiesTotal = copiesTotal
        self.statusHTML = statusHTML
        self.fullPrompt = fullPrompt.isEmpty ? (values["prompt"] as? String ?? "") : fullPrompt
        self.thumbnailPaths = thumbnailPaths
        self.referencesInvalid = referencesInvalid
        self.steps = steps
        self.pluginUnavailable = pluginUnavailable
        self.statusView = statusView
        self.jobNumber = jobNumber
        self.held = held
        self.inError = inError
        self.errorMessage = errorMessage
    }

    init(document: [String: Any]) {
        jobID = document["job_id"] as? String ?? UUID().uuidString
        pluginID = document["plugin_id"] as? String ?? ""
        function = document["function"] as? String ?? "create"
        pluginUnavailable = document["plugin_unavailable"] as? Bool ?? false
        steps = document["steps"] as? [[String: Any]] ?? []

        var loadedValues = document["values"] as? [String: Any] ?? [:]
        if loadedValues.isEmpty, let firstStep = steps.first {
            loadedValues = JobStepQueue.mergeStepIntoValues(firstStep)
        }
        values = loadedValues

        if let display = document["display"] as? [String: Any] {
            thumbnailPaths = display["thumbnail_paths"] as? [String] ?? document["thumbnail_paths"] as? [String] ?? []
        } else {
            thumbnailPaths = document["thumbnail_paths"] as? [String] ?? []
        }

        if let copies = document["copies_total"] as? Int {
            copiesTotal = max(1, copies)
        } else if !steps.isEmpty {
            copiesTotal = steps.count
        } else {
            copiesTotal = 1
        }

        statusHTML = document["status_html"] as? String ?? "Queued"
        jobNumber = ImageGenJobNumber.parse(from: document)
        held = document["held"] as? Bool ?? false
        inError = document["in_error"] as? Bool ?? false
        errorMessage = document["error_message"] as? String ?? ""
        if inError == false, statusHTML == "Failed" {
            inError = true
            if errorMessage.isEmpty {
                errorMessage = "Job failed."
            }
        }
        referencesInvalid = document["references_invalid"] as? Bool ?? false
        fullPrompt = JobStepQueue.resolvedFullPrompt(
            stored: {
                if let display = document["display"] as? [String: Any],
                   let prompt = display["full_prompt"] as? String {
                    return prompt
                }
                return document["full_prompt"] as? String ?? ""
            }(),
            values: values,
            steps: steps,
            statusView: nil
        )
        if !fullPrompt.isEmpty, (values["prompt"] as? String ?? "").isEmpty {
            values["prompt"] = fullPrompt
        }
    }

    var document: [String: Any] {
        let resolvedPrompt = JobStepQueue.resolvedFullPrompt(
            stored: fullPrompt,
            values: values,
            steps: steps,
            statusView: statusView
        )
        var doc: [String: Any] = [
            "version": JobStepQueue.stepVersion,
            "job_id": jobID,
            "plugin_id": pluginID,
            "function": function,
            "values": values,
            "copies_total": copiesTotal,
            "status_html": statusHTML,
            "full_prompt": resolvedPrompt,
            "thumbnail_paths": thumbnailPaths,
            "references_invalid": referencesInvalid,
            "plugin_unavailable": pluginUnavailable,
            "display": [
                "full_prompt": resolvedPrompt,
                "thumbnail_paths": thumbnailPaths,
            ],
            "steps_done": 0,
            "held": held,
            "in_error": inError,
            "error_message": errorMessage,
        ]
        if let jobNumber {
            doc["job_number"] = jobNumber
        }
        if !steps.isEmpty {
            doc["steps"] = steps
        }
        return doc
    }
}
