import Foundation

enum LoRAModelRegistry {
    struct RegistryModel: Equatable, Sendable {
        var modelKey: String
        var displayName: String
        var availableIn: [String]
    }

    private static let functionDisplayOrder = ["create", "edit", "expand", "infill", "infill_paint"]
    private static let functionShortLabels: [String: String] = [
        "create": "Create",
        "edit": "Edit",
        "expand": "Expand",
        "infill": "Infill",
        "infill_paint": "Infill",
    ]

    private static let settingsModels: [RegistryModel] = [
        .init(modelKey: LoRAHFModelIDs.flux1Schnell, displayName: LoRAHFModelIDs.flux1Schnell, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.flux1Dev, displayName: LoRAHFModelIDs.flux1Dev, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.flux1FillDev, displayName: LoRAHFModelIDs.flux1FillDev, availableIn: ["expand", "infill"]),
        .init(modelKey: LoRAHFModelIDs.flux2Klein4B, displayName: LoRAHFModelIDs.flux2Klein4B, availableIn: ["create", "edit"]),
        .init(modelKey: LoRAHFModelIDs.flux2Klein9B, displayName: LoRAHFModelIDs.flux2Klein9B, availableIn: ["create", "edit"]),
        .init(modelKey: LoRAHFModelIDs.flux2Klein9BKV, displayName: LoRAHFModelIDs.flux2Klein9BKV, availableIn: ["create", "edit"]),
        .init(
            modelKey: LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
            displayName: LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
            availableIn: ["create", "edit", "expand"]
        ),
        .init(modelKey: LoRAHFModelIDs.sd15BaseV15, displayName: LoRAHFModelIDs.sd15BaseV15, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.realisticVisionV4NoVAE, displayName: LoRAHFModelIDs.realisticVisionV4NoVAE, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.realisticVisionV6NoVAE, displayName: LoRAHFModelIDs.realisticVisionV6NoVAE, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.anythingFurry, displayName: LoRAHFModelIDs.anythingFurry, availableIn: ["create"]),
        .init(modelKey: LoRAHFModelIDs.sdxlBase10, displayName: LoRAHFModelIDs.sdxlBase10, availableIn: ["create"]),
        .init(
            modelKey: LoRAHFModelIDs.zImageTurboMflux4Bit,
            displayName: LoRAHFModelIDs.displayName(for: LoRAHFModelIDs.zImageTurboMflux4Bit),
            availableIn: ["create"]
        ),
        .init(
            modelKey: LoRAHFModelIDs.zImageTurbo,
            displayName: LoRAHFModelIDs.displayName(for: LoRAHFModelIDs.zImageTurbo),
            availableIn: ["create"]
        ),
    ]

    static func modelsForSettings() -> [RegistryModel] {
        let byKey = Dictionary(uniqueKeysWithValues: settingsModels.map { ($0.modelKey, $0) })
        return LoRAHFModelIDs.probeModelOrder.compactMap { byKey[$0] }
    }

    static func hostID(forModelKey modelKey: String) -> String? {
        let mk = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if mk == LoRAHFModelIDs.flux1Schnell || mk == LoRAHFModelIDs.flux1Dev { return LoRAHostRegistry.flux1T2I }
        if mk == LoRAHFModelIDs.flux1FillDev { return LoRAHostRegistry.flux1Fill }
        if [
            LoRAHFModelIDs.flux2Klein4B, LoRAHFModelIDs.flux2Klein9B,
            LoRAHFModelIDs.flux2Klein9BKV, LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
        ].contains(mk) { return LoRAHostRegistry.flux2Klein }
        if LoRAHFModelIDs.sd15LoraModelKeys.contains(mk) { return LoRAHostRegistry.sd15 }
        if LoRAHFModelIDs.sdxlLoraModelKeys.contains(mk) { return LoRAHostRegistry.sdxl }
        if mk == LoRAHFModelIDs.zImageTurboMflux4Bit || mk == LoRAHFModelIDs.zImageTurbo {
            return LoRAHostRegistry.zImageTurbo
        }
        return nil
    }

    static func modelsForEntry(_ entry: LoRAEntry) -> [String] {
        if entry.hostID == LoRAHostRegistry.sd15 { return LoRAHFModelIDs.sd15LoraModelKeys }
        if entry.hostID == LoRAHostRegistry.sdxl { return LoRAHFModelIDs.sdxlLoraModelKeys }
        if !entry.baseHFModelID.isEmpty { return [entry.baseHFModelID] }
        if entry.hostID == LoRAHostRegistry.flux1Fill { return [LoRAHFModelIDs.flux1FillDev] }
        if entry.hostID == LoRAHostRegistry.flux1T2I { return [LoRAHFModelIDs.flux1Schnell, LoRAHFModelIDs.flux1Dev] }
        if entry.hostID == LoRAHostRegistry.flux2Klein {
            return flux2KleinLoraCatalogModelKeys()
        }
        if entry.hostID == LoRAHostRegistry.zImageTurbo {
            return [LoRAHFModelIDs.zImageTurboMflux4Bit, LoRAHFModelIDs.zImageTurbo]
        }
        return []
    }

    static func kleinAliases(for modelKey: String) -> [String] {
        let mk = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if mk == LoRAHFModelIDs.flux2Klein9BKV { return [LoRAHFModelIDs.flux2Klein9BKV, LoRAHFModelIDs.flux2Klein9B] }
        if mk == LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX {
            return [
                LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
                LoRAHFModelIDs.flux2Klein9BKV,
                LoRAHFModelIDs.flux2Klein9B,
            ]
        }
        return mk.isEmpty ? [] : [mk]
    }

