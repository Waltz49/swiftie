import Foundation

struct LoRAEntry: Equatable, Sendable {
    var hostID: String
    var loraID: String
    var displayName: String
    var repoID: String
    var filename: String
    var scale: Double
    var bestGuess: Double
    var localPath: String?
    var baseHFModelID: String
    var minSteps: Int
    var mfluxCompatible: Bool?
    var triggerWord: String?
    var comment: String?
    var referencePrompt: String?
    var sourcePath: String?

    static let minStepsDefault = 2
    static let userIDPrefix = "user_"

    static func isUserLoraID(_ loraID: String) -> Bool {
        loraID.hasPrefix(userIDPrefix)
    }

    func toDictionary() -> [String: Any] {
        var out: [String: Any] = [
            "host_id": hostID,
            "lora_id": loraID,
            "display_name": displayName,
            "repo_id": repoID,
            "filename": filename,
            "scale": scale,
            "best_guess": bestGuess,
            "base_hf_model_id": baseHFModelID,
            "min_steps": minSteps,
        ]
        if let localPath { out["local_path"] = localPath }
        if let mfluxCompatible { out["mflux_compatible"] = mfluxCompatible }
        if let triggerWord { out["trigger_word"] = triggerWord }
        if let comment { out["comment"] = comment }
        if let referencePrompt { out["reference_prompt"] = referencePrompt }
        if let sourcePath { out["source_path"] = sourcePath }
        return out
    }

    static func fromDictionary(_ raw: [String: Any]) -> LoRAEntry? {
        let loraID = (raw["lora_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !loraID.isEmpty else { return nil }
        let hostID = (raw["host_id"] as? String) ?? ""
        let displayName = (raw["display_name"] as? String) ?? loraID
        let localPath = (raw["local_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseHF = (raw["base_hf_model_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hostID.isEmpty, !baseHF.isEmpty else { return nil }
        if isUserLoraID(loraID), (localPath ?? "").isEmpty { return nil }

        func double(_ key: String, default: Double) -> Double {
            if let n = raw[key] as? NSNumber { return n.doubleValue }
            if let d = raw[key] as? Double { return d }
            return `default`
        }
        func int(_ key: String, default: Int) -> Int {
            if let n = raw[key] as? NSNumber { return n.intValue }
            if let i = raw[key] as? Int { return i }
            return `default`
        }
        let trigger = (raw["trigger_word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = (raw["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = (raw["reference_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mflux = raw["mflux_compatible"] as? Bool
        let source = (raw["source_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return LoRAEntry(
            hostID: hostID,
            loraID: loraID,
            displayName: displayName,
            repoID: (raw["repo_id"] as? String) ?? "",
            filename: (raw["filename"] as? String) ?? "",
            scale: double("scale", default: 1),
            bestGuess: double("best_guess", default: 1),
            localPath: localPath?.isEmpty == true ? nil : localPath,
            baseHFModelID: baseHF,
            minSteps: int("min_steps", default: minStepsDefault),
            mfluxCompatible: mflux,
            triggerWord: trigger?.isEmpty == true ? nil : trigger,
            comment: comment?.isEmpty == true ? nil : comment,
            referencePrompt: ref?.isEmpty == true ? nil : ref,
            sourcePath: source?.isEmpty == true ? nil : source
        )
    }
}

enum LoRACachePaths {
    static var defaultCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/image_browser/mflux_loras", isDirectory: true)
    }

    static var altCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/mflux_loras", isDirectory: true)
    }

    static var userCacheRoot: URL {
        defaultCache.appendingPathComponent("user", isDirectory: true)
    }
}
