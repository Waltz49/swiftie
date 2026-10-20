import Foundation

/// How a registry ``pipeline_id`` is executed in the Swift app.
enum ImageGenPipelineRouting {
    enum ExecutionKind: Equatable {
        case mfluxCLI
        case optimizedPythonWorker
    }

    /// Diffusers / torch-backed pipelines (venv + diffusers import).
    static let diffusersPipelineIDs: Set<String> = [
        "sana_sprint_600m",
        "z_image_turbo_sdnq",
        "sd15_diffusers",
        "sdxl_diffusers",
    ]

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

    @MainActor
    static func executionBackend(config: AppConfig?) -> ImageGenExecutionBackend {
        guard let config else { return .optimized }
        return ImageGenExecutionBackend.from(config: config)
    }

    @MainActor
    static func executionKind(
        pipelineID: String,
        hfModelID: String,
        config: AppConfig? = nil
    ) -> ExecutionKind? {
        let pipeline = pipelineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pipeline.isEmpty else { return nil }

        if ImageGenSceneWorksKlein.isSceneWorksRepo(hfModelID) {
            guard pipeline.hasPrefix("mflux_flux2_klein") else { return nil }
            return .optimizedPythonWorker
        }

        let backend = executionBackend(config: config)
        if backend == .mfluxCLI, MfluxCLIPipeline.isSupported(pipelineID: pipeline) {
            return .mfluxCLI
        }

        if ImageGenPipelineCatalog.workerScriptName(pipelineID: pipeline) != nil {
            return .optimizedPythonWorker
        }
        return nil
    }

    @MainActor
    static func usesPythonWorker(
        pipelineID: String,
        hfModelID: String,
        config: AppConfig? = nil
    ) -> Bool {
        switch executionKind(pipelineID: pipelineID, hfModelID: hfModelID, config: config) {
        case .optimizedPythonWorker:
            return true
        case .mfluxCLI, nil:
            return false
        }
    }

    @MainActor
    static func usesPersistentPythonWorker(
        pipelineID: String,
        hfModelID: String,
        config: AppConfig? = nil
    ) -> Bool {
        executionKind(pipelineID: pipelineID, hfModelID: hfModelID, config: config) == .optimizedPythonWorker
    }

    /// Every registered pipeline must have a worker script and a routing kind.
    @MainActor
    static func validateVendoredCatalog(bundleRoot: URL, config: AppConfig? = nil) -> [String] {
        var issues: [String] = []
        for pipelineID in registeredPipelineIDs.sorted() {
            if executionKind(pipelineID: pipelineID, hfModelID: "black-forest-labs/FLUX.1-schnell", config: config) == nil {
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
