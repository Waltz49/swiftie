import Foundation

/// Swift helpers mirroring `image_gen_persistence.py` imagegen settings keys.
@MainActor
enum ImageGenPersistence {
    private static let dialogsKey = "dialogs"
    private static let pluginSettingsKey = "plugin_settings"
    private static let loraStacksKey = "lora_stacks"
    private static let activePluginByFunctionKey = "active_plugin_by_function"
    private static let sharedFunctionKeys: Set<String> = ["prompt"]
    private static let structuralDialogKeys: Set<String> = [pluginSettingsKey, loraStacksKey]
    private static let deprecatedFieldKeys: Set<String> = ["low_ram"]
    private static let globalDialogPrefKeys: Set<String> = [
        "pass_image_to_ai_with_prompt",
        "flux_prompt_ai_job",
        "show_progressive_images",
        "flux_prompt_job_with_generate",
    ]
    private static let pluginSpecificKeys: Set<String> = [
        "hf_model_id",
        "source_image_path",
        "source_image_paths",
    ]
    private static let preserveOnPluginSwitchKeys: Set<String> = [
        "width",
        "height",
        "use_custom_size",
        "aspect_ratio_lock",
    ]

    private static func imagegenBlock(config: AppConfig) -> [String: Any] {
        config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
    }

    private static func mutateImagegen(config: AppConfig, _ mutate: (inout [String: Any]) -> Void) {
        var imagegen = imagegenBlock(config: config)
        mutate(&imagegen)
        config.updateSetting("imagegen", value: imagegen)
    }

    static func persistFunctionKey(_ function: String) -> String {
        function == "infill_paint" ? "infill" : function
    }

    private static func sanitizeDialogValues(_ values: [String: Any]) -> [String: Any] {
        values.filter { key, _ in
            !pluginSpecificKeys.contains(key)
                && !globalDialogPrefKeys.contains(key)
                && !deprecatedFieldKeys.contains(key)
                && key != "series_prompt_refinement"
                && key != "series_refinement"
        }
    }

    private static func sharedDialogValues(from entry: [String: Any]) -> [String: Any] {
        let raw = entry.filter { !structuralDialogKeys.contains($0.key) }
        return sanitizeDialogValues(raw)
    }

    private static func sharedFunctionValues(from values: [String: Any]) -> [String: Any] {
        values.filter { sharedFunctionKeys.contains($0.key) }
    }

    private static func perPluginDialogValues(from values: [String: Any]) -> [String: Any] {
        values.filter { !sharedFunctionKeys.contains($0.key) }
    }

