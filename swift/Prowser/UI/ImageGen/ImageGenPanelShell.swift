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
    var onEditSourcePathsChanged: (([String]) -> Void)?

    @State private var localSourcePath: String?
    @State private var localSourcePaths: [String] = []

    private var selectedPlugin: [String: Any]? {
        plugins.first { ($0["plugin_id"] as? String) == selectedPluginID }
    }

    private var fieldLayout: [[String: Any]] {
        selectedPlugin?["field_layout"] as? [[String: Any]] ?? []
    }

    private var dimensionSpecs: (width: [String: Any]?, height: [String: Any]?) {
        ImageGenFieldLayoutFilter.dimensionSpecs(from: fieldLayout)
    }

    private var filteredLayout: [[String: Any]] {
        ImageGenFieldLayoutFilter.layoutExcludingDimensionsAndPrompt(fieldLayout)
    }

    /// Edit: the leftmost source image is the single source of truth for imports and
    /// ``source_image_path`` (Python ``_edit_first_source_path`` / ``job_values_snapshot``).
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
            if function == "edit" {
                ImageGenPreviewSplitter {
                    editPreviewPane
                } controls: {
                    editControlsColumn
                }
                .frame(minHeight: 420)
            } else {
                standardPanelColumn
            }
        }
        .onAppear { syncSources() }
        .onChange(of: sourcePath) { _, _ in
            guard function != "edit" else { return }
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

    private var standardPanelColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelIntro
            controlsContent(includeFunctionHeader: true)
        }
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
                    onPathsChanged: { syncEditSourceValues() }
                )
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editControlsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelIntro
            controlsContent(includeFunctionHeader: false)
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var panelIntro: some View {
        if let intro = introText(for: function), !intro.isEmpty {
            Text(intro)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
        }
    }

    @ViewBuilder
    private func controlsContent(includeFunctionHeader: Bool) -> some View {
        ImageGenModelSelector(plugins: plugins, selectedPluginID: $selectedPluginID)
            .onChange(of: selectedPluginID) { _, _ in onValuesChanged?() }

        if let plugin = selectedPlugin {
            ImageGenLoraSection(
                values: $values,
                plugin: plugin,
                onValuesChanged: onValuesChanged
            )
        }

        if let comment = selectedPlugin?["model_comment"] as? String, !comment.isEmpty {
            Text(comment).font(.caption).foregroundStyle(.secondary)
        }

        if includeFunctionHeader {
            functionSpecificHeader
        }

        ImageGenPromptSection(
            function: function,
            values: $values,
            selectedPluginID: $selectedPluginID,
            plugins: plugins,
            sourcePath: effectiveSourcePath,
            existingSourcePaths: effectiveSourcePaths,
            showNegativePrompt: hasNegativePrompt,
            onValuesChanged: onValuesChanged,
            onSourcePathsImported: function == "edit" ? { paths in
                let normalized = ImageGenEditSourcePaths.normalizedPaths(paths)
                guard !normalized.isEmpty else { return }
                localSourcePaths = normalized
                syncEditSourceValues()
            } : nil
        )

        ImageGenFluxPromptSection(
            values: $values,
            function: function,
            sourcePaths: effectiveSourcePaths,
            onValuesChanged: onValuesChanged
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let width = dimensionSpecs.width, let height = dimensionSpecs.height,
                   let plugin = selectedPlugin {
                        ImageGenCustomSizeSection(
                            values: $values,
                            widthSpec: width,
                            heightSpec: height,
                            pipelineID: plugin["pipeline_id"] as? String ?? "",
                            pluginMaxDimension: plugin["max_generation_dimension"] as? Int ?? 2048,
                            sourcePath: effectiveSourcePath,
                            usesOptionalCustomSize: function == "edit",
                            onValuesChanged: onValuesChanged
                        )
                }
                ImageGenFieldRenderer(layout: filteredLayout, values: $values)
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: function == "edit" ? .infinity : 360)
    }

    @ViewBuilder
    private var functionSpecificHeader: some View {
        switch function {
        case "edit":
            editHeader
        case "expand":
            expandHeader
        case "infill":
            infillHeader
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var editHeader: some View {
        EmptyView()
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

    @ViewBuilder
    private var expandHeader: some View {
        if let path = effectiveSourcePath {
            ImageGenSourceNavBar(
                currentPath: path,
                onSelectPath: { newPath in
                    localSourcePath = newPath
                    values["source_image_path"] = newPath
                    values["source_image_paths"] = [newPath]
                    onValuesChanged?()
                }
            )
            sourceThumbnail(path: path, size: 180)
            Text("Placement canvas: drag handles in Python UI (preview only in Swift port).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("Expand requires an active source image.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var infillHeader: some View {
        if let path = effectiveSourcePath {
            sourceThumbnail(path: path, size: 180)
            Text("Paint mask in Pixelmator or the Python paint canvas (preview only in Swift port).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("Infill requires an active source image.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hasNegativePrompt: Bool {
        ImageGenFieldLayoutFilter.containsField(fieldLayout, key: "negative_prompt")
    }

    @ViewBuilder
    private func sourceThumbnail(path: String, size: CGFloat) -> some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
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

        localSourcePath = sourcePath
        localSourcePaths = sourcePaths
        guard function == "expand" || function == "infill" else { return }
        if !effectiveSourcePaths.isEmpty {
            values["source_image_paths"] = effectiveSourcePaths
            values["source_image_path"] = effectiveSourcePaths[0]
        }
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
