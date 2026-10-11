import Foundation

@MainActor
final class SwiftImageGenRegistry: ImageGenRegistry {
    private weak var config: AppConfig?
    private(set) var lastError = ""

    init(config: AppConfig?) {
        self.config = config
    }

    func reloadSettings(config: AppConfig) {
        self.config = config
    }

    var isAvailable: Bool {
        guard BundleCapabilities.imageGenUIEnabled else {
            lastError = "Image generation is not included in this build."
            return false
        }
        guard ImageGenPythonBundle.rootURL() != nil else {
            lastError = "Bundled pipeline scripts are missing."
            return false
        }
        if let bundleRoot = ImageGenPythonBundle.rootURL() {
            let issues = ImageGenPipelineRouting.validateVendoredCatalog(bundleRoot: bundleRoot)
            if !issues.isEmpty {
                lastError = issues.first ?? "Pipeline catalog incomplete."
                return false
            }
        }
        guard let config else { return false }
        if MfluxToolchain.shared.isAvailable { return true }
        if ImageGenPluginAvailability.venvPythonReady(config: config) { return true }
        lastError = MfluxToolchain.shared.lastProbeError
        return false
    }

    func shutdown() {}

    func listPlugins(
        function: String? = nil,
        savedValues: [String: Any]? = nil,
        availability: ImageGenPluginListAvailability = .full
    ) async throws -> [[String: Any]] {
        let snapshot = ImageGenCatalogSnapshot.loadPlugins()
        let filtered: [[String: Any]]
        if let function, !function.isEmpty {
            filtered = snapshot.filter { ($0["function"] as? String) == function }
        } else {
            filtered = snapshot
        }
        return assemblePlugins(from: filtered, savedValues: savedValues, availability: availability)
    }

    /// One snapshot read; partition by function key.
    func listPluginsGrouped(
        functions: [String],
        savedByFunction: [String: [String: Any]],
        availability: ImageGenPluginListAvailability
    ) async throws -> [String: [[String: Any]]] {
        let snapshot = ImageGenCatalogSnapshot.loadPlugins()
        var out: [String: [[String: Any]]] = [:]
        for function in functions {
            let filtered = snapshot.filter { ($0["function"] as? String) == function }
            let saved = savedByFunction[function]
            let savedValues = saved?.isEmpty == false ? saved : nil
            out[function] = assemblePlugins(from: filtered, savedValues: savedValues, availability: availability)
        }
        return out
    }

    func buildPayload(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        applyImageExit: Bool = true
    ) async throws -> [String: Any] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            throw ImageGenRegistryError.unknownPlugin(pluginID)
        }
        guard let config else { throw ImageGenRegistryError.unknownPlugin(pluginID) }
        var runValues = values
        var applyExit = applyImageExit
        if applyImageExit {
            runValues = ImageGenMfluxPayloadBuilder.applyImagePromptRules(values: runValues, config: config)
            applyExit = false
        }
        var payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: runValues,
            outputPath: outputPath,
            config: config,
            applyImageExit: applyExit
        )
        payload = try await ImageGenLoraWorkerPayloadEnrich.enrichPayload(
            pluginID: pluginID,
            payload: payload,
            outputPath: outputPath,
            applyImageExit: applyExit,
            config: config
        )
        return payload
    }

    func normalizeValues(pluginID: String, values: [String: Any], mode: String) async throws -> [String: Any] {
        guard let config else { throw ImageGenRegistryError.unknownPlugin(pluginID) }
        return try await ImageGenJobValuesSnapshot.normalizeValues(
            pluginID: pluginID,
            values: values,
            mode: mode,
            config: config
        )
    }

    func materializeSteps(pluginID: String, values: [String: Any], copies: Int) async throws -> [[String: Any]] {
        try JobStepQueue.materializeSteps(pluginID: pluginID, templateValues: values, copiesTotal: copies)
    }

    private func assemblePlugins(
        from filtered: [[String: Any]],
        savedValues: [String: Any]?,
        availability: ImageGenPluginListAvailability
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for raw in filtered {
            guard let pluginID = raw["plugin_id"] as? String,
                  let descriptor = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { continue }
            var plugin = raw
            plugin["merged_defaults"] = ImageGenPluginMetadata.mergedDefaults(
                pluginID: pluginID,
                saved: savedValues
            )
            switch availability {
            case .fast:
                plugin["available"] = pluginFastAvailable(descriptor)
            case .full:
                plugin["available"] = pluginIsAvailable(descriptor)
            }
            if plugin["field_layout"] == nil {
                plugin["field_layout"] = raw["field_layout"] as? [[String: Any]] ?? []
            }
            out.append(plugin)
        }
        switch availability {
        case .fast:
            return ImageGenMfluxPluginFilter.applyingMfluxAvailabilityFast(out, config: config)
        case .full:
            return ImageGenMfluxPluginFilter.applyingMfluxAvailability(out, config: config)
        }
    }

    private func pluginFastAvailable(_ plugin: ImageGenPluginDescriptor) -> Bool {
        switch ImageGenPipelineRouting.executionKind(pipelineID: plugin.pipelineID, hfModelID: plugin.hfModelID) {
        case .mfluxCLI:
            return MfluxToolchain.shared.isPipelineInstalled(plugin.pipelineID)
        case .bundledPythonWorker, .sceneWorksPythonWorker:
            guard let config else { return false }
            return ImageGenPluginAvailability.venvPythonReady(config: config)
        case nil:
            return false
        }
    }

    private func pluginIsAvailable(_ plugin: ImageGenPluginDescriptor) -> Bool {
        switch ImageGenPipelineRouting.executionKind(pipelineID: plugin.pipelineID, hfModelID: plugin.hfModelID) {
        case .mfluxCLI:
            return MfluxToolchain.shared.isAvailable
        case .bundledPythonWorker, .sceneWorksPythonWorker:
            guard let config else { return false }
            return ImageGenPluginAvailability.diffusersPipelineReady(config: config)
        case nil:
            return false
        }
    }
}