    /// Z-Image 4-bit weights vs Tongyi full weights share one LoRA catalog slice (Python ``Z_IMAGE_TURBO`` on both plugins).
    static func zImageLoraModelKeys() -> [String] {
        [LoRAHFModelIDs.zImageTurbo, LoRAHFModelIDs.zImageTurboMflux4Bit]
    }

    /// All Klein HF ids for catalog entry metadata (includes 4B).
    static func flux2KleinLoraCatalogModelKeys() -> [String] {
        [
            LoRAHFModelIDs.flux2Klein4B,
            LoRAHFModelIDs.flux2Klein9B,
            LoRAHFModelIDs.flux2Klein9BKV,
            LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
        ]
    }

    /// Klein 9B-family: shared ``by_model.enabled_ids`` reads and ``model_support`` interpretation (excludes 4B).
    static func flux2KleinSharedRunDialogModelKeys() -> [String] {
        [
            LoRAHFModelIDs.flux2Klein9B,
            LoRAHFModelIDs.flux2Klein9BKV,
            LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX,
        ]
    }

    /// Keys for ``by_model.enabled_ids`` in the image-gen run dialog (Z-Image shares one slice; Klein 9B-family shares, not 4B).
    static func loraCatalogModelKeys(forPlugin plugin: ImageGenPluginDescriptor) -> [String] {
        let hf = plugin.hfModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if hf == LoRAHFModelIDs.zImageTurboMflux4Bit || hf == LoRAHFModelIDs.zImageTurbo {
            return zImageLoraModelKeys()
        }
        if plugin.loraHostID == LoRAHostRegistry.flux2Klein {
            if hf == LoRAHFModelIDs.flux2Klein4B {
                return [LoRAHFModelIDs.flux2Klein4B]
            }
            let klein9BFamily = flux2KleinSharedRunDialogModelKeys()
            if klein9BFamily.contains(hf) {
                return klein9BFamily
            }
        }
        return hf.isEmpty ? [] : [hf]
    }

    /// Model key for probe results / Check LoRAs when plugin reports the 4-bit HF id.
    static func loraProbeModelKey(forModelKey modelKey: String) -> String {
        let mk = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if mk == LoRAHFModelIDs.zImageTurboMflux4Bit {
            return LoRAHFModelIDs.zImageTurbo
        }
        return mk
    }

    static func loraProbeModelKey(forPlugin plugin: ImageGenPluginDescriptor) -> String {
        loraProbeModelKey(forModelKey: plugin.hfModelID)
    }

    /// Shared storage key for Settings → LoRA enablement (both Z-Image picker rows).
    static func canonicalSettingsModelKey(_ modelKey: String) -> String {
        loraProbeModelKey(forModelKey: modelKey)
    }

    static func entryMatchesModel(
        _ entry: LoRAEntry,
        modelKey: String,
        modelSupport: [String: [String]]
    ) -> Bool {
        if probeSupportedOnModel(entry: entry, modelKey: modelKey, modelSupport: modelSupport) {
            return true
        }
        if LoRAEntry.isUserLoraID(entry.loraID) {
            let expected = hostID(forModelKey: modelKey)
            if let expected, entry.hostID != expected { return false }
            return true
        }
        let entryModels = modelsForEntry(entry)
        let aliases = kleinAliases(for: modelKey)
        return aliases.contains(where: { entryModels.contains($0) })
    }

    static func probeSupportedOnModel(
        entry: LoRAEntry,
        modelKey: String,
        modelSupport: [String: [String]]
    ) -> Bool {
        let supported = modelSupport[entry.loraID] ?? []
        if supported.isEmpty { return false }
        let supportedSet = Set(supported)
        if kleinAliases(for: modelKey).contains(where: { supportedSet.contains($0) }) {
            return true
        }
        guard modelKey != LoRAHFModelIDs.flux2Klein4B,
              hostID(forModelKey: modelKey) == LoRAHostRegistry.flux2Klein,
              entry.hostID == LoRAHostRegistry.flux2Klein
        else { return false }
        let klein9BFamily = Set(flux2KleinSharedRunDialogModelKeys())
        return supported.contains(where: { klein9BFamily.contains($0) })
    }

    static func isCrossFamily(entry: LoRAEntry, modelKey: String) -> Bool {
        let entryHost = entry.hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelHost = hostID(forModelKey: modelKey) ?? ""
        if entryHost.isEmpty || modelHost.isEmpty { return false }
        return entryHost != modelHost
    }

    static func functionsForModelKey(_ modelKey: String) -> [String] {
        var found: [String] = []
        for fn in functionDisplayOrder {
            for plugin in ImageGenPluginCatalog.allPlugins() {
                guard plugin.hfModelID == modelKey, plugin.loraHostID != nil else { continue }
                guard plugin.function == fn else { continue }
                if !found.contains(fn) { found.append(fn) }
                break
            }
        }
        if !found.isEmpty { return found }
        return settingsModels.first(where: { $0.modelKey == modelKey })?.availableIn ?? []
    }

    static func availableInLabel(modelKey: String) -> String {
        var labels: [String] = []
        for fn in functionsForModelKey(modelKey) {
            let label = functionShortLabels[fn] ?? fn
            if !labels.contains(label) { labels.append(label) }
        }
        if labels.isEmpty { return "" }
        return "Available in: " + labels.joined(separator: ", ")
    }
}
