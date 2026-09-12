import Foundation

struct QuickPersonFace: Sendable {
    let trbl: [Int]
    let embedding: [Double]
}

struct QuickPersonImageResult: Sendable {
    let path: String
    let faces: [QuickPersonFace]
    let previewJPEGBase64: String
}

/// Headless face encoding for Quick Person Search (`swift/Scripts/quick_person_worker.py`).
@Observable
@MainActor
final class QuickPersonBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?
    private var isReady = false
    private var pendingCommand: [String: Any]?

    private enum ActiveJob {
        case encode(CheckedContinuation<[QuickPersonImageResult], Error>)
        case save(CheckedContinuation<String, Error>)
    }

    private var activeJobID = ""
    private var activeJob: ActiveJob?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func encodeFaces(imagePaths: [String]) async throws -> [QuickPersonImageResult] {
        guard let environment else { throw BridgeError.pythonUnavailable }
        let jobID = UUID().uuidString
        let cmd: [String: Any] = [
            "command": "encode_faces",
            "job_id": jobID,
            "image_paths": imagePaths,
        ]
        return try await withCheckedThrowingContinuation { continuation in
            beginJob(jobID: jobID, job: .encode(continuation), command: cmd, environment: environment)
        }
    }

    func saveQuickPersonSamples(samples: [(path: String, embedding: [Double])]) async throws -> String {
        guard let environment else { throw BridgeError.pythonUnavailable }
        let jobID = UUID().uuidString
        let payload: [[String: Any]] = samples.map { [
            "path": $0.path,
            "embedding": $0.embedding,
        ] }
        let cmd: [String: Any] = [
            "command": "save_quick_person",
            "job_id": jobID,
            "samples": payload,
        ]
        return try await withCheckedThrowingContinuation { continuation in
            beginJob(jobID: jobID, job: .save(continuation), command: cmd, environment: environment)
        }
    }

    func shutdown() {
        failActiveJob(QuickPersonBridgeError.workerFailed("Worker shut down"))
        try? bridge?.send(["command": "shutdown"])
        bridge?.terminate()
        bridge = nil
        isReady = false
        pendingCommand = nil
    }

    private func beginJob(
        jobID: String,
        job: ActiveJob,
        command: [String: Any],
        environment: PythonLocator.Environment
    ) {
        failActiveJob(QuickPersonBridgeError.workerFailed("Superseded by a newer request"))
        activeJobID = jobID
        activeJob = job
        do {
            try ensureWorker(environment: environment)
            if isReady {
                try bridge?.send(command)
                pendingCommand = nil
            } else {
                pendingCommand = command
            }
        } catch {
            finishActiveJob(jobID: jobID, result: .failure(error))
        }
    }

    private func ensureWorker(environment: PythonLocator.Environment) throws {
        if bridge?.isRunning == true { return }
        let processBridge = JSONLineProcessBridge(environment: environment)
        processBridge.setMessageHandler { [weak self] message in
            Task { @MainActor in self?.handleMessage(message) }
        }
        bridge = processBridge
        isReady = false
        let script = environment.repoRoot
            .appendingPathComponent("swift/Scripts/quick_person_worker.py")
        try processBridge.start(arguments: ["-u", script.path])
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let msgJobID = message["job_id"] as? String ?? ""
        if type == "ready" {
            isReady = true
            if let command = pendingCommand {
                do {
                    try bridge?.send(command)
                    pendingCommand = nil
                } catch {
                    failActiveJob(error)
                }
            }
            return
        }

        let jobID = msgJobID
        guard !jobID.isEmpty, jobID == activeJobID, let job = activeJob else { return }

        switch type {
        case "result":
            switch job {
            case .encode(let continuation):
                let images = message["images"] as? [[String: Any]] ?? []
                let parsed = images.compactMap { Self.parseImageResult($0) }
                clearActiveJob()
                continuation.resume(returning: parsed)
            case .save(let continuation):
                let subjectID = message["subject_id"] as? String ?? ""
                clearActiveJob()
                continuation.resume(returning: subjectID)
            }
        case "error":
            let err = message["message"] as? String ?? "Quick Person worker failed."
            finishActiveJob(jobID: jobID, result: .failure(QuickPersonBridgeError.workerFailed(err)))
        default:
            break
        }
    }

    private func failActiveJob(_ error: Error) {
        guard let job = activeJob else { return }
        clearActiveJob()
        switch job {
        case .encode(let continuation):
            continuation.resume(throwing: error)
        case .save(let continuation):
            continuation.resume(throwing: error)
        }
    }

    private func finishActiveJob(jobID: String, result: Result<Never, Error>) {
        guard jobID == activeJobID, let job = activeJob else { return }
        clearActiveJob()
        if case .failure(let error) = result {
            switch job {
            case .encode(let continuation):
                continuation.resume(throwing: error)
            case .save(let continuation):
                continuation.resume(throwing: error)
            }
        }
    }

    private func clearActiveJob() {
        activeJob = nil
        activeJobID = ""
    }

    private static func parseImageResult(_ dict: [String: Any]) -> QuickPersonImageResult? {
        guard let path = dict["path"] as? String else { return nil }
        let rawFaces = dict["faces"] as? [[String: Any]] ?? []
        let faces = rawFaces.compactMap { face -> QuickPersonFace? in
            guard let trbl = FaceEncodingJSON.parseTRBL(face["trbl"]),
                  let emb = FaceEncodingJSON.parseEmbedding(face["embedding"]) else { return nil }
            return QuickPersonFace(trbl: trbl, embedding: emb)
        }
        let preview = dict["preview_b64"] as? String ?? ""
        return QuickPersonImageResult(path: path, faces: faces, previewJPEGBase64: preview)
    }
}

enum QuickPersonBridgeError: Error, LocalizedError {
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .workerFailed(let message): return message
        }
    }
}
