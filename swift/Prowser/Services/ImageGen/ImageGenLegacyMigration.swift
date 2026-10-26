import Foundation

/// Port of ``migrate_legacy_z_image_plugin_id`` / ``migrate_legacy_imagegen_block``.
enum ImageGenLegacyMigration {
    static let legacySDNQPluginID = "z_image_turbo_sdnq_int8"
    static let zImageMflux4BitPluginID = "z_image_turbo_mflux_4bit"

    static func migrateLegacyImageGenPluginID(_ pluginID: String) -> String {
        if pluginID == legacySDNQPluginID { return zImageMflux4BitPluginID }
        return pluginID
    }

    @discardableResult
    static func migrateImageGenBlock(_ imagegen: inout [String: Any]) -> Bool {
        var changed = false
        if var byFn = imagegen["active_plugin_by_function"] as? [String: Any] {
            for (fn, pid) in byFn {
                guard let raw = pid as? String else { continue }
                let migrated = migrateLegacyImageGenPluginID(raw)
                if migrated != raw {
                    byFn[fn] = migrated
                    changed = true
                }
            }
            imagegen["active_plugin_by_function"] = byFn
        }
        guard var dialogs = imagegen["dialogs"] as? [String: Any] else { return changed }
        for (dialogKey, entryValue) in dialogs {
            guard var entry = entryValue as? [String: Any] else { continue }
            var entryChanged = false
            if var pluginSettings = entry["plugin_settings"] as? [String: Any],
               let legacy = pluginSettings.removeValue(forKey: legacySDNQPluginID) as? [String: Any] {
                var legacyValues = legacy
                if legacyValues["mflux_quantize"] == nil {
                    legacyValues["mflux_quantize"] = 4
                }
                let existing = pluginSettings[zImageMflux4BitPluginID] as? [String: Any]
                if existing == nil || existing?.isEmpty == true {
                    pluginSettings[zImageMflux4BitPluginID] = legacyValues
                }
                entry["plugin_settings"] = pluginSettings
                entryChanged = true
            }
            if var stacks = entry["lora_stacks"] as? [String: Any],
               let legacyStack = stacks.removeValue(forKey: legacySDNQPluginID) {
                if stacks[zImageMflux4BitPluginID] == nil {
                    stacks[zImageMflux4BitPluginID] = legacyStack
                }
                entry["lora_stacks"] = stacks
                entryChanged = true
            }
            if entryChanged {
                dialogs[dialogKey] = entry
                changed = true
            }
        }
        if changed {
            imagegen["dialogs"] = dialogs
        }
        return changed
    }
}