    private static func mergedPrompt(shared: [String: Any], perPlugin: [String: Any]) -> String? {
        let sharedPrompt = (shared["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sharedPrompt.isEmpty { return shared["prompt"] as? String }
        let perPrompt = (perPlugin["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !perPrompt.isEmpty { return perPlugin["prompt"] as? String }
        return nil
    }

    private static func functionDialogEntry(function: String, config: AppConfig) -> [String: Any] {
        let imagegen = imagegenBlock(config: config)
        let dialogs = imagegen[dialogsKey] as? [String: Any] ?? [:]
        return dialogs[persistFunctionKey(function)] as? [String: Any] ?? [:]
    }

    /// FLUX/mflux/Klein/SDXL use multi-LoRA stacks; SD15 keeps single ``mflux_lora``.
    static func pluginUsesLoraStack(pluginID: String) -> Bool {
        let host = ImageGenCatalogSnapshot.pluginDictionary(pluginID: pluginID)?["lora_host_id"] as? String ?? ""
        return !host.isEmpty && host != "sd15"
    }

    private static func coerceLoraPresetID(_ raw: Any?) -> String {
        let text = (raw as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "none" { return "none" }
        return text
    }

    private static func coerceLoraStackList(_ raw: Any?) -> [String] {
        let items: [Any]
        if let stack = raw as? [Any] {
            items = stack
        } else if let stack = raw as? [String] {
            items = stack
        } else {
            return []
        }
        var out: [String] = []
        for item in items {
            let pid = coerceLoraPresetID(item)
            if pid != "none", !out.contains(pid) {
                out.append(pid)
            }
        }
        return out
    }

    private static func loadLoraStackForPlugin(
        function: String,
        pluginID: String,
        config: AppConfig
    ) -> [String] {
        let fnEntry = functionDialogEntry(function: function, config: config)
        let stacks = fnEntry[loraStacksKey] as? [String: Any] ?? [:]
        return coerceLoraStackList(stacks[pluginID])
    }

    private static func applyLoraFieldsForPlugin(pluginID: String, to values: inout [String: Any]) {
        let stack = coerceLoraStackList(values["mflux_lora_stack"])
        if pluginUsesLoraStack(pluginID: pluginID) {
            values["mflux_lora_stack"] = stack
            values.removeValue(forKey: "mflux_lora")
            return
        }
        var preset = coerceLoraPresetID(values["mflux_lora"])
        if preset == "none", let first = stack.first {
            preset = first
        }
        if preset == "none" {
            values.removeValue(forKey: "mflux_lora")
        } else {
            values["mflux_lora"] = preset
        }
        values.removeValue(forKey: "mflux_lora_stack")
    }

    static func loadDialogSettings(function: String, config: AppConfig) -> [String: Any] {
        sharedDialogValues(from: functionDialogEntry(function: function, config: config))
    }

    static func loadPluginDialogSettings(
        function: String,
        pluginID: String,
        config: AppConfig
    ) -> [String: Any] {
        let fnEntry = functionDialogEntry(function: function, config: config)
        let shared = sharedDialogValues(from: fnEntry)
        let pluginSettings = fnEntry[pluginSettingsKey] as? [String: Any] ?? [:]
        let perPlugin = sanitizeDialogValues(pluginSettings[pluginID] as? [String: Any] ?? [:])

        var out: [String: Any]
        if !perPlugin.isEmpty {
            out = perPlugin
        } else if !shared.isEmpty {
            out = shared
        } else {
            out = [:]
        }
        if let prompt = mergedPrompt(shared: shared, perPlugin: perPlugin) {
            out["prompt"] = prompt
        }
        let stack = loadLoraStackForPlugin(function: function, pluginID: pluginID, config: config)
        if pluginUsesLoraStack(pluginID: pluginID) {
            out["mflux_lora_stack"] = stack
            out.removeValue(forKey: "mflux_lora")
        } else {
            var preset = coerceLoraPresetID(out["mflux_lora"])
            if preset == "none", let first = stack.first {
                preset = first
            }
            if preset == "none" {
                out.removeValue(forKey: "mflux_lora")
            } else {
                out["mflux_lora"] = preset
            }
            out.removeValue(forKey: "mflux_lora_stack")
        }
        return sanitizeDialogValues(out)
    }

    private static func activePluginLookupKeys(for function: String) -> [String] {
        let key = persistFunctionKey(function)
        if key == "infill" {
            return ["infill", "infill_paint"]
        }
        return [key]
    }

    static func loadActivePluginID(
        function: String,
        availablePluginIDs: [String],
        config: AppConfig
    ) -> String? {
        let imagegen = imagegenBlock(config: config)
        let byFunction = imagegen[activePluginByFunctionKey] as? [String: Any] ?? [:]
        for lookupKey in activePluginLookupKeys(for: function) {
            if let pluginID = byFunction[lookupKey] as? String,
               availablePluginIDs.contains(pluginID) {
                return pluginID
            }
        }
        return nil
    }

    static func savePluginDialogSettings(
        function: String,
        pluginID: String,
        values: [String: Any],
        config: AppConfig
    ) {
        let key = persistFunctionKey(function)
        var sanitized = sanitizeDialogValues(values)
        var stack = coerceLoraStackList(sanitized.removeValue(forKey: "mflux_lora_stack"))
        let persistStack = pluginUsesLoraStack(pluginID: pluginID)
        if !persistStack {
            sanitized.removeValue(forKey: "mflux_lora_stack")
            let preset = coerceLoraPresetID(sanitized["mflux_lora"])
            if preset == "none", let first = stack.first {
                sanitized["mflux_lora"] = first
            }
            stack = []
        }

        mutateImagegen(config: config) { imagegen in
            var dialogs = imagegen[dialogsKey] as? [String: Any] ?? [:]
            var fnEntry = dialogs[key] as? [String: Any] ?? [:]

            for (sharedKey, sharedValue) in sharedFunctionValues(from: sanitized) {
                fnEntry[sharedKey] = sharedValue
            }

            var pluginSettings = fnEntry[pluginSettingsKey] as? [String: Any] ?? [:]
            var perPlugin = perPluginDialogValues(from: sanitized)
            if persistStack {
                perPlugin.removeValue(forKey: "mflux_lora")
            }
            pluginSettings[pluginID] = perPlugin
            fnEntry[pluginSettingsKey] = pluginSettings

            var stacks = fnEntry[loraStacksKey] as? [String: Any] ?? [:]
            if persistStack {
                stacks[pluginID] = stack
            } else {
                stacks.removeValue(forKey: pluginID)
            }
            fnEntry[loraStacksKey] = stacks

            dialogs[key] = fnEntry
            imagegen[dialogsKey] = dialogs

            var byFunction = imagegen[activePluginByFunctionKey] as? [String: Any] ?? [:]
            byFunction[key] = pluginID
            imagegen[activePluginByFunctionKey] = byFunction
        }
    }

    static func saveDialogSessions(
        _ sessions: [String: (values: [String: Any], pluginID: String)],
        config: AppConfig
    ) {
        for (function, session) in sessions where !session.pluginID.isEmpty {
            savePluginDialogSettings(
                function: function,
                pluginID: session.pluginID,
                values: session.values,
                config: config
            )
        }
    }

    static func switchPluginPreservingPrompt(
        function: String,
        outgoingPluginID: String?,
        outgoingValues: [String: Any],
        incomingPluginID: String,
        preservedPrompt: String,
        editingQueueJob: Bool,
        config: AppConfig
    ) -> [String: Any] {
        if editingQueueJob {
            var incoming = outgoingValues
            incoming["prompt"] = preservedPrompt
            return incoming
        }
        if let outgoingPluginID, !outgoingPluginID.isEmpty {
            var outgoing = outgoingValues
            outgoing["prompt"] = preservedPrompt
            savePluginDialogSettings(
                function: function,
                pluginID: outgoingPluginID,
                values: outgoing,
                config: config
            )
        }
        var incoming = loadPluginDialogSettings(
            function: function,
            pluginID: incomingPluginID,
            config: config
        )
        incoming["prompt"] = preservedPrompt
        applyLoraFieldsForPlugin(pluginID: incomingPluginID, to: &incoming)
        for key in preserveOnPluginSwitchKeys {
            if let value = outgoingValues[key] {
                incoming[key] = value
            }
        }
        savePluginDialogSettings(
            function: function,
            pluginID: incomingPluginID,
            values: incoming,
            config: config
        )
        return incoming
    }

    static func closeDialogOnGenerate(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["close_dialog_on_generate"] as? Bool ?? false
    }

    static func setCloseDialogOnGenerate(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["close_dialog_on_generate"] = enabled }
    }

    static func passImageToAI(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["pass_image_to_ai_with_prompt"] as? Bool ?? false
    }

    static func setPassImageToAI(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["pass_image_to_ai_with_prompt"] = enabled }
    }

    static func fluxPromptJobWithGenerate(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["flux_prompt_job_with_generate"] as? Bool ?? false
    }

    static func setFluxPromptJobWithGenerate(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["flux_prompt_job_with_generate"] = enabled }
    }

    static func fluxSystemPromptText(config: AppConfig) -> String {
        imagegenBlock(config: config)["flux_prompt_system_prompt"] as? String ?? ""
    }

    static func fluxSystemPromptExpanded(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["flux_prompt_system_prompt_expanded"] as? Bool ?? false
    }

    static func saveFluxSystemPrompt(text: String, expanded: Bool, config: AppConfig) {
        mutateImagegen(config: config) {
            $0["flux_prompt_system_prompt"] = text
            $0["flux_prompt_system_prompt_expanded"] = expanded
        }
    }

    static func snapshotSignature(_ values: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(values.count)"
        }
        return text
    }

    static func snapshotsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        snapshotSignature(lhs) == snapshotSignature(rhs)
    }
}
