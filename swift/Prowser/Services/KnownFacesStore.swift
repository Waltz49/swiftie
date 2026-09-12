import Foundation

/// Read `known_faces.json` (shared with Python `faces/known_faces_manager.py`).
struct KnownFaceSubject: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let sampleCount: Int
}

struct KnownFaceSample: Equatable {
    let path: String
    let embedding: [Double]
}

struct KnownFaceSubjectDetail: Identifiable, Equatable {
    let id: String
    var name: String
    var samples: [KnownFaceSample]
}

enum KnownFacesStore {
    static func loadSubjects(dataDirectory: URL) -> [KnownFaceSubject] {
        loadSubjectDetails(dataDirectory: dataDirectory)
            .filter { !$0.samples.isEmpty }
            .map { KnownFaceSubject(id: $0.id, name: $0.name, sampleCount: $0.samples.count) }
    }

    /// All subjects for Search by person (Python `list_subjects` order: name ascending).
    static func loadSubjectDetails(dataDirectory: URL) -> [KnownFaceSubjectDetail] {
        let url = dataDirectory.appendingPathComponent("known_faces.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["subjects"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict -> KnownFaceSubjectDetail? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let name = (dict["name"] as? String ?? "Unnamed").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawSamples = dict["samples"] as? [[String: Any]] ?? []
            let samples = rawSamples.prefix(4).compactMap { sample -> KnownFaceSample? in
                let path = sample["path"] as? String ?? ""
                guard let rawEmbedding = sample["embedding"] as? [Any], !rawEmbedding.isEmpty else { return nil }
                let embedding = rawEmbedding.compactMap { element -> Double? in
                    if let value = element as? Double { return value }
                    if let value = element as? Int { return Double(value) }
                    if let value = element as? NSNumber { return value.doubleValue }
                    return nil
                }
                guard embedding.count == 128 else { return nil }
                return KnownFaceSample(path: path, embedding: embedding)
            }
            return KnownFaceSubjectDetail(id: id, name: name.isEmpty ? "Unnamed" : name, samples: samples)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let maxSamplesPerSubject = 4
    static let placeholderAddName = "Add..."

    @discardableResult
    static func saveSubjectDetails(dataDirectory: URL, subjects: [KnownFaceSubjectDetail]) throws -> Bool {
        let url = dataDirectory.appendingPathComponent("known_faces.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [[String: Any]] = subjects.map { subject in
            [
                "id": subject.id,
                "name": subject.name.trimmingCharacters(in: .whitespacesAndNewlines),
                "samples": subject.samples.prefix(maxSamplesPerSubject).map { sample in
                    [
                        "path": sample.path,
                        "embedding": sample.embedding,
                    ]
                },
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["subjects": payload],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        return true
    }

    static func nameExists(_ name: String, subjects: [KnownFaceSubjectDetail], excludingID: String? = nil) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return subjects.contains { subject in
            if let excludingID, subject.id == excludingID { return false }
            return subject.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }
}
