import AppKit
import SwiftUI

@MainActor
struct ImageGenCustomSizeSection: View {
    @Binding var values: [String: Any]
    let widthSpec: [String: Any]
    let heightSpec: [String: Any]
    let sourcePath: String?
    var onValuesChanged: (() -> Void)?

    @State private var isExpanded = false
    @State private var aspectLock = false
    @State private var aspectRatio: Double = 1.0

    var body: some View {
        ImageGenCollapsibleSection(
            title: headerTitle,
            isExpanded: $isExpanded,
            tooltip: "Override output dimensions when enabled."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if values["use_custom_size"] as? Bool ?? false {
                    Toggle("Lock aspect ratio", isOn: $aspectLock)
                        .onChange(of: aspectLock) { _, locked in
                            values["aspect_lock"] = locked
                            if locked {
                                captureAspectRatio()
                            }
                            onValuesChanged?()
                        }
                    ImageGenIntSliderRow(
                        label: widthSpec["label"] as? String ?? "Width",
                        key: "width",
                        minValue: widthSpec["min_value"] as? Int ?? 256,
                        maxValue: widthSpec["max_value"] as? Int ?? 2048,
                        step: widthSpec["step"] as? Int ?? 8,
                        presetValues: ImageGenSliderPresets.intPresets(
                            key: "width",
                            min: widthSpec["min_value"] as? Int ?? 256,
                            max: widthSpec["max_value"] as? Int ?? 2048,
                            step: widthSpec["step"] as? Int ?? 8,
                            choices: widthSpec["choices"] as? [Any]
                        ),
                        values: $values
                    )
                    .onChange(of: values["width"] as? Int) { _, _ in
                        applyAspectLock(changed: "width")
                        onValuesChanged?()
                    }
                    ImageGenIntSliderRow(
                        label: heightSpec["label"] as? String ?? "Height",
                        key: "height",
                        minValue: heightSpec["min_value"] as? Int ?? 256,
                        maxValue: heightSpec["max_value"] as? Int ?? 2048,
                        step: heightSpec["step"] as? Int ?? 8,
                        presetValues: ImageGenSliderPresets.intPresets(
                            key: "height",
                            min: heightSpec["min_value"] as? Int ?? 256,
                            max: heightSpec["max_value"] as? Int ?? 2048,
                            step: heightSpec["step"] as? Int ?? 8,
                            choices: heightSpec["choices"] as? [Any]
                        ),
                        values: $values
                    )
                    .onChange(of: values["height"] as? Int) { _, _ in
                        applyAspectLock(changed: "height")
                        onValuesChanged?()
                    }
                }
            }
        }
        .onAppear {
            isExpanded = values["use_custom_size"] as? Bool ?? false
            aspectLock = values["aspect_lock"] as? Bool ?? false
            captureAspectRatio()
        }
        .onChange(of: isExpanded) { _, expanded in
            values["use_custom_size"] = expanded
            onValuesChanged?()
        }
    }

    private var headerTitle: String {
        let base = isExpanded ? "Custom Size" : "Use Custom Size"
        guard !isExpanded, let size = sourcePixelSize() else { return base }
        return "\(base) ( Current: \(size.width) x \(size.height) )"
    }

    private func sourcePixelSize() -> (width: Int, height: Int)? {
        guard let sourcePath, let image = NSImage(contentsOfFile: sourcePath) else { return nil }
        let size = image.size
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func captureAspectRatio() {
        let width = max(1, values["width"] as? Int ?? 1024)
        let height = max(1, values["height"] as? Int ?? 1024)
        aspectRatio = Double(width) / Double(height)
    }

    private func applyAspectLock(changed: String) {
        guard aspectLock, aspectRatio > 0 else { return }
        if changed == "width" {
            let width = max(1, values["width"] as? Int ?? 1024)
            let height = max(1, Int((Double(width) / aspectRatio).rounded()))
            values["height"] = height
        } else {
            let height = max(1, values["height"] as? Int ?? 1024)
            let width = max(1, Int((Double(height) * aspectRatio).rounded()))
            values["width"] = width
        }
    }
}

enum ImageGenFieldLayoutFilter {
    static func dimensionSpecs(from layout: [[String: Any]]) -> (width: [String: Any]?, height: [String: Any]?) {
        var width: [String: Any]?
        var height: [String: Any]?
        walk(layout) { spec in
            let key = spec["key"] as? String ?? ""
            if key == "width" { width = spec }
            if key == "height" { height = spec }
        }
        return (width, height)
    }

    static func layoutExcludingDimensionsAndPrompt(_ layout: [[String: Any]]) -> [[String: Any]] {
        layout.compactMap { filterNode($0) }
    }

    private static func filterNode(_ node: [String: Any]) -> [String: Any]? {
        let type = node["type"] as? String ?? "field"
        if type == "group" {
            let layoutName = node["layout"] as? String ?? ""
            if layoutName == "prompt_block" { return nil }
            var copy = node
            if let children = node["children"] as? [[String: Any]] {
                let filtered = children.compactMap { filterNode($0) }
                if filtered.isEmpty { return nil }
                copy["children"] = filtered
            }
            return copy
        }
        if let spec = node["spec"] as? [String: Any] {
            let key = spec["key"] as? String ?? ""
            if key == "width" || key == "height" || key == "prompt" || key == "negative_prompt" {
                return nil
            }
        }
        return node
    }

    static func containsField(_ layout: [[String: Any]], key: String) -> Bool {
        var found = false
        walk(layout) { spec in
            if spec["key"] as? String == key { found = true }
        }
        return found
    }

    private static func walk(_ layout: [[String: Any]], visit: ([String: Any]) -> Void) {
        for node in layout {
            let type = node["type"] as? String ?? "field"
            if type == "group", let children = node["children"] as? [[String: Any]] {
                walk(children, visit: visit)
            } else if let spec = node["spec"] as? [String: Any] {
                visit(spec)
            }
        }
    }
}
