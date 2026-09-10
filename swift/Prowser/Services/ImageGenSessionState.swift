import Foundation

@MainActor
final class ImageGenSessionState {
    private var valuesByFunction: [String: [String: Any]] = [:]
    private var pluginIDByFunction: [String: String] = [:]

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
        return imagegen["last_function"] as? String ?? "create"
    }

    func saveLastFunction(_ function: String, config: AppConfig) {
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen["last_function"] = function
        config.updateSetting("imagegen", value: imagegen)
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

struct ImageGenDialogRequest {
    var function: String
    var replaceJobID: String?
    var initialPrompt: String?
    var autoImportEXIF: Bool
    var editSourcePaths: [String]

    static let empty = ImageGenDialogRequest(
        function: "create",
        replaceJobID: nil,
        initialPrompt: nil,
        autoImportEXIF: false,
        editSourcePaths: []
    )
}
