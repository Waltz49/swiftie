import Foundation

/// How a registry ``pipeline_id`` is executed in the Swift app (MFLUX CLI vs vendored Python worker).
enum ImageGenPipelineRouting {
    enum ExecutionKind: Equatable {
        case mfluxCLI
        case bundledPythonWorker
        case sceneWorksPythonWorker
    }

    /// Unique ``pipeline_id`` values from vendored ``imagegen_plugins`` registrations.
    static let registeredPipelineIDs: Set<String> = [
        "flux_schnell_mflux_play",
        "sana_sprint_600m",
        "z_image_turbo_sdnq",
        "mflux_z_image_turbo",
        "sd15_diffusers",
        "sdxl_diffusers",
        "mflux_fill_expand",
        "mflux_fill_infill",
        "mflux_flux2_klein_create",
        "mflux_flux2_klein_edit",
        "mflux_flux2_klein_expand",
    ]

    /// Pipelines that must run ``ImageGenPipelineWorkerRunner`` (not ``mflux-generate*``).
    static let bundledPythonWorkerPipelineIDs: Set<String> = [
        "sana_sprint_600m",
        "z_image_turbo_sdnq",
        "sd15_diffusers",
        "sdxl_diffusers",
    ]

    static func executionKind(pipelineID: String, hfModelID: String) -> ExecutionKind? {
        let pipeline = pipelineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pipeline.isEmpty else { return nil }
        if ImageGenSceneWorksKlein.isSceneWorksRepo(hfModelID) {
            guard pipeline.hasPrefix("mflux_flux2_klein") else { return nil }
            return .sceneWorksPythonWorker
        }
        if bundledPythonWorkerPipelineIDs.contains(pipeline) {
            return .bundledPythonWorker
        }
        if MfluxCLIPipeline.isSupported(pipelineID: pipeline) {
            return .mfluxCLI
        }
        return nil
    }

    static func usesPythonWorker(pipelineID: String, hfModelID: String) -> Bool {
        switch executionKind(pipelineID: pipelineID, hfModelID: hfModelID) {
        case .bundledPythonWorker, .sceneWorksPythonWorker:
            return true
        case .mfluxCLI, nil:
            return false
        }
    }

    /// Every registered pipeline must have a worker script and a routing kind.
    static func validateVendoredCatalog(bundleRoot: URL) -> [String] {
        var issues: [String] = []
        for pipelineID in registeredPipelineIDs.sorted() {
            if executionKind(pipelineID: pipelineID, hfModelID: "black-forest-labs/FLUX.1-schnell") == nil {
                issues.append("No execution kind for pipeline \(pipelineID)")
            }
            if ImageGenPipelineCatalog.workerScriptName(pipelineID: pipelineID) == nil {
                issues.append("Missing worker script mapping for \(pipelineID)")
                continue
            }
            if ImageGenPipelineWorkerRunner.scriptURL(
                pipelineID: pipelineID,
                bundleRoot: bundleRoot
            ) != nil {
                continue
            }
            issues.append("Worker script file missing on disk for \(pipelineID)")
        }
        return issues
    }
}
