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

    private var effectiveSourcePath: String? {
        localSourcePath ?? sourcePath
    }

    private var effectiveSourcePaths: [String] {
        if !localSourcePaths.isEmpty { return localSourcePaths }
        if !sourcePaths.isEmpty { return sourcePaths }
        if let effectiveSourcePath { return [effectiveSourcePath] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let intro = introText(for: function), !intro.isEmpty {
                Text(intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
            }

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

            functionSpecificHeader

            ImageGenPromptSection(
                function: function,
                values: $values,
                selectedPluginID: $selectedPluginID,
                plugins: plugins,
                sourcePath: effectiveSourcePath,
                showNegativePrompt: hasNegativePrompt,
                onValuesChanged: onValuesChanged
            )

            ImageGenFluxPromptSection(
                values: $values,
                function: function,
                sourcePaths: effectiveSourcePaths,
                onValuesChanged: onValuesChanged
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let width = dimensionSpecs.width, let height = dimensionSpecs.height {
                        ImageGenCustomSizeSection(
                            values: $values,
                            widthSpec: width,
                            heightSpec: height,
                            sourcePath: effectiveSourcePath,
                            onValuesChanged: onValuesChanged
                        )
                    }
                    ImageGenFieldRenderer(layout: filteredLayout, values: $values)
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)
        }
        .onAppear { syncSources() }
        .onChange(of: sourcePath) { _, _ in syncSources() }
        .onChange(of: sourcePaths) { _, _ in syncSources() }
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
        if effectiveSourcePaths.isEmpty {
            Text("Select source images from the active browse image.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Sources: \(effectiveSourcePaths.count) image(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ImageGenSourceNavBar(
                    currentPath: effectiveSourcePaths.first,
                    onSelectPath: { path in
                        localSourcePaths = [path]
                        localSourcePath = path
                        values["source_image_paths"] = [path]
                        values["source_image_path"] = path
                        onValuesChanged?()
                    }
                )
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(effectiveSourcePaths, id: \.self) { path in
                        sourceThumbnail(path: path, size: 72)
                    }
                }
            }
        }
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
        localSourcePath = sourcePath
        localSourcePaths = sourcePaths
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
