import Foundation

/// `data/known_faces.json` (port of `faces/known_faces_manager.py`).
final class KnownFacesStore: @unchecked Sendable {
    static let maxSamplesPerSubject = 4
    static let quickPersonSubjectName = "Z Quick Person"

    struct Sample: Codable, Sendable {
        var path: String?
        var embedding: [Double]
    }

    struct Subject: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var samples: [Sample]
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(profile: ProfilePaths) {
        fileURL = profile.knownFacesFile
    }

    func loadSubjects() -> [Subject] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        return root.subjects
    }

    func saveSubjects(_ subjects: [Subject]) {
        lock.lock()
        defer { lock.unlock() }
        let root = Root(subjects: subjects)
        guard let data = try? JSONEncoder().encode(root) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func listSubjects() -> [Subject] { loadSubjects() }

    func subject(id: String) -> Subject? {
        loadSubjects().first { $0.id == id }
    }

    func addSubject(name: String) -> Subject? {
        var subjects = loadSubjects()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if subjects.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return nil
        }
        let subject = Subject(id: UUID().uuidString, name: trimmed, samples: [])
        subjects.append(subject)
        saveSubjects(subjects)
        return subject
    }

    func deleteSubject(id: String) {
        var subjects = loadSubjects()
        subjects.removeAll { $0.id == id }
        saveSubjects(subjects)
    }

    func updateSubjectName(id: String, name: String) -> Bool {
        var subjects = loadSubjects()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if subjects.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return false
        }
        guard let idx = subjects.firstIndex(where: { $0.id == id }) else { return false }
        subjects[idx].name = trimmed
        saveSubjects(subjects)
        return true
    }

    func removeSample(subjectID: String, at index: Int) {
        var subjects = loadSubjects()
        guard let subjectIndex = subjects.firstIndex(where: { $0.id == subjectID }) else { return }
        var samples = subjects[subjectIndex].samples
        guard index >= 0, index < samples.count else { return }
        samples.remove(at: index)
        if samples.isEmpty {
            subjects.remove(at: subjectIndex)
        } else {
            subjects[subjectIndex].samples = samples
        }
        saveSubjects(subjects)
    }

    func addSample(subjectID: String, path: String?, embedding: [Double]) -> Bool {
        guard embedding.count == 128 else { return false }
        var subjects = loadSubjects()
        guard let idx = subjects.firstIndex(where: { $0.id == subjectID }) else { return false }
        if subjects[idx].samples.count >= Self.maxSamplesPerSubject { return false }
        subjects[idx].samples.append(Sample(path: path, embedding: embedding))
        saveSubjects(subjects)
        return true
    }

    func replaceAllSamples(subjectID: String, samples: [Sample]) -> Bool {
        var subjects = loadSubjects()
        guard let idx = subjects.firstIndex(where: { $0.id == subjectID }) else { return false }
        subjects[idx].samples = Array(samples.prefix(Self.maxSamplesPerSubject))
        saveSubjects(subjects)
        return true
    }

    /// Port of Settings → Faces examine / assign dialog save (`_faces_examine_current_image`).
    func mergeAssignedFaces(_ assignments: [FaceAssignResult]) {
        guard !assignments.isEmpty else { return }
        var subjects = loadSubjects()
        for assignment in assignments {
            let nameNorm = assignment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameNorm.isEmpty else { continue }
            var matched: Subject?
            if let idx = subjects.firstIndex(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == nameNorm.lowercased()
            }) {
                matched = subjects[idx]
            } else {
                let newSubject = Subject(id: UUID().uuidString, name: assignment.name, samples: [])
                subjects.append(newSubject)
                matched = newSubject
            }
            guard var subject = matched,
                  let idx = subjects.firstIndex(where: { $0.id == subject.id }) else { continue }
            if subject.samples.count >= Self.maxSamplesPerSubject { continue }
            let existingPaths = Set(subject.samples.compactMap(\.path))
            if existingPaths.contains(assignment.imagePath) { continue }
            if subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subject.name = assignment.name
            }
            subject.samples.append(Sample(path: assignment.imagePath, embedding: assignment.embedding))
            subjects[idx] = subject
        }
        saveSubjects(subjects)
    }

    func subjectIDForQuickPerson(createIfMissing: Bool) -> String? {
        var subjects = loadSubjects()
        if let existing = subjects.first(where: { $0.name == Self.quickPersonSubjectName }) {
            return existing.id
        }
        guard createIfMissing else { return nil }
        let subject = Subject(id: UUID().uuidString, name: Self.quickPersonSubjectName, samples: [])
        subjects.append(subject)
        saveSubjects(subjects)
        return subject.id
    }

    private struct Root: Codable {
        var subjects: [Subject]
    }
}
