import SwiftUI

@MainActor
struct ImageGenPanelShell: View {
    let function: String
    @Binding var values: [String: Any]
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String
    var sourcePaths: [String] = []
    var sourcePath: String? = nil
    var onValuesChanged: (() -> Void)?
    var onPluginImported: ((String) -> Void)?
    var onEditSourcePathsChanged: (([String]) -> Void)?
    var onSingleSourcePathChanged: ((String) -> Void)?
    var compactSliderTracks: Bool = false
    var infillCanvasHolder: ImageGenInfillCanvasHolder?
    var infillMaskPNGData: Data?
    var onInfillMaskPNGDataChanged: ((Data?) -> Void)?
    var onInfillHasPaintChanged: ((Bool) -> Void)?
    var onInfillPixelmatorDocPathChanged: ((String?) -> Void)?
    var onInfillPixelmatorExportChanged: (([String: Any]) -> Void)?
    var fluxContext: ImageGenFluxPromptSubmitContext?
    var fluxRefineCoordinator: FluxPromptRefineCoordinator?
    var activeBrowsePath: String?
    var onQueueJobWithAI: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var localSourcePath: String?
    @State private var localSourcePaths: [String] = []
    /// Expand: when true, canvas restores job snapshot placement; when false, first fit wins over stale `placement_*` from settings.
    var editingQueueJob: Bool = false

    private var selectedPlugin: [String: Any]? {
        plugins.first { ($0["plugin_id"] as? String) == selectedPluginID }
    }

    private var fieldLayout: [[String: Any]] {
        selectedPlugin?["field_layout"] as? [[String: Any]] ?? []
    }

    private var customSizeDimensionSpecs: (width: [String: Any], height: [String: Any])? {
        ImageGenFieldLayoutFilter.resolvedCustomSizeDimensionSpecs(
            function: function,
            layout: fieldLayout,
            values: values,
            mergedDefaults: selectedPlugin?["merged_defaults"] as? [String: Any] ?? [:]
        )
    }

    private var filteredLayout: [[String: Any]] {
        ImageGenFieldLayoutFilter.layoutExcludingDimensionsAndPrompt(fieldLayout)
    }

    private var pipelineID: String {
        selectedPlugin?["pipeline_id"] as? String ?? ""
    }

    /// Edit: canvas leftmost source drives ``source_image_path``; EXIF import buttons use the active
    /// browse/thumbnail image, not the edit preview canvas.
    private var effectiveSourcePath: String? {
        if function == "edit" {
            return effectiveSourcePaths.first
        }
        return localSourcePath ?? sourcePath
    }

    private var effectiveSourcePaths: [String] {
        if !localSourcePaths.isEmpty { return localSourcePaths }
        if !sourcePaths.isEmpty { return sourcePaths }
        if let path = localSourcePath ?? sourcePath { return [path] }
        return []
    }

    var body: some View {
        Group {
            switch function {
            case "edit":
                ImageGenPreviewSplitter {
                    editPreviewPane
                } controls: {
                    editControlsColumn
                }
                .frame(minHeight: 420)
            case "expand":
                ImageGenPreviewSplitter {
                    ImageGenExpandPreviewPane(
                        values: $values,
                        sourcePath: effectiveSourcePath,
                        pipelineID: pipelineID,
                        honorPersistedPlacement: editingQueueJob,
                        onSourcePathChanged: { adoptSingleSourcePath($0) },
                        onValuesChanged: onValuesChanged
                    )
                } controls: {
                    splitControlsColumn
                }
                .frame(minHeight: 420)
            case "infill":
                ImageGenPreviewSplitter {
                    ImageGenInfillPreviewPane(
                        sourcePath: effectiveSourcePath,
                        maxGenerationSide: infillMaxGenerationSide,
                        maskPNGData: infillMaskPNGData,
                        navigationLocked: infillSourceNavigationLocked,
                        showRefineInPixelmator: infillShowRefineInPixelmator,
                        canvasHolder: infillCanvasHolder ?? ImageGenInfillCanvasHolder(),
                        onSourcePathChanged: { adoptSingleSourcePath($0) },
                        onMaskPNGDataChanged: onInfillMaskPNGDataChanged,
                        onHasPaintChanged: onInfillHasPaintChanged,
                        onPixelmatorDocPathChanged: onInfillPixelmatorDocPathChanged,
                        onPixelmatorExportChanged: onInfillPixelmatorExportChanged
                    )
                } controls: {
                    splitControlsColumn
                }
                .frame(minHeight: 420)
            default:
                standardPanelColumn
            }
        }
        .onAppear { syncSources() }
        .onChange(of: sourcePath) { _, newPath in
            guard function != "edit" else { return }
            if function == "create" || function == "expand" || function == "infill" {
                localSourcePath = newPath
            }
            syncSources()
        }
        .onChange(of: sourcePaths) { _, newPaths in
            if function == "edit" {
                adoptEditSourcePathsIfNeeded(newPaths)
            } else {
                syncSources()
            }
        }
    }

