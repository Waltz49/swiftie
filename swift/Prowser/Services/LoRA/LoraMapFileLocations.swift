import Foundation

/// Installed image-gen model and LoRA weight paths for Map LoRAs → File locations.
@MainActor
enum LoraMapFileLocations {
    struct Row: Identifiable, Hashable {
        let id: String
        let label: String
        let path: String
    }

    static func build(config: AppConfig) -> (imageGen: [Row], loras: [Row]) {
        (imageGenModels(), loras(config: config))
    }

    static func filter(_ rows: [Row], needle: String) -> [Row] {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.label.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    static func plainText(imageGenRows: [Row], loraRows: [Row]) -> String {
        var lines: [String] = []
        lines.append(contentsOf: plainTextSection(
            title: "LoRAs",
            rows: loraRows,
            emptyMessage: "No LoRA weight files found on disk."
        ))
        lines.append("")
        lines.append(contentsOf: plainTextSection(
            title: "Image Generation Models",
            rows: imageGenRows,
            emptyMessage: "No image generation models installed locally."
        ))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func plainTextSection(
        title: String,
        rows: [Row],
        emptyMessage: String
    ) -> [String] {
        var lines = [title, ""]
        if rows.isEmpty {
            lines.append(emptyMessage)
        } else {
            for (index, row) in rows.enumerated() {
                if index > 0 {
                    lines.append("")
                }
                lines.append(row.label)
                lines.append("  - \(row.path)")
            }
        }
        return lines
    }

    private static func imageGenModels() -> [Row] {
        var rows: [Row] = []
        for entry in ImageGenModelDownloadCatalog.buildCatalog() {
            guard ImageGenHFModelLocality.modelIsInstalled(
                pipelineID: entry.pipelineID,
                repoID: entry.repoID
            ) else { continue }
            guard let raw = ImageGenHFModelLocality.resolvedInstallPath(
                pipelineID: entry.pipelineID,
                repoID: entry.repoID
            ) else { continue }
            rows.append(
                Row(
                    id: entry.repoID,
                    label: entry.repoID,
                    path: SettingsPathValidation.displayPath(raw)
                )
            )
        }
        return rows
    }

    private static func loras(config: AppConfig) -> [Row] {
        let store = LoRACatalogStore(paths: config.profilePaths)
        let lc = store.load()
        var rows: [Row] = []
        for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
            guard let url = LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) else {
                continue
            }
            let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? entry.loraID : name
            rows.append(
                Row(
                    id: entry.loraID,
                    label: label,
                    path: SettingsPathValidation.displayPath(url.path)
                )
            )
        }
        return rows
    }
}
