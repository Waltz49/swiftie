import AppKit
import SwiftUI

@MainActor
struct ImageGenCustomSizeSection: View {
    @Binding var values: [String: Any]
    let widthSpec: [String: Any]
    let heightSpec: [String: Any]
    let sourcePath: String?
    /// Edit uses optional ``use_custom_size`` (Python ``mount_edit_custom_size_section``); create/expand use collapse-for-visibility only.
    var usesOptionalCustomSize: Bool = false
    var onValuesChanged: (() -> Void)?

    @State private var isExpanded = true
    @State private var aspectLock = false
    @State private var aspectRatio: Double = 1.0

    var body: some View {
        ImageGenCollapsibleSection(
            title: headerTitle,
            isExpanded: $isExpanded,
            tooltip: "Override output dimensions when enabled."
        ) {
            if isExpanded {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 8) {
                        controlsRow
                        ImageGenIntSliderRow(
                            label: widthSpec["label"] as? String ?? "Width",
                            key: "width",
                            minValue: widthSpec["min_value"] as? Int ?? 256,
                            maxValue: widthSpec["max_value"] as? Int ?? 2048,
                            step: widthSpec["step"] as? Int ?? 8,
                            resetDefault: widthSpec["reset_default"],
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
                            resetDefault: heightSpec["reset_default"],
                            values: $values
                        )
                        .onChange(of: values["height"] as? Int) { _, _ in
                            applyAspectLock(changed: "height")
                            onValuesChanged?()
                        }
                    }
                    VStack(spacing: 4) {
                        ImageGenDimHelperIconButton(
                            normalName: "sizeX2",
                            hoverName: "sizeX2_hover",
                            tooltip: ImageGenDimHelperTooltips.doubleArea,
                            action: { applyAreaScale(multiplier: 2.0) }
                        )
                        ImageGenDimHelperIconButton(
                            normalName: "sizeD2",
                            hoverName: "sizeD2_hover",
                            tooltip: ImageGenDimHelperTooltips.halfArea,
                            action: { applyAreaScale(multiplier: 0.5) }
                        )
                    }
                }
            }
        }
        .onAppear {
            if usesOptionalCustomSize {
                isExpanded = values["use_custom_size"] as? Bool ?? false
            }
            aspectLock = values["aspect_lock"] as? Bool ?? false
            captureAspectRatio()
        }
        .onChange(of: isExpanded) { _, expanded in
            if usesOptionalCustomSize {
                values["use_custom_size"] = expanded
                onValuesChanged?()
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Toggle("Lock aspect ratio", isOn: $aspectLock)
                .help(ImageGenDimHelperTooltips.aspect)
                .onChange(of: aspectLock) { _, locked in
                    values["aspect_lock"] = locked
                    if locked {
                        captureAspectRatio()
                    }
                    onValuesChanged?()
                }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ImageGenDimHelperIconButton(
                    normalName: "dim_square_icon",
                    hoverName: "dim_square_icon_hover",
                    tooltip: ImageGenDimHelperTooltips.square,
                    action: applySquareDims
                )
                ImageGenDimHelperIconButton(
                    normalName: "dim_reverse_icon",
                    hoverName: "dim_reverse_icon_hover",
                    tooltip: ImageGenDimHelperTooltips.reverse,
                    action: applyReverseDims
                )
                ImageGenDimHelperIconButton(
                    normalName: "dim_screen_icon",
                    hoverName: "dim_screen_icon_hover",
                    tooltip: ImageGenDimHelperTooltips.screenSize,
                    action: applyScreenDims
                )
                ImageGenDimHelperIconButton(
                    normalName: "import_icon",
                    hoverName: "import_icon_hover",
                    tooltip: ImageGenDimHelperTooltips.importSize,
                    action: applyImportDims
                )
            }
        }
    }

    private var headerTitle: String {
        if usesOptionalCustomSize {
            let base = isExpanded ? "Custom Size" : "Use Custom Size"
            guard !isExpanded, let size = sourcePixelSize() else { return base }
            return "\(base) ( Current: \(size.width) x \(size.height) )"
        }
        let base = isExpanded ? "Custom Size" : "Use Custom Size"
        guard !isExpanded else { return base }
        let width = values["width"] as? Int ?? Int(widthSpec["reset_default"] as? Int ?? 1024)
        let height = values["height"] as? Int ?? Int(heightSpec["reset_default"] as? Int ?? 1024)
        return "\(base) ( Current: \(width) x \(height) )"
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

    private func widthBounds() -> (min: Int, max: Int, step: Int) {
        (
            widthSpec["min_value"] as? Int ?? 256,
            widthSpec["max_value"] as? Int ?? 2048,
            widthSpec["step"] as? Int ?? 8
        )
    }

    private func heightBounds() -> (min: Int, max: Int, step: Int) {
        (
            heightSpec["min_value"] as? Int ?? 256,
            heightSpec["max_value"] as? Int ?? 2048,
            heightSpec["step"] as? Int ?? 8
        )
    }

    private func setDims(width: Int, height: Int) {
        let wb = widthBounds()
        let hb = heightBounds()
        let w = ImageGenDimScaleLogic.snap(width, step: wb.step, min: wb.min, max: wb.max)
        let h = ImageGenDimScaleLogic.snap(height, step: hb.step, min: hb.min, max: hb.max)
        values["width"] = w
        values["height"] = h
        if aspectLock {
            captureAspectRatio()
        }
        onValuesChanged?()
    }

    private func applyScreenDims() {
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1024, height: 1024)
        setDims(width: Int(screen.width.rounded()), height: Int(screen.height.rounded()))
    }

    private func applySquareDims() {
        let wb = widthBounds()
        let hb = heightBounds()
        let lo = max(wb.min, hb.min)
        let hi = min(wb.max, hb.max)
        let width = values["width"] as? Int ?? 1024
        var side = ImageGenDimScaleLogic.snap(width, step: wb.step, min: lo, max: hi)
        side = max(lo, min(hi, side))
        if aspectLock {
            aspectRatio = 1.0
        }
        setDims(width: side, height: side)
    }

    private func applyReverseDims() {
        let width = values["width"] as? Int ?? 1024
        let height = values["height"] as? Int ?? 1024
        if aspectLock, width > 0 {
            aspectRatio = Double(height) / Double(width)
        }
        setDims(width: height, height: width)
    }

    private func applyImportDims() {
        guard let size = sourcePixelSize() else { return }
        setDims(width: size.width, height: size.height)
    }

    private func applyAreaScale(multiplier: Double) {
        let width = values["width"] as? Int ?? 1024
        let height = values["height"] as? Int ?? 1024
        let ratio = aspectLock ? aspectRatio : (height > 0 ? Double(width) / Double(height) : 1.0)
        let scaled = ImageGenDimScaleLogic.scaleForAreaMultiplier(
            width: width,
            height: height,
            multiplier: multiplier,
            ratio: ratio,
            widthBounds: widthBounds(),
            heightBounds: heightBounds()
        )
        if scaled.width == width, scaled.height == height { return }
        setDims(width: scaled.width, height: scaled.height)
    }
}

