import AppKit
import SwiftUI

@MainActor
struct ResizeImagesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors

    @State private var width = 1920
    @State private var height = 1080
    @State private var refWidth = 1
    @State private var refHeight = 1
    private enum ResizeMode: String {
        case dimensions
        case percent
    }

    @State private var resizeMode: ResizeMode = .dimensions
    @State private var percentScale = ResizeImagesService.percentScaleDefault
    @State private var preserveAspect = true
    @State private var anchorIsWidth = true
    @State private var resampleMethod = ResizeImagesService.ResampleMethod.lanczos
    @State private var preserveDates = true
    @State private var deleteOriginal = false
    @State private var isResizing = false
    @State private var updating = false
    /// When the slider switches to percent mode, skip resetting to the default scale (Python: `_on_percent_changed` vs `_on_percent_radio_clicked`).
    @State private var percentChangeFromSlider = false

    private var paths: [String] { appState.fileOpsTargetPaths }

    private var percentAllowed: Bool {
        ResizeImagesService.percentModeAllowed(refWidth: refWidth, refHeight: refHeight)
    }

    private var dimSpinMax: Int {
        percentAllowed ? ResizeImagesService.maxResizeDimension : max(refWidth, refHeight)
    }

    private var maxPercent: Int {
        ResizeImagesService.maxPercentForReference(refWidth: refWidth, refHeight: refHeight)
    }

    private var finalSizeText: String {
        if resizeMode == .percent && percentAllowed {
            let dims = ResizeImagesService.dimensionsFromPercent(
                refWidth: refWidth,
                refHeight: refHeight,
                percent: percentScale
            )
            return "Final size: \(dims.width) × \(dims.height) pixels (\(percentScale)%)"
        }
        return "Final size: \(width) × \(height) pixels"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(paths.count > 1 ? "Resize Images" : "Resize Image")
                .font(.headline)

            Text("Current size: \(refWidth) × \(refHeight) pixels")
                .font(.caption)
                .foregroundStyle(colors.dialogMutedText)

            if paths.count > 1 {
                Text("\(paths.count) files will be resized.")
                    .font(.caption)
                    .foregroundStyle(colors.dialogMutedText)
            }

            Picker("Mode", selection: $resizeMode) {
                Text("Dimensions").tag(ResizeMode.dimensions)
                Text("Percent").tag(ResizeMode.percent)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: resizeMode) { _, newMode in
                if newMode == .percent {
                    if percentAllowed {
                        if percentChangeFromSlider {
                            percentChangeFromSlider = false
                        } else {
                            percentScale = min(ResizeImagesService.percentScaleDefault, maxPercent)
                        }
                    } else {
                        resizeMode = .dimensions
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Width:")
                    TextField("", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: width) { _, _ in onWidthChanged() }
                    Text("Height:")
                    TextField("", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: height) { _, _ in onHeightChanged() }
                }

                HStack(spacing: 4) {
                    Spacer(minLength: 0)
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
            .padding(.leading, 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(percentScale) },
                            set: { onPercentChanged(Int($0.rounded())) }
                        ),
                        in: Double(ResizeImagesService.percentScaleMin)...Double(maxPercent),
                        step: 1
                    )
                    .disabled(!percentAllowed)
                    Text("\(percentScale)%")
                        .frame(width: 42, alignment: .trailing)
                        .foregroundStyle(percentAllowed ? colors.dialogText : colors.dialogMutedText)
                }
            }
            .padding(.leading, 20)

            if !percentAllowed {
                Text("Percent scaling is unavailable when either side exceeds \(ResizeImagesService.maxResizeDimension) pixels.")
                    .font(.caption2)
                    .foregroundStyle(colors.dialogMutedText)
            }

            Text(finalSizeText)
                .font(.caption)

            Toggle("Preserve aspect ratio", isOn: $preserveAspect)
                .onChange(of: preserveAspect) { _, checked in
                    selectDimensionsMode()
                    if checked {
                        anchorIsWidth = true
                        applyPreserveFromWidth()
                    }
                }

            HStack {
                Text("Method:")
                Picker("", selection: $resampleMethod) {
                    ForEach(ResizeImagesService.ResampleMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .labelsHidden()
            }

            Toggle("Preserve date (copy original modification time to output)", isOn: $preserveDates)

            Toggle("Delete original file (replace in place)", isOn: $deleteOriginal)
                .help("When unchecked, a copy is saved as name-0001.ext and the original is kept.")

            DialogButtonRow([
                DialogButton("Cancel", isDefault: true, isCancel: true, isEnabled: !isResizing) { dismiss() },
                DialogButton("Resize", isEnabled: !(isResizing || paths.isEmpty)) { resize() },
            ])
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 480)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.resizeImages,
            defaultWidth: 440,
            defaultHeight: 520,
            minWidth: 400,
            minHeight: 440
        )
        .onAppear { loadFromSettings() }
    }

    @MainActor
    private func loadFromSettings() {
        let settings = appState.config.rawSettings()
        preserveAspect = appState.config.bool(forKey: "resize_preserve_aspect", default: true)
        preserveDates = appState.config.bool(forKey: "resize_preserve_dates", default: true)
        deleteOriginal = appState.config.bool(forKey: "resize_delete_original", default: false)
        anchorIsWidth = appState.config.bool(forKey: "resize_anchor_is_width", default: true)
        let methodLabel = settings["resize_resample_method"] as? String ?? "Lanczos"
        resampleMethod = ResizeImagesService.ResampleMethod.fromSettingsLabel(methodLabel)

        if let first = paths.first, let dims = ResizeImagesService.dimensions(for: first) {
            refWidth = dims.width
            refHeight = dims.height
            width = dims.width
            height = dims.height
        }
        percentScale = min(ResizeImagesService.percentScaleDefault, maxPercent)
        if preserveAspect {
            if anchorIsWidth {
                applyPreserveFromWidth()
            } else {
                applyPreserveFromHeight()
            }
        }
    }

    private func saveSettings() {
        appState.config.setValue(preserveAspect, forKey: "resize_preserve_aspect")
        appState.config.setValue(preserveDates, forKey: "resize_preserve_dates")
        appState.config.setValue(deleteOriginal, forKey: "resize_delete_original")
        appState.config.setValue(anchorIsWidth, forKey: "resize_anchor_is_width")
        appState.config.setValue(resampleMethod.displayName, forKey: "resize_resample_method")
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    private func setDimSpins(targetWidth: Int, targetHeight: Int) {
        let cap = dimSpinMax
        let w = max(1, min(cap, targetWidth))
        let h = max(1, min(cap, targetHeight))
        updating = true
        width = w
        height = h
        updating = false
    }

    private func selectDimensionsMode() {
        if resizeMode != .dimensions {
            resizeMode = .dimensions
        }
    }

    private func selectPercentMode() {
        guard percentAllowed, resizeMode != .percent else { return }
        resizeMode = .percent
    }

    private func onPercentChanged(_ value: Int) {
        guard !updating else { return }
        if resizeMode != .percent {
            percentChangeFromSlider = true
        }
        selectPercentMode()
        percentScale = value
    }

    private func onWidthChanged() {
        guard !updating else { return }
        selectDimensionsMode()
        width = max(1, min(dimSpinMax, width))
        if !preserveAspect { return }
        anchorIsWidth = true
        applyPreserveFromWidth()
    }

    private func onHeightChanged() {
        guard !updating else { return }
        selectDimensionsMode()
        height = max(1, min(dimSpinMax, height))
        if !preserveAspect { return }
        anchorIsWidth = false
        applyPreserveFromHeight()
    }

    private func applyPreserveFromWidth() {
        guard preserveAspect, refWidth > 0 else { return }
        let cap = dimSpinMax
        updating = true
        var w = max(1, width)
        var h = max(1, Int(round(Double(refHeight) * Double(w) / Double(refWidth))))
        h = min(h, cap)
        if h == cap && refHeight > 0 {
            w = min(cap, max(1, Int(round(Double(refWidth) * Double(h) / Double(refHeight)))))
            width = w
        }
        height = h
        updating = false
    }

    private func applyPreserveFromHeight() {
        guard preserveAspect, refHeight > 0 else { return }
        let cap = dimSpinMax
        updating = true
        var h = max(1, height)
        var w = max(1, Int(round(Double(refWidth) * Double(h) / Double(refHeight))))
        w = min(w, cap)
        if w == cap && refWidth > 0 {
            h = min(cap, max(1, Int(round(Double(refHeight) * Double(w) / Double(refWidth)))))
            height = h
        }
        width = w
        updating = false
    }

    private func applyScreenDims() {
        selectDimensionsMode()
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1024, height: 1024)
        let sw = Int(screen.width.rounded())
        let sh = Int(screen.height.rounded())
        if preserveAspect {
            let (w, h) = ResizeImagesService.bestFitWithinBounds(
                origW: refWidth,
                origH: refHeight,
                boundW: sw,
                boundH: sh,
                maxDim: dimSpinMax
            )
            let scaleW = refWidth > 0 ? Double(sw) / Double(refWidth) : 1.0
            let scaleH = refHeight > 0 ? Double(sh) / Double(refHeight) : 1.0
            anchorIsWidth = scaleW <= scaleH
            setDimSpins(targetWidth: w, targetHeight: h)
        } else {
            setDimSpins(targetWidth: sw, targetHeight: sh)
        }
    }

    private func applySquareDims() {
        selectDimensionsMode()
        let cap = dimSpinMax
        let side = max(1, min(cap, width))
        setDimSpins(targetWidth: side, targetHeight: side)
    }

    private func applyReverseDims() {
        selectDimensionsMode()
        setDimSpins(targetWidth: height, targetHeight: width)
    }

    private func applyImportDims() {
        selectDimensionsMode()
        guard let path = appState.fileData.currentImagePath ?? paths.first,
              let dims = ResizeImagesService.dimensions(for: path) else {
            StyledMessageDialog.showWarning(title: "Import Size", message: "No image selected.")
            return
        }
        setDimSpins(targetWidth: dims.width, targetHeight: dims.height)
    }

    @MainActor
    private func resize() {
        guard !paths.isEmpty else { return }

        let targetW: Int
        let targetH: Int
        let usePercent: Bool
        let pct: Int
        var preserve = preserveAspect
        var anchor = anchorIsWidth

        if resizeMode == .percent && percentAllowed {
            usePercent = true
            pct = percentScale
            let dims = ResizeImagesService.dimensionsFromPercent(
                refWidth: refWidth,
                refHeight: refHeight,
                percent: pct
            )
            targetW = dims.width
            targetH = dims.height
            preserve = true
            anchor = true
        } else {
            usePercent = false
            pct = ResizeImagesService.percentScaleDefault
            targetW = width
            targetH = height
            preserve = preserveAspect
            anchor = anchorIsWidth
        }

        if targetW < 1 || targetH < 1 {
            StyledMessageDialog.showWarning(title: "Resize", message: "Width and height must be at least 1 pixel.")
            return
        }
        if targetW > ResizeImagesService.maxResizeDimension || targetH > ResizeImagesService.maxResizeDimension {
            StyledMessageDialog.showWarning(
                title: "Resize",
                message: "Width and height cannot exceed \(ResizeImagesService.maxResizeDimension) pixels."
            )
            return
        }

        saveSettings()
        isResizing = true

        let request = ResizeImagesService.ResizeRequest(
            targetWidth: targetW,
            targetHeight: targetH,
            preserveAspect: preserve,
            anchorIsWidth: anchor,
            usePercentScale: usePercent,
            percentScale: pct,
            resampleMethod: resampleMethod,
            deleteOriginal: deleteOriginal,
            preserveDates: preserveDates,
            ignoreExifRotation: appState.config.ignoreExifRotation
        )

        var progress: CancellableProgressPanelController?
        if paths.count > 5 {
            progress = CancellableProgressPanelController(
                title: paths.count > 1 ? "Resize Images" : "Resize Image",
                labelText: "Resizing 1 of \(paths.count)",
                maximum: paths.count
            )
            progress?.show()
        }

        let result = ResizeImagesService.resizeBatch(paths: paths, request: request, progress: progress)
        isResizing = false
        dismiss()

        if !result.outputPaths.isEmpty {
            DirectoryRefreshService.invalidateThumbnails(appState: appState, paths: Array(Set(result.outputPaths)))
            appState.refreshDirectory()
            var message = "Resized \(result.resizedCount) file(s)"
            if result.stoppedEarly {
                message += " (stopped early)"
            }
            appState.status.show(message)
        }

        if !result.errors.isEmpty {
            let maxShow = 10
            var body = result.errors.prefix(maxShow).joined(separator: "\n\n")
            if result.errors.count > maxShow {
                body += "\n\n... and \(result.errors.count - maxShow) more"
            }
            StyledMessageDialog.showCritical(title: "Resize Errors", message: body)
        } else if result.resizedCount == 0 {
            appState.status.show("No files were resized")
        }
    }
}
