import Foundation

struct FaceAssignDetection: Sendable, Identifiable {
    let id = UUID()
    let trbl: [Int]
    let embedding: [Double]
    let suggestedName: String
}

struct FaceAssignDetectionResult: Sendable {
    let imagePath: String
    let previewJPEG: Data?
    let faces: [FaceAssignDetection]
}

/// Python helpers for Settings → Face Recognition (`swift/Scripts/faces_settings_worker.py`).
@Observable
@MainActor
final class KnownFacesBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func checkEngineAvailable() async -> Bool {
        guard let environment else { return false }
        let jobID = UUID().uuidString
        do {
            try ensureWorker(environment: environment)
            return try await withCheckedThrowingContinuation { continuation in
                var finished = false
                bridge?.setMessageHandler { message in
                    Task { @MainActor in
                        guard !finished else { return }
                        let type = message["type"] as? String ?? ""
                        let msgJob = message["job_id"] as? String ?? ""
                        if !msgJob.isEmpty, msgJob != jobID { return }
                        switch type {
                        case "result":
                            finished = true
                            continuation.resume(returning: message["available"] as? Bool ?? false)
                        case "error":
                            finished = true
                            continuation.resume(returning: false)
                        default:
                            break
                        }
                    }
                }
                do {
                    try bridge?.send(["command": "is_available", "job_id": jobID])
                } catch {
                    finished = true
                    continuation.resume(returning: false)
                }
            }
        } catch {
            return false
        }
    }

    func detectFaces(imagePath: String, subjects: [KnownFaceSubjectDetail]) async throws -> FaceAssignDetectionResult {
        guard let environment else { throw BridgeError.pythonUnavailable }
        let jobID = UUID().uuidString
        try ensureWorker(environment: environment)
        let subjectPayload: [[String: Any]] = subjects.map { subject in
            [
                "id": subject.id,
                "name": subject.name,
                "samples": subject.samples.map { [
                    "path": $0.path,
                    "embedding": $0.embedding,
                ] },
            ]
        }
        let cmd: [String: Any] = [
            "command": "detect_faces",
            "job_id": jobID,
            "image_path": imagePath,
            "subjects": subjectPayload,
        ]
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            bridge?.setMessageHandler { message in
                Task { @MainActor in
                    guard !finished else { return }
                    let type = message["type"] as? String ?? ""
                    let msgJob = message["job_id"] as? String ?? ""
                    if !msgJob.isEmpty, msgJob != jobID { return }
                    switch type {
                    case "result":
                        finished = true
                        continuation.resume(returning: Self.parseDetectionResult(message))
                    case "error":
                        finished = true
                        let err = message["message"] as? String ?? "Face detection failed."
                        continuation.resume(throwing: KnownFacesBridgeError.workerFailed(err))
                    default:
                        break
                    }
                }
            }
            do {
                try bridge?.send(cmd)
            } catch {
                finished = true
                continuation.resume(throwing: error)
            }
        }
    }

    func ensureThumbnails(samples: [KnownFaceSample]) async {
        guard let environment, !samples.isEmpty else { return }
        let jobID = UUID().uuidString
        do {
            try ensureWorker(environment: environment)
            let payload: [[String: Any]] = samples.map { [
                "path": $0.path,
                "embedding": $0.embedding,
            ] }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                bridge?.setMessageHandler { message in
                    Task { @MainActor in
                        guard !finished else { return }
                        let type = message["type"] as? String ?? ""
                        let msgJob = message["job_id"] as? String ?? ""
                        if !msgJob.isEmpty, msgJob != jobID { return }
                        switch type {
                        case "result", "error":
                            finished = true
                            continuation.resume()
                        default:
                            break
                        }
                    }
                }
                do {
                    try bridge?.send([
                        "command": "ensure_thumbnails",
                        "job_id": jobID,
                        "samples": payload,
                    ])
                } catch {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return
        }
    }

    func shutdown() {
        try? bridge?.send(["command": "shutdown"])
        bridge?.terminate()
        bridge = nil
    }

    private func ensureWorker(environment: PythonLocator.Environment) throws {
        if bridge?.isRunning == true { return }
        let processBridge = JSONLineProcessBridge(environment: environment)
        bridge = processBridge
        let script = environment.repoRoot
            .appendingPathComponent("swift/Scripts/faces_settings_worker.py")
        try processBridge.start(arguments: ["-u", script.path])
    }

    private static func parseDetectionResult(_ message: [String: Any]) -> FaceAssignDetectionResult {
        let path = message["image_path"] as? String ?? ""
        let previewData = (message["preview_b64"] as? String).flatMap { Data(base64Encoded: $0) }
        let rawFaces = message["faces"] as? [[String: Any]] ?? []
        let faces = rawFaces.compactMap { face -> FaceAssignDetection? in
            guard let trbl = FaceEncodingJSON.parseTRBL(face["trbl"]),
                  let emb = FaceEncodingJSON.parseEmbedding(face["embedding"]) else { return nil }
            let suggested = face["suggested_name"] as? String ?? "Add..."
            return FaceAssignDetection(trbl: trbl, embedding: emb, suggestedName: suggested)
        }
        return FaceAssignDetectionResult(imagePath: path, previewJPEG: previewData, faces: faces)
    }
}

enum KnownFacesBridgeError: Error, LocalizedError {
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .workerFailed(let message): return message
        }
    }
}