    private var inlineFieldLabelWidth: CGFloat {
        ImageGenInlineFieldLayout.labelColumnWidth()
    }

    private var standardPanelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelIntro
            controlsContent(includeFunctionHeader: true)
        }
    }

    private var splitControlsColumn: some View {
        splitControlsColumnBody
    }

    private var editPreviewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if effectiveSourcePaths.isEmpty {
                Text("Select source images from the active browse image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ImageGenEditSourcePreview(
                    sourcePaths: editSourcePathsBinding,
                    onPathsChanged: { syncEditSourceValues() },
                    onPrimaryPathSelected: { path in
                        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
                        values["source_image_path"] = abs
                        onValuesChanged?()
                    }
                )
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editControlsColumn: some View {
        splitControlsColumnBody
    }

    private var splitControlsColumnBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelIntro
            controlsContent(includeFunctionHeader: false)
        }
    }

    @ViewBuilder
    private var panelIntro: some View {
        if let intro = introText(for: function), !intro.isEmpty {
            Text(intro)
                .font(ImageGenInlineFieldLayout.introFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ImageGenUnifiedIntroRule()
        }
    }

    @ViewBuilder
    private func controlsContent(includeFunctionHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: ImageGenInlineFieldLayout.blockSpacing) {
            ImageGenModelSection(
                plugins: plugins,
                selectedPluginID: $selectedPluginID,
                labelWidth: inlineFieldLabelWidth,
                onSelectionChanged: onValuesChanged
            )

            if let plugin = selectedPlugin {
                ImageGenLoraSection(
                    values: $values,
                    plugin: plugin,
                    labelWidth: inlineFieldLabelWidth,
                    onValuesChanged: onValuesChanged
                )
            }

            if includeFunctionHeader {
                EmptyView()
            }

            ImageGenPanelClientScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ImageGenPromptSection(
                        function: function,
                        values: $values,
                        selectedPluginID: $selectedPluginID,
                        plugins: plugins,
                        sourcePath: effectiveSourcePath,
                        existingSourcePaths: effectiveSourcePaths,
                        showNegativePrompt: hasNegativePrompt,
                        promptLabel: "Image Prompt",
                        promptStreamSession: fluxRefineCoordinator?.promptStreamSession,
                        onValuesChanged: onValuesChanged,
                        onSourcePathsImported: function == "edit" ? { paths in
                            let normalized = ImageGenEditSourcePaths.normalizedPaths(paths)
                            guard !normalized.isEmpty else { return }
                            localSourcePaths = normalized
                            syncEditSourceValues()
                        } : nil,
                        onPluginImported: onPluginImported
                    )
                    .padding(.top, 8)

                    if let fluxContext, let fluxRefineCoordinator {
                        ImageGenFluxPromptSection(
                            values: $values,
                            fluxContext: fluxContext,
                            refineCoordinator: fluxRefineCoordinator,
                            function: function,
                            sourcePaths: effectiveSourcePaths,
                            activeBrowsePath: activeBrowsePath,
                            onValuesChanged: onValuesChanged,
                            onQueueJobWithAI: onQueueJobWithAI
                        )
                    }

                    if let dimSpecs = customSizeDimensionSpecs, let plugin = selectedPlugin {
                        ImageGenCustomSizeSection(
                            values: $values,
                            widthSpec: dimSpecs.width,
                            heightSpec: dimSpecs.height,
                            pipelineID: plugin["pipeline_id"] as? String ?? "",
                            pluginMaxDimension: plugin["max_generation_dimension"] as? Int ?? 2048,
                            function: function,
                            sourcePath: effectiveSourcePath,
                            usesOptionalCustomSize: function == "edit",
                            compactSliderTracks: compactSliderTracks,
                            onValuesChanged: onValuesChanged
                        )
                        .padding(.vertical, compactSliderTracks ? 4 : 0)
                    }
                    ImageGenFieldRenderer(
                        layout: filteredLayout,
                        compactSliderTracks: compactSliderTracks,
                        copiesSliderMax: compactSliderTracks ? JobStepQueue.seriesContinuousCopies : nil,
                        values: $values,
                        onValuesChanged: onValuesChanged
                    )
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editSourcePathsBinding: Binding<[String]> {
        Binding(
            get: { effectiveSourcePaths },
            set: { newPaths in
                let normalized = ImageGenEditSourcePaths.normalizedPaths(newPaths)
                guard !normalized.isEmpty else { return }
                localSourcePaths = normalized
                syncEditSourceValues()
            }
        )
    }

    private func syncEditSourceValues() {
        let paths = effectiveSourcePaths
        guard !paths.isEmpty else { return }
        values["source_image_paths"] = paths
        values["source_image_path"] = paths[0]
        onEditSourcePathsChanged?(paths)
        onValuesChanged?()
    }

    private func adoptEditSourcePathsIfNeeded(_ paths: [String]) {
        let normalized = ImageGenEditSourcePaths.normalizedPaths(paths)
        guard !normalized.isEmpty else { return }
        guard normalized != localSourcePaths else { return }
        localSourcePaths = normalized
        syncEditSourceValues()
    }

    private func adoptSingleSourcePath(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalized) else { return }
        localSourcePath = normalized
        values["source_image_path"] = normalized
        values["source_image_paths"] = [normalized]
        onSingleSourcePathChanged?(normalized)
        onValuesChanged?()
    }

    private var hasNegativePrompt: Bool {
        ImageGenFieldLayoutFilter.containsField(fieldLayout, key: "negative_prompt")
    }

    private func syncSources() {
        if function == "edit" {
            if localSourcePaths.isEmpty, !sourcePaths.isEmpty {
                localSourcePaths = sourcePaths
            }
            if !effectiveSourcePaths.isEmpty {
                syncEditSourceValues()
            }
            return
        }

        if function == "expand" || function == "infill" {
            if let path = sourcePath {
                localSourcePath = path
            }
        } else if localSourcePath == nil {
            localSourcePath = sourcePath
        }
        localSourcePaths = sourcePaths
        guard function == "expand" || function == "infill" else { return }
        if !effectiveSourcePaths.isEmpty {
            values["source_image_paths"] = effectiveSourcePaths
            values["source_image_path"] = effectiveSourcePaths[0]
        }
    }

    private var infillMaxGenerationSide: Int {
        let pluginMax = selectedPlugin?["max_generation_dimension"] as? Int ?? 1024
        return ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: pluginMax,
            settings: appState.config.rawSettings()
        )
    }

    private var infillShowRefineInPixelmator: Bool {
        let editor = appState.config.string(forKey: "image_editor_app", default: "Preview")
        return ImageGenEditorSettings.shouldShowInfillPixelmatorRefine(editorApp: editor)
    }

    private var infillSourceNavigationLocked: Bool {
        guard let path = effectiveSourcePath else { return false }
        return ImageGenInfillPathSemantics.isWorkingTempPath(
            path,
            tempRoot: appState.config.temporaryFilesDirectory.path
        )
    }

    private func introText(for function: String) -> String? {
        switch function {
        case "edit":
            return "Modify the selected image(s) with AI using a text prompt. Drag and drop new images."
        case "create":
            return "Generate a new image from a text (prompt) and optional active image description."
        case "expand":
            return "Extend an image beyond its current edges (outpainting)."
        case "infill":
            return "Paint a mask to fill or replace part of an image. When Pixelmator Pro is the configured editor, refine the mask there."
        default:
            return nil
        }
    }
}
