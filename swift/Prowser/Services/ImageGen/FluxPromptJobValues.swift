import Foundation

/// Flux prompt AI job value helpers (nonisolated; port of ``flux_prompt_job.py`` prompt fields).
enum FluxPromptJobValues {
    static let fluxPromptAIJobKey = JobStepQueue.fluxPromptAIJobKey

    static func hasFluxPromptAIJob(_ values: [String: Any]) -> Bool {
        values[fluxPromptAIJobKey] is [String: Any]
    }

    static func fluxPromptAIUserPrompt(_ values: [String: Any]) -> String {
        if let meta = values[fluxPromptAIJobKey] as? [String: Any] {
            let user = (meta["user_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty { return user }
        }
        return (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Port of ``effective_job_prompt_for_tooltip``.
    static func effectiveJobPromptForTooltip(_ values: [String: Any]) -> String {
        var current: String
        if hasFluxPromptAIJob(values) {
            current = fluxPromptAIUserPrompt(values)
        } else {
            current = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty {
                current = fluxPromptAIUserPrompt(values)
            }
        }
        guard !current.isEmpty else { return "" }
        return ImageGenLoraTriggerPromptGuard.augmentPromptWithMissingLoraTriggers(
            prompt: current,
            values: values
        )
    }

    static func syncFluxPromptAIUserPromptForNextCopy(
        values: inout [String: Any],
        sourceValues: [String: Any]? = nil
    ) {
        guard var meta = values[fluxPromptAIJobKey] as? [String: Any] else { return }
        let src = sourceValues ?? values
        let prompt = (src["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            meta["user_prompt"] = prompt
        }
        if meta["image_paths"] != nil {
            let refreshed = ImageGenExifReferences.resolveSourceImagePaths(values)
                .filter { FileManager.default.isReadableFile(atPath: $0) }
            if !refreshed.isEmpty {
                meta["image_paths"] = refreshed
            }
        }
        values[fluxPromptAIJobKey] = meta
    }

    static func applyRefinementSourceForNextCopy(
        values: [String: Any],
        outputPath: String
    ) -> [String: Any] {
        var out = values
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.isReadableFile(atPath: trimmed) else { return out }
        let ap = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        var paths: [String]
        if let multi = out["source_image_paths"] as? [String], !multi.isEmpty {
            paths = multi.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        } else {
            paths = ImageGenExifReferences.resolveSourceImagePaths(out)
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        if paths.isEmpty {
            paths = [ap]
        } else {
            paths[0] = ap
        }
        out["source_image_path"] = ap
        out["source_image_paths"] = paths
        return out
    }
}
