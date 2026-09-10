import Foundation

/// Read `known_faces.json` (shared with Python `faces/known_faces_manager.py`).
struct KnownFaceSubject: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let sampleCount: Int
}

enum KnownFacesStore {
    static func loadSubjects(dataDirectory: URL) -> [KnownFaceSubject] {
        let url = dataDirectory.appendingPathComponent("known_faces.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["subjects"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict -> KnownFaceSubject? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let samples = dict["samples"] as? [[String: Any]] ?? []
            let withEmbeddings = samples.filter { ($0["embedding"] as? [Any])?.isEmpty == false }
            return KnownFaceSubject(id: id, name: name, sampleCount: withEmbeddings.count)
        }
        .filter { $0.sampleCount > 0 }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
