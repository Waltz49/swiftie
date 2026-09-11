import SwiftUI

/// Sheet showing EXIF reference dependency graph for an image.
@MainActor
struct ReferenceGraphView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let graph: ReferenceGraph

    private let thumbSize: CGFloat = 88
    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 110), spacing: 8)]

    var body: some View {
        let focusName = graph.focusPath.map { ($0 as NSString).lastPathComponent } ?? "Image"

        VStack(alignment: .leading, spacing: 12) {
            Text("Reference Graph — \(focusName)")
                .font(.headline)

            Text("Arrows show EXIF references (source → derived image).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if graph.nodes.isEmpty {
                Text("No reference images found.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(graph.nodes, id: \.self) { path in
                                ReferenceGraphNodeCell(
                                    path: path,
                                    size: thumbSize,
                                    isFocus: path == graph.focusPath
                                )
                            }
                        }

                        if !graph.edges.isEmpty {
                            Text("References")
                                .font(.subheadline.weight(.semibold))
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                                    Text("→ \((edge.0 as NSString).lastPathComponent) → \((edge.1 as NSString).lastPathComponent)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            DialogButtonRow(
                [DialogButton("Close", isDefault: true, isCancel: true) { dismiss() }],
                leadingButtons: graph.nodes.count >= 2
                    ? [DialogButton("Show in Browser") {
                        appState.openReferencePaths(graph.nodes, focusPath: graph.focusPath)
                        dismiss()
                    }]
                    : [],
                focusDefaultOnAppear: true
            )
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 400)
        .persistedDialogGeometry(
            DialogGeometryKey.referenceGraph,
            defaultWidth: 560,
            defaultHeight: 460,
            minWidth: 520,
            minHeight: 400
        )
    }
}

private struct ReferenceGraphNodeCell: View {
    @Environment(AppState.self) private var appState

    let path: String
    let size: CGFloat
    let isFocus: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isFocus ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isFocus ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .frame(width: size, height: size)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Text((path as NSString).lastPathComponent)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size + 8)
        }
        .task(id: path) {
            let pixelSize = Int(size * 2)
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: pixelSize) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else if let loaded = NSImage(contentsOfFile: path) {
                image = loaded
            }
        }
    }
}
