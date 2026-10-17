import Foundation

/// One unique Hugging Face repo in the manage-models list (port of ``ModelDownloadCatalogEntry``).
struct ImageGenModelDownloadCatalogEntry: Identifiable, Sendable {
    var id: String { repoID }

    let repoID: String
    let displayName: String
    let pipelineID: String
    let functions: [String]
    let modelComment: String
    let gated: Bool
    let sizeEstimateBytes: Int

    var functionLabels: [String] {
        functions
            .sorted()
            .map { ImageGenModelDownloadFormatting.functionLabel($0) }
    }

    func formattedSizeEstimate() -> String {
        ImageGenModelDownloadFormatting.formatDownloadSizeEstimate(repoID: repoID, bytes: sizeEstimateBytes)
    }
}

/// Static image-gen model download catalog (from registered plugins / snapshot).
@MainActor
enum ImageGenModelDownloadCatalog {
    private static let gatedPrefixes = ["black-forest-labs/"]

    static func buildCatalog() -> [ImageGenModelDownloadCatalogEntry] {
        struct Bucket {
            var pipelineID: String
            var functions: Set<String> = []
            var comments: [String] = []
            var displayNames: [String] = []
        }

        var grouped: [String: Bucket] = [:]
        for raw in ImageGenCatalogSnapshot.loadPlugins() {
            let repoID = (raw["hf_model_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard repoID.contains("/"), !repoID.hasPrefix("./"), !repoID.hasPrefix("../") else { continue }
            let pipelineID = (raw["pipeline_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let function = (raw["function"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if grouped[repoID] == nil {
                grouped[repoID] = Bucket(pipelineID: pipelineID)
            }
            var bucket = grouped[repoID]!
            if !function.isEmpty {
                bucket.functions.insert(function)
            }
            let comment = (raw["model_comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !comment.isEmpty {
                bucket.comments.append(comment)
            }
            let displayName = (raw["display_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty {
                bucket.displayNames.append(displayName)
            }
            grouped[repoID] = bucket
        }

        var entries: [ImageGenModelDownloadCatalogEntry] = []
        for repoID in grouped.keys.sorted() {
            let meta = grouped[repoID]!
            let comment = meta.comments.first ?? ""
            var displayName = LoRAHFModelIDs.displayName(for: repoID)
            for name in meta.displayNames where name != repoID {
                displayName = name
                break
            }
            let gated = gatedPrefixes.contains { repoID.hasPrefix($0) }
            entries.append(
                ImageGenModelDownloadCatalogEntry(
                    repoID: repoID,
                    displayName: displayName,
                    pipelineID: meta.pipelineID,
                    functions: Array(meta.functions),
                    modelComment: comment,
                    gated: gated,
                    sizeEstimateBytes: ImageGenModelDownloadFormatting.sizeEstimateBytes(for: repoID)
                )
            )
        }
        entries.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return entries
    }
}
