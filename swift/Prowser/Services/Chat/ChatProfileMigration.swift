import Foundation

/// One-time copy of chat libraries from the Python Prowser profile (`~/.prowser`).
@MainActor
enum ChatProfileMigration {
    private static let pythonProfileDirectoryName = ".prowser"
    private static let systemPromptsFileName = "chat_system_prompts.json"
    private static let migrationSettingsKey = "chat_system_prompts_migrated_from_prowser"

    static func migrateSystemPromptsFromPythonProfile(config: AppConfig) {
        guard !config.bool(forKey: migrationSettingsKey, default: false) else { return }

        let legacyURL = pythonReferenceDataDirectory
            .appendingPathComponent(systemPromptsFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        let destURL = config.dataDirectory.appendingPathComponent(systemPromptsFileName)
        guard shouldCopyLegacySystemPrompts(legacyURL: legacyURL, destURL: destURL) else {
            config.updateSetting(migrationSettingsKey, value: true)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: config.dataDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: legacyURL, to: destURL)
            config.updateSetting(migrationSettingsKey, value: true)
        } catch {
            // Leave flag unset so a later launch can retry.
        }
    }

    /// Skip when Swift already has a non-default named prompt library.
    private static func shouldCopyLegacySystemPrompts(legacyURL: URL, destURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destURL.path),
              let destData = try? Data(contentsOf: destURL),
              let destJSON = try? JSONSerialization.jsonObject(with: destData) as? [String: Any] else {
            return true
        }
        let named = destJSON["named_prompts"] as? [[String: Any]] ?? []
        if !named.isEmpty { return false }
        let system = destJSON["system_prompt"] as? String ?? ""
        let trimmed = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != ChatSystemPromptStore.defaultPromptText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }
        // Dest is empty/default — copy if legacy has anything worth importing.
        guard let legacyData = try? Data(contentsOf: legacyURL),
              let legacyJSON = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any] else {
            return false
        }
        let legacyNamed = legacyJSON["named_prompts"] as? [[String: Any]] ?? []
        let legacySystem = (legacyJSON["system_prompt"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !legacyNamed.isEmpty
            || legacySystem != ChatSystemPromptStore.defaultPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var pythonReferenceDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(pythonProfileDirectoryName, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }
}
