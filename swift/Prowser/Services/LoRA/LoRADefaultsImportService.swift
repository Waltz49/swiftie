import Foundation
import LoRABlobCodec

enum LoRADefaultsImportError: LocalizedError {
    case missingBlob
    case invalidPassword
    case invalidPayload
    case saveFailed
    case backupFailed
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBlob:
            return "The bundled lorablob resource is missing."
        case .invalidPassword:
            return "Could not decrypt lorablob with that password."
        case .invalidPayload:
            return "Decrypted data is not a valid LoRA catalog JSON object."
        case .saveFailed:
            return "Could not write lora_catalog.json; your previous catalog was restored from backup."
        case .backupFailed:
            return "Could not back up the current lora_catalog.json."
        case let .restoreFailed(detail):
            return "Import failed and catalog restore failed: \(detail)"
        }
    }

}

/// Tools → Debug → Import Lora Defaults.
@MainActor
enum LoRADefaultsImportService {
    static func bundledBlobURL() -> URL? {
        AppAssets.url(name: "lorablob", fileExtension: "")
    }

    static func run(password: String, store: LoRACatalogStore) throws -> LoRACatalogDefaultsMerge.Result {
        guard let blobURL = bundledBlobURL() else {
            throw LoRADefaultsImportError.missingBlob
        }
        let blob = try Data(contentsOf: blobURL)
        let jsonData: Data
        do {
            jsonData = try LoRABlobCodec.decrypt(blob: blob, password: password)
        } catch LoRABlobCodec.Error.decryptionFailed {
            throw LoRADefaultsImportError.invalidPassword
        }
        guard let imported = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw LoRADefaultsImportError.invalidPayload
        }

        let catalogPath = store.catalogFileURL()
        let backupURL = backupURL(for: catalogPath)
        var backupCreated = false

        let existing = store.load()
        if FileManager.default.fileExists(atPath: catalogPath.path) {
            do {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try FileManager.default.removeItem(at: backupURL)
                }
                try FileManager.default.copyItem(at: catalogPath, to: backupURL)
                backupCreated = true
            } catch {
                throw LoRADefaultsImportError.backupFailed
            }
        }

        let (merged, result) = LoRACatalogDefaultsMerge.merge(existing: existing, imported: imported)
        let beforeMTime = catalogModTime(catalogPath)
        store.save(merged)

        if !catalogSaved(catalogPath: catalogPath, beforeMTime: beforeMTime) {
            if backupCreated {
                try restoreCatalog(from: backupURL, to: catalogPath, store: store)
            }
            throw LoRADefaultsImportError.saveFailed
        }

        if backupCreated {
            try? FileManager.default.removeItem(at: backupURL)
        }
        return result
    }

    private static func catalogModTime(_ catalog: URL) -> Date? {
        try? catalog.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func catalogSaved(catalogPath: URL, beforeMTime: Date?) -> Bool {
        guard FileManager.default.fileExists(atPath: catalogPath.path) else { return false }
        guard let after = catalogModTime(catalogPath) else { return true }
        if let before = beforeMTime {
            return after >= before
        }
        return true
    }

    private static func backupURL(for catalog: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return catalog.deletingLastPathComponent()
            .appendingPathComponent("lora_catalog.json.import-backup-\(stamp)")
    }

    private static func restoreCatalog(from backup: URL, to catalog: URL, store: LoRACatalogStore) throws {
        do {
            if FileManager.default.fileExists(atPath: catalog.path) {
                try FileManager.default.removeItem(at: catalog)
            }
            try FileManager.default.copyItem(at: backup, to: catalog)
            store.invalidateCache()
        } catch {
            throw LoRADefaultsImportError.restoreFailed(error.localizedDescription)
        }
    }
}