enum ImageGenDimHelperTooltips {
    static let importSize =
        "Import size from the\n"
        + "dimensions of the selected image."
    static let screenSize =
        "Set size to fit your screen.\n"
        + "Limited by aspect ratio lock and\n"
        + "max size from Settings Dialog."
    static let square = "Square:\nMake width and height equal."
    static let reverse = "Reverse:\nSwap width and height."
    static let aspect =
        "Keep width and height proportional\nwhen either dimension is changed."
    static let doubleArea =
        "Double the pixel area (width × height),\n"
        + "keeping aspect ratio.\n"
        + "Limited by min/max size and Settings."
    static let halfArea =
        "Halve the pixel area (width × height),\n"
        + "keeping aspect ratio.\n"
        + "Limited by min/max size and Settings."
}

enum ImageGenDimScaleLogic {
    static func snap(_ value: Int, step: Int, min minValue: Int, max maxValue: Int) -> Int {
        let stepValue = max(1, step)
        let snapped = ((value + stepValue / 2) / stepValue) * stepValue
        return max(minValue, min(maxValue, snapped))
    }

    static func scaleForAreaMultiplier(
        width: Int,
        height: Int,
        multiplier: Double,
        ratio: Double,
        widthBounds: (min: Int, max: Int, step: Int),
        heightBounds: (min: Int, max: Int, step: Int)
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0, ratio > 0, multiplier > 0 else {
            return (width, height)
        }
        let area = Double(width * height) * multiplier
        var newWidth = Int(sqrt(area * ratio).rounded())
        var newHeight = Int(sqrt(area / ratio).rounded())
        newWidth = snap(newWidth, step: widthBounds.step, min: widthBounds.min, max: widthBounds.max)
        newHeight = snap(newHeight, step: heightBounds.step, min: heightBounds.min, max: heightBounds.max)
        return (newWidth, newHeight)
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
            if key == "mflux_lora" || key == "mflux_lora_stack" {
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
