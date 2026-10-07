import AppKit
import SwiftUI

@MainActor
struct ImageGenCustomSizeSection: View {
    @Environment(AppState.self) private var appState

    @Binding var values: [String: Any]
    let widthSpec: [String: Any]
    let heightSpec: [String: Any]
    let pipelineID: String
    let pluginMaxDimension: Int
    let sourcePath: String?
    /// Edit uses optional ``use_custom_size`` (Python ``mount_edit_custom_size_section``); create/expand use collapse-for-visibility only.
    var usesOptionalCustomSize: Bool = false
    var onValuesChanged: (() -> Void)?

    @State private var isExpanded = true
    @State private var aspectLock = false
    @State private var aspectRatio: Double = 1.0
    @State private var aspectLockPrevW: Int?
    @State private var aspectLockPrevH: Int?
    @State private var aspectLockUpdating = false
    @State private var settingsObserver: UUID?

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
                        ImageGenDimSliderRow(
                            label: widthSpec["label"] as? String ?? "Width",
                            key: "width",
                            minValue: widthMin,
                            maxValue: effectiveMaxSide,
                            step: dimStep,
                            resetDefault: widthSpec["reset_default"],
                            values: $values,
                            onValueChanged: { onDimValueChanged(changed: "width", value: $0) }
                        )
                        ImageGenDimSliderRow(
                            label: heightSpec["label"] as? String ?? "Height",
                            key: "height",
                            minValue: heightMin,
                            maxValue: effectiveMaxSide,
                            step: dimStep,
                            resetDefault: heightSpec["reset_default"],
                            values: $values,
                            onValueChanged: { onDimValueChanged(changed: "height", value: $0) }
                        )
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
            aspectLock = values["aspect_ratio_lock"] as? Bool ?? false
            captureAspectRatio()
            syncAspectLockPrevDims()
            applyEffectiveMaxIfNeeded()
            settingsObserver = appState.eventBus.subscribe(.settingsChanged) { _ in
                refreshGenerationDimLimits()
            }
        }
        .onDisappear {
            if let settingsObserver {
                appState.eventBus.unsubscribe(.settingsChanged, token: settingsObserver)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if usesOptionalCustomSize {
                values["use_custom_size"] = expanded
                onValuesChanged?()
            }
        }
        .onChange(of: pluginMaxDimension) { _, _ in
            refreshGenerationDimLimits()
        }
        .onChange(of: pipelineID) { _, _ in
            refreshGenerationDimLimits()
        }
    }

    private var dimStep: Int {
        max(1, widthSpec["step"] as? Int ?? 8)
    }

    private var widthMin: Int {
        widthSpec["min_value"] as? Int ?? 256
    }

    private var heightMin: Int {
        heightSpec["min_value"] as? Int ?? 256
    }

    private var effectiveMaxSide: Int {
        ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: pluginMaxDimension,
            settings: appState.config.rawSettings()
        )
    }

    private var wBounds: ImageGenDimMath.Bounds {
        ImageGenDimMath.Bounds(min: widthMin, max: effectiveMaxSide)
    }

    private var hBounds: ImageGenDimMath.Bounds {
        ImageGenDimMath.Bounds(min: heightMin, max: effectiveMaxSide)
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Toggle("Lock aspect ratio", isOn: $aspectLock)
                .help(ImageGenDimHelperTooltips.aspect)
                .onChange(of: aspectLock) { _, locked in
                    values["aspect_ratio_lock"] = locked
                    if locked {
                        captureAspectRatio()
                    }
                    syncAspectLockPrevDims()
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
        guard let sourcePath else { return nil }
        return ResizeImagesService.dimensions(for: sourcePath)
    }

    private func captureAspectRatio() {
        let width = max(1, values["width"] as? Int ?? 1024)
        let height = max(1, values["height"] as? Int ?? 1024)
        aspectRatio = Double(width) / Double(height)
    }

    private func syncAspectLockPrevDims() {
        let width = values["width"] as? Int
        let height = values["height"] as? Int
        guard let width, let height else { return }
        aspectLockPrevW = width
        aspectLockPrevH = height
    }

    private func refreshGenerationDimLimits() {
        applyEffectiveMaxIfNeeded()
        onValuesChanged?()
    }

    private func applyEffectiveMaxIfNeeded() {
        let width = values["width"] as? Int ?? 1024
        let height = values["height"] as? Int ?? 1024
        guard width > 0, height > 0 else { return }
        let (w, h, scaledDown) = ImageGenDimMath.applyEffectiveMax(
            width: width,
            height: height,
            effectiveMaxSide: effectiveMaxSide
        )
        aspectLockUpdating = true
        values["width"] = w
        values["height"] = h
        if scaledDown {
            aspectLock = true
            values["aspect_ratio_lock"] = true
            aspectRatio = Double(width) / Double(height)
        } else if aspectLock {
            captureAspectRatio()
        }
        aspectLockUpdating = false
        syncAspectLockPrevDims()
    }

    private func onDimValueChanged(changed: String, value: Int) {
        if aspectLockUpdating { return }
        if aspectLock {
            applyAspectLockedDims(changed: changed, value: value)
            return
        }
        let snapped = ImageGenDimMath.snapDimFloor(value, step: dimStep)
        let bounds = changed == "width" ? wBounds : hBounds
        let clamped = max(bounds.min, min(bounds.max, snapped))
        if clamped == value {
            syncAspectLockPrevDims()
            onValuesChanged?()
            return
        }
        aspectLockUpdating = true
        values[changed] = clamped
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
    }

    private func applyAspectLockedDims(changed: String, value: Int) {
        if aspectLockPrevW == nil || aspectLockPrevH == nil {
            syncAspectLockPrevDims()
        }
        guard let prevW = aspectLockPrevW, let prevH = aspectLockPrevH else { return }
        let oldVal = changed == "width" ? prevW : prevH
        if value == oldVal { return }
        let direction = value > oldVal ? 1 : -1
        let (w, h) = ImageGenDimMath.nextAspectLockedDims(
            changed: changed,
            direction: direction,
            currentW: prevW,
            currentH: prevH,
            ratio: aspectRatio,
            wBounds: wBounds,
            hBounds: hBounds,
            step: dimStep
        )
        if w == prevW && h == prevH {
            let currentW = values["width"] as? Int
            let currentH = values["height"] as? Int
            if currentW != prevW || currentH != prevH {
                aspectLockUpdating = true
                values["width"] = prevW
                values["height"] = prevH
                aspectLockUpdating = false
            }
            return
        }
        aspectLockUpdating = true
        values["width"] = w
        values["height"] = h
        aspectLockUpdating = false
        aspectLockPrevW = w
        aspectLockPrevH = h
        onValuesChanged?()
    }

    private func applyScreenDims() {
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1024, height: 1024)
        let sw = Int(screen.width.rounded())
        let sh = Int(screen.height.rounded())
        let aligned = ImageGenDimMath.alignDimsForPipeline(
            pipelineID: pipelineID,
            width: sw,
            height: sh,
            effectiveMaxSide: effectiveMaxSide,
            dimStep: dimStep,
            widthMin: widthMin,
            heightMin: heightMin
        )
        aspectLockUpdating = true
        values["width"] = aligned.width
        values["height"] = aligned.height
        if aspectLock {
            captureAspectRatio()
        }
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
    }

    private func applySquareDims() {
        let width = values["width"] as? Int ?? 1024
        let lo = max(widthMin, heightMin)
        let hi = min(wBounds.max, hBounds.max)
        var side = ImageGenDimMath.snapDimFloor(width, step: dimStep)
        side = max(lo, min(hi, side))
        aspectLockUpdating = true
        if aspectLock {
            aspectRatio = 1.0
        }
        values["width"] = side
        values["height"] = side
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
    }

    private func applyReverseDims() {
        let width = values["width"] as? Int ?? 1024
        let height = values["height"] as? Int ?? 1024
        aspectLockUpdating = true
        if aspectLock, width > 0 {
            aspectRatio = Double(height) / Double(width)
        }
        values["width"] = height
        values["height"] = width
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
    }

    private func applyImportDims() {
        guard sourcePath != nil else {
            StyledMessageDialog.showWarning(title: "Import Size", message: "No image selected.")
            return
        }
        guard let size = sourcePixelSize() else {
            StyledMessageDialog.showWarning(
                title: "Import Size",
                message: "Could not read image dimensions."
            )
            return
        }
        let srcW = size.width
        let srcH = size.height
        let aligned = ImageGenDimMath.alignDimsForPipeline(
            pipelineID: pipelineID,
            width: srcW,
            height: srcH,
            effectiveMaxSide: effectiveMaxSide,
            dimStep: dimStep,
            widthMin: widthMin,
            heightMin: heightMin
        )
        let scaledDown = aligned.width < srcW || aligned.height < srcH
        aspectLockUpdating = true
        values["width"] = aligned.width
        values["height"] = aligned.height
        if scaledDown {
            aspectLock = true
            values["aspect_ratio_lock"] = true
            aspectRatio = Double(srcW) / Double(srcH)
        } else if aspectLock {
            captureAspectRatio()
        }
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
    }

    private func applyAreaScale(multiplier: Double) {
        let width = values["width"] as? Int ?? 1024
        let height = values["height"] as? Int ?? 1024
        let ratio = aspectLock ? aspectRatio : (height > 0 ? Double(width) / Double(height) : 1.0)
        let scaled = ImageGenDimMath.scaleDimsForAreaMultiplier(
            width: width,
            height: height,
            multiplier: multiplier,
            pipelineID: pipelineID,
            effectiveMaxSide: effectiveMaxSide,
            wBounds: wBounds,
            hBounds: hBounds,
            step: dimStep,
            ratio: ratio,
            widthMin: widthMin,
            heightMin: heightMin
        )
        if scaled.width == width, scaled.height == height { return }
        aspectLockUpdating = true
        values["width"] = scaled.width
        values["height"] = scaled.height
        if aspectLock {
            captureAspectRatio()
        }
        aspectLockUpdating = false
        syncAspectLockPrevDims()
        onValuesChanged?()
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
