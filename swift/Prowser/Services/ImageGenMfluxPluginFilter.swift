import Foundation

/// Marks registry plugins unavailable when generation backends are not installed.
@MainActor
enum ImageGenMfluxPluginFilter {
    static func applyingMfluxAvailability(
        _ plugins: [[String: Any]],
        config: AppConfig? = nil
    ) -> [[String: Any]] {
        plugins.map { plugin in
            var copy = plugin
            let pipeline = plugin["pipeline_id"] as? String ?? ""
            let hfModel = plugin["hf_model_id"] as? String ?? ""
            let registryOK = plugin["available"] as? Bool ?? true
            let kind = ImageGenPipelineRouting.executionKind(
                pipelineID: pipeline,
                hfModelID: hfModel,
                config: config
            )
            var runtimeOK = false
            switch kind {
            case .optimizedPythonWorker:
                if let config {
                    runtimeOK = ImageGenPluginAvailability.optimizedPipelineReady(
                        pipelineID: pipeline,
                        config: config
                    )
                }
            case .mfluxCLI:
                runtimeOK = MfluxToolchain.shared.isPipelineInstalled(pipeline)
            case nil:
                runtimeOK = false
            }
            copy["available"] = registryOK && runtimeOK
            if registryOK && !runtimeOK {
                switch kind {
                case .optimizedPythonWorker:
                    copy["unavailable_reason"] =
                        "Requires imagegen venv with pipeline dependencies (Settings → Image Generation)."
                case .mfluxCLI, nil:
                    copy["unavailable_reason"] = "Requires MFLUX CLI for this model (Settings → Image Generation)."
                }
            }
            return copy
        }
    }

    /// Optimistic availability for dialog first paint (no subprocess / HF cache walks).
    static func applyingMfluxAvailabilityFast(
        _ plugins: [[String: Any]],
        config: AppConfig? = nil
    ) -> [[String: Any]] {
        plugins.map { plugin in
            var copy = plugin
            let pipeline = plugin["pipeline_id"] as? String ?? ""
            let registryOK = plugin["available"] as? Bool ?? true
            let hfModel = plugin["hf_model_id"] as? String ?? ""
            let kind = ImageGenPipelineRouting.executionKind(
                pipelineID: pipeline,
                hfModelID: hfModel,
                config: config
            )
            let runtimeOK: Bool
            switch kind {
            case .mfluxCLI:
                runtimeOK = MfluxToolchain.shared.isPipelineInstalled(pipeline)
            case .optimizedPythonWorker:
                if let config {
                    runtimeOK = ImageGenPluginAvailability.venvPythonReady(config: config)
                } else {
                    runtimeOK = false
                }
            case nil:
                runtimeOK = false
            }
            copy["available"] = registryOK && runtimeOK
            return copy
        }
    }
}
