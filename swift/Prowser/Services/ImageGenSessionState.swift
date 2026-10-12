import Foundation

@MainActor
final class ImageGenSessionState {
    private static let supportedFunctions = ["create", "edit", "expand", "infill"]
    private var valuesByFunction: [String: [String: Any]] = [:]
    private var pluginIDByFunction: [String: String] = [:]
    private var infillMaskPNGByFunction: [String: Data] = [:]
    private var infillPixelmatorDocPathByFunction: [String: String] = [:]

    func values(for function: String) -> [String: Any] {
        valuesByFunction[function] ?? [:]
    }

    func setValues(_ values: [String: Any], for function: String) {
        valuesByFunction[function] = values
    }

    func pluginID(for function: String) -> String? {
        pluginIDByFunction[function]
    }

    func setPluginID(_ pluginID: String, for function: String) {
        pluginIDByFunction[function] = pluginID
    }

    func lastFunction(config: AppConfig) -> String {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        guard let function = imagegen["last_function"] as? String,
              Self.supportedFunctions.contains(function) else {
            return "create"
        }
        return function
    }

    func saveLastFunction(_ function: String, config: AppConfig) {
        guard Self.supportedFunctions.contains(function) else { return }
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen["last_function"] = function
        config.updateSetting("imagegen", value: imagegen)
    }

    func infillMaskPNGData(for function: String = "infill") -> Data? {
        infillMaskPNGByFunction[function]
    }

    func setInfillMaskPNGData(_ data: Data?, for function: String = "infill") {
        if let data, !data.isEmpty {
            infillMaskPNGByFunction[function] = data
        } else {
            infillMaskPNGByFunction.removeValue(forKey: function)
        }
    }

    func infillPixelmatorDocPath(for function: String = "infill") -> String? {
        infillPixelmatorDocPathByFunction[function]
    }

    func setInfillPixelmatorDocPath(_ path: String?, for function: String = "infill") {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            infillPixelmatorDocPathByFunction.removeValue(forKey: function)
        } else {
            infillPixelmatorDocPathByFunction[function] = trimmed
        }
    }

    func reset() {
        valuesByFunction.removeAll()
        pluginIDByFunction.removeAll()
        infillMaskPNGByFunction.removeAll()
        infillPixelmatorDocPathByFunction.removeAll()
    }

    func copyValues(_ values: [String: Any]) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return values
        }
        return copy
    }
}

struct ImageGenDialogRequest: Equatable {
    var function: String
    var replaceJobID: String?
    var initialPrompt: String?
    var autoImportEXIF: Bool
    var autoGenerate: Bool
    var editSourcePaths: [String]

    static let empty = ImageGenDialogRequest(
        function: "create",
        replaceJobID: nil,
        initialPrompt: nil,
        autoImportEXIF: false,
        autoGenerate: false,
        editSourcePaths: []
    )
}